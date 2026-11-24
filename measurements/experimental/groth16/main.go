// EXPERIMENTAL. A Groth16 (BN254) circuit for the canonical 52,650-parameter MLP, for measurement only.
//
//	go run . setup <weights.json> <out dir>                 compile, single-party local setup, Solidity verifier
//	go run . prove <weights.json> <reference.json> <out dir> prove every reference input; parity with EZKL
//
// The weights are constants of the circuit, quantised as the canonical EZKL circuit does: inputs,
// weights and biases at scale 2^13 (round half away from zero). Each layer is
// round_half_away(W.x / 2^13) + b, with ReLU between layers: the rule that reproduced EZKL's own
// outputs on 25 of 25 inputs (parity run). Public inputs: the input commitment, then the ten outputs,
// as field elements, like the canonical solo circuit's. The commitment is Poseidon2 (gnark's BN254
// Poseidon2 in Merkle-Damgard mode) over the 789 quantised input values: it is NOT the canonical
// commitment, which is EZKL's Poseidon over the same values.
//
// The trusted setup here is a single-party local setup: whoever ran it could forge proofs. It is
// insecure for anything but measurement.
package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"math/big"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
	"time"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark-crypto/ecc/bn254/fr"
	nativeposeidon2 "github.com/consensys/gnark-crypto/ecc/bn254/fr/poseidon2"
	"github.com/consensys/gnark/backend/groth16"
	"github.com/consensys/gnark/backend/solidity"
	"github.com/consensys/gnark/constraint"
	"github.com/consensys/gnark/constraint/solver"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/std/hash/poseidon2"
)

const (
	nIn     = 789 // 784 features and 5 nonce values; the model reads the first 784
	nFeat   = 784
	nOut    = 10
	scale   = 13
	offBits = 60 // a layer's sum plus 2^60 is non-negative and below 2^61
	qBits   = 48 // offBits + 1 - scale
)

type Weights struct {
	Scale     int          `json:"scale"`
	Semantics string       `json:"semantics"`
	W         [][][]int64  `json:"W"`
	B26       [][]int64    `json:"b26"`
	B13       [][]int64    `json:"b13"`
}

var weights Weights

type MLP struct {
	Commitment frontend.Variable        `gnark:",public"`
	Outputs    [nOut]frontend.Variable  `gnark:",public"`
	X          [nIn]frontend.Variable
}

// divHint returns q, r with a = q*2^scale + r, 0 <= r < 2^scale, for a non-negative a < 2^61.
func divHint(_ *big.Int, in []*big.Int, out []*big.Int) error {
	d := big.NewInt(1 << scale)
	out[0].DivMod(in[0], d, out[1])
	return nil
}

func init() { solver.RegisterHint(divHint) }

func pow2(n uint) *big.Int { return new(big.Int).Lsh(big.NewInt(1), n) }

// roundHalfAway returns round_half_away(acc / 2^13) for |acc| < 2^60. With a = acc + 2^60 =
// q*2^13 + r (q < 2^48, r < 2^13, which pins q and r), floor(acc / 2^13) = q - 2^47 and acc < 0
// exactly when the top bit of q is 0. Rounding adds 1 when r > 2^12, and when r = 2^12 and acc >= 0.
// A sum outside [-2^60, 2^60) has no witness.
func roundHalfAway(api frontend.API, acc frontend.Variable) frontend.Variable {
	a := api.Add(acc, pow2(offBits))
	qr, err := api.Compiler().NewHint(divHint, 2, a)
	if err != nil {
		panic(err)
	}
	q, r := qr[0], qr[1]
	api.AssertIsEqual(a, api.Add(api.Mul(q, 1<<scale), r))
	rb := api.ToBinary(r, scale)
	qb := api.ToBinary(q, qBits)
	negative := api.Sub(1, qb[qBits-1])
	half := api.IsZero(api.Sub(r, 1<<(scale-1)))
	up := api.Sub(rb[scale-1], api.Mul(negative, half))
	return api.Add(api.Sub(q, pow2(qBits-1)), up)
}

// relu returns max(z, 0) for |z| < 2^47.
func relu(api frontend.API, z frontend.Variable) frontend.Variable {
	zb := api.ToBinary(api.Add(z, pow2(qBits-1)), qBits)
	return api.Mul(z, zb[qBits-1])
}

func (c *MLP) Define(api frontend.API) error {
	if os.Getenv("MLP_WITHOUT_COMMITMENT") == "" { // set only to count the network's constraints alone
		h, err := poseidon2.New(api)
		if err != nil {
			return err
		}
		h.Write(c.X[:]...)
		api.AssertIsEqual(h.Sum(), c.Commitment)
	}

	layer := make([]frontend.Variable, nFeat)
	copy(layer, c.X[:nFeat])
	for l := range weights.W {
		next := make([]frontend.Variable, len(weights.W[l]))
		for j, row := range weights.W[l] {
			acc := frontend.Variable(0)
			for i, w := range row {
				if w != 0 {
					acc = api.Add(acc, api.Mul(layer[i], w))
				}
			}
			y := api.Add(roundHalfAway(api, acc), weights.B13[l][j])
			if l < len(weights.W)-1 {
				y = relu(api, y)
			}
			next[j] = y
		}
		layer = next
	}
	for j := 0; j < nOut; j++ {
		api.AssertIsEqual(layer[j], c.Outputs[j])
	}
	return nil
}

// ── Native side: quantisation, the same layers, the commitment ─────────────────────────────────

func quantise(x float64) int64 { return int64(math.Round(x * (1 << scale))) } // half away from zero, as EZKL

func roundHalfAwayNative(acc *big.Int) *big.Int {
	d, h := big.NewInt(1<<scale), big.NewInt(1<<(scale-1))
	a := new(big.Int).Abs(acc)
	q := new(big.Int).Quo(new(big.Int).Add(a, h), d)
	if acc.Sign() < 0 {
		q.Neg(q)
	}
	return q
}

func forward(q []int64) []int64 {
	layer := make([]*big.Int, nFeat)
	for i := range layer {
		layer[i] = big.NewInt(q[i])
	}
	for l := range weights.W {
		next := make([]*big.Int, len(weights.W[l]))
		for j, row := range weights.W[l] {
			acc := big.NewInt(0)
			for i, w := range row {
				acc.Add(acc, new(big.Int).Mul(layer[i], big.NewInt(w)))
			}
			y := roundHalfAwayNative(acc)
			y.Add(y, big.NewInt(weights.B13[l][j]))
			if l < len(weights.W)-1 && y.Sign() < 0 {
				y.SetInt64(0)
			}
			next[j] = y
		}
		layer = next
	}
	out := make([]int64, nOut)
	for j := range out {
		out[j] = layer[j].Int64()
	}
	return out
}

func toField(v int64) fr.Element {
	var e fr.Element
	e.SetBigInt(big.NewInt(v))
	return e
}

func commitment(q []int64) fr.Element {
	h := nativeposeidon2.NewMerkleDamgardHasher()
	for _, v := range q {
		e := toField(v)
		b := e.Bytes()
		h.Write(b[:])
	}
	var c fr.Element
	c.SetBytes(h.Sum(nil))
	return c
}

// ── Commands ─────────────────────────────────────────────────────────────────────────────────

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func peakMB() int64 {
	var ru syscall.Rusage
	_ = syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	return ru.Maxrss / 1024 // Linux: kilobytes
}

func compile() constraint.ConstraintSystem {
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, &MLP{})
	must(err)
	return ccs
}

func writeJSON(path string, v any) {
	b, _ := json.MarshalIndent(v, "", "  ")
	must(os.WriteFile(path, b, 0o644))
}

func main() {
	raw, err := os.ReadFile(os.Args[2])
	must(err)
	must(json.Unmarshal(raw, &weights))
	out := os.Args[len(os.Args)-1]
	must(os.MkdirAll(out, 0o755))

	switch os.Args[1] {
	case "count":
		fmt.Printf("constraints %d\n", compile().GetNbConstraints())

	case "setup":
		t := time.Now()
		ccs := compile()
		compileS := time.Since(t).Seconds()
		t = time.Now()
		pk, vk, err := groth16.Setup(ccs)
		must(err)
		setupS := time.Since(t).Seconds()
		for name, w := range map[string]interface{ WriteTo(f *os.File) (int64, error) }{} {
			_, _ = name, w
		}
		f, _ := os.Create(filepath.Join(out, "ccs.bin"))
		_, _ = ccs.WriteTo(f)
		f.Close()
		f, _ = os.Create(filepath.Join(out, "pk.bin"))
		_, _ = pk.WriteTo(f)
		f.Close()
		f, _ = os.Create(filepath.Join(out, "vk.bin"))
		_, _ = vk.WriteTo(f)
		f.Close()
		f, _ = os.Create(filepath.Join(out, "Groth16Verifier.sol"))
		must(vk.ExportSolidity(f, solidity.WithPragmaVersion("^0.8.24")))
		f.Close()
		writeJSON(filepath.Join(out, "setup.json"), map[string]any{
			"label": "EXPERIMENTAL; single-party local trusted setup, insecure for anything but measurement",
			"constraints": ccs.GetNbConstraints(), "public_inputs": ccs.GetNbPublicVariables() - 1,
			"secret_inputs": ccs.GetNbSecretVariables(), "internal_variables": ccs.GetNbInternalVariables(),
			"compile_seconds": compileS, "setup_seconds": setupS, "peak_rss_mb": peakMB(),
			"cores": runtime.NumCPU(), "gomaxprocs": runtime.GOMAXPROCS(0), "semantics": weights.Semantics,
		})
		fmt.Printf("constraints %d, compile %.1f s, setup %.1f s, peak %d MB\n", ccs.GetNbConstraints(), compileS, setupS, peakMB())

	case "prove":
		var refs []struct {
			Label   string    `json:"label"`
			Input   []float64 `json:"input"`
			Outputs []int64   `json:"ezkl_outputs"`
		}
		raw, err := os.ReadFile(os.Args[3])
		must(err)
		must(json.Unmarshal(raw, &refs))
		ccs := groth16.NewCS(ecc.BN254)
		f, _ := os.Open(filepath.Join(out, "ccs.bin"))
		_, err = ccs.ReadFrom(f)
		must(err)
		f.Close()
		pk := groth16.NewProvingKey(ecc.BN254)
		f, _ = os.Open(filepath.Join(out, "pk.bin"))
		_, err = pk.ReadFrom(f)
		must(err)
		f.Close()
		vk := groth16.NewVerifyingKey(ecc.BN254)
		f, _ = os.Open(filepath.Join(out, "vk.bin"))
		_, err = vk.ReadFrom(f)
		must(err)
		f.Close()

		type row struct {
			Label        string   `json:"label"`
			ParityExact  bool     `json:"parity_exact"`
			Ours         []int64  `json:"ours"`
			EZKL         []int64  `json:"ezkl"`
			ProveSeconds float64  `json:"prove_seconds"`
			Verified     bool     `json:"verified"`
			Commitment   string   `json:"commitment"`
		}
		var rows []row
		matches := 0
		for k, ref := range refs {
			q := make([]int64, nIn)
			for i, x := range ref.Input {
				q[i] = quantise(x)
			}
			ours := forward(q)
			exact := len(ours) == len(ref.Outputs)
			for j := range ours {
				exact = exact && ours[j] == ref.Outputs[j]
			}
			if exact {
				matches++
			}
			c := commitment(q)
			var a MLP
			a.Commitment = c
			for j := 0; j < nOut; j++ {
				a.Outputs[j] = ours[j]
			}
			for i := 0; i < nIn; i++ {
				a.X[i] = q[i]
			}
			w, err := frontend.NewWitness(&a, ecc.BN254.ScalarField())
			must(err)
			t := time.Now()
			proof, err := groth16.Prove(ccs, pk, w)
			must(err)
			dt := time.Since(t).Seconds()
			pub, _ := w.Public()
			ok := groth16.Verify(proof, vk, pub) == nil
			cb := c.Bytes()
			rows = append(rows, row{ref.Label, exact, ours, ref.Outputs, dt, ok, "0x" + hex.EncodeToString(cb[:])})
			fmt.Printf("%-14s parity %-5v prove %.2f s verified %v\n", ref.Label, exact, dt, ok)
			if k == 0 {
				type solidityProof interface{ MarshalSolidity() []byte }
				ps := proof.(solidityProof).MarshalSolidity()
				pubs := []string{"0x" + hex.EncodeToString(cb[:])}
				for j := 0; j < nOut; j++ {
					e := toField(ours[j])
					b := e.Bytes()
					pubs = append(pubs, "0x"+hex.EncodeToString(b[:]))
				}
				writeJSON(filepath.Join(out, "proof-for-foundry.json"), map[string]any{
					"label": ref.Label, "proof": "0x" + hex.EncodeToString(ps), "public_inputs": pubs,
				})
			}
		}
		writeJSON(filepath.Join(out, "prove.json"), map[string]any{
			"label": "EXPERIMENTAL; single-party local trusted setup, insecure for anything but measurement",
			"inputs": len(refs), "exact_output_matches": matches, "peak_rss_mb": peakMB(),
			"cores": runtime.NumCPU(), "gomaxprocs": runtime.GOMAXPROCS(0), "rows": rows,
		})
		fmt.Printf("parity: %d of %d exact; peak %d MB\n", matches, len(refs), peakMB())
	}
}
