# EXPERIMENTAL: a Groth16 version of the canonical MLP, 2026-11-24 (preliminary)

**EXPERIMENTAL and preliminary. The trusted setup is a single-party local setup and is insecure for anything but measurement:** the machine that ran `groth16.Setup` knew the randomness that lets anyone holding it forge proofs this verifier accepts. Nothing from this prototype is registered or deployed on any network, and no canonical artifact changed. A Groth16 verifier fit for use needs a setup ceremony with independent participants, or a universal setup (docs/deployment-notes.md, "Second proof system").

## What was built

A Groth16 (BN254) circuit for the canonical 52,650-parameter MLP (784 → 64 → 32 → 10), written with **gnark v0.16.5** (`main.go`; Go 1.27.4). gnark rather than circom with snarkjs, because:
- it proves natively, much faster than snarkjs's JavaScript prover;
- it needs no separate circuit compiler;
- in its R1CS, multiplying by a constant weight is free;
- it exports a plain Solidity verifier.

**The arithmetic is EZKL's, measured rather than guessed.** `parity.py` compared candidate integer pipelines with EZKL's own witness outputs for the canonical compiled circuit (no proving), on 25 inputs:
- the published solo input;
- the 16 inputs of the September K=16 run;
- 8 random inputs, from a fixed seed.

One rule reproduced all 25 exactly. Inputs, weights and biases are quantised at 2^13, rounding half away from zero. Each layer is `round_half_away(W·x / 2^13) + b`, with ReLU between layers. The weights are constants of the circuit.

**Public inputs: the input commitment, then the ten outputs**, field elements in the canonical solo circuit's order, so that `SoloSettlement` and the registry take the statement unchanged.

**The input commitment is NOT the canonical one.** The canonical circuit commits with EZKL's Poseidon over the 789 quantised values (784 features and 5 nonce values). This prototype commits with gnark's Poseidon2, in Merkle-Damgard mode, over the same 789 quantised values. For the published input that gives `0x2b8e…0460` instead of `0x0011…ff70`. A payment signed for one commitment cannot be settled with the other circuit's proof.

## Results

Proving ran on 2 vCPUs of an Intel Xeon Gold 5220R at 2.20 GHz, Go running 2 threads. Gas was measured with Forge (the Osaka schedule, the test token; gas does not depend on the machine).

| | Groth16 prototype | Canonical Halo2 (EZKL), same 2 cores |
|---|---:|---:|
| Constraints | 158,795: input commitment 146,755, network 12,040 | 33,976 rows of a logrows-16 circuit |
| Setup (single-party, local; insecure) | 37.0 s, peak 392 MB | 18.25 s |
| Proof time, per input (25 proofs) | 3.25 to 3.49 s, mean 3.35 s | 20.10 s |
| Peak memory while proving | 521 MB | 1,409 MB |
| Proof size | 256 bytes | 3,840 bytes |
| Proving key, verifying key | 32.6 MB, 684 bytes | 659 MB, 157 KB |
| Output parity with EZKL, 25 inputs | **25 of 25 exact** | |
| Adapter and verifier, gas | 265,728 | 577,544 (verifier alone) |
| `SoloSettlement.settle`, steady, test token | **372,965** | 747,528 |
| `settle`, first payment to the provider, test token | 390,065 | 764,628 |
| `settle`, steady, USDC (derived: test token + 20,646) | **≈ 393,611** | 768,174 |

The USDC figure adds to the test-token one the difference measured for the same call with the Halo2 verifier: 768,174 − 747,528 = 20,646, the token's part, which the proof system does not touch. It was not measured on a fork.

**The Foundry test** is `test/experimental/groth16/Groth16Prototype.t.sol`. It runs gnark's exported verifier (`Groth16Verifier.sol`, unchanged) behind `Groth16Adapter` (`IProofVerifier`), registered in the `VerifierRegistry`. The real proof of the published input settles through `SoloSettlement`. A changed proof, a changed output and another commitment are all rejected; a changed proof makes `settle` revert with `ProofInvalid()`. One caveat: an invalid curve point makes the verifier's precompile call consume all the gas it is given. Behind the registry that is bounded by the entry's allowance (280,000).

## Projection to K=16 batches (HYPOTHESIS)

Not measured. A Groth16 verifier pays a fixed cost plus about 6,270 gas per public input, for an elliptic-curve multiplication and addition. Fitted to the measured 265,728 for 11 inputs, that is about 196,758 plus 6,270 per input. The canonical K=16 batch (`measurements/2026-11-24-k16/`) costs 1,137,050, of which its verifier is 702,349 and its proof 3,840 bytes.

- **The same statement, one proof for 16 inferences:** 16 commitments and 160 outputs, so 176 public inputs. The verifier would cost about 1,300,000, and the batch about 1,680,000: about 105,000 per request. That is worse than Halo2's 71,066, because the outputs are public inputs.
- **Each lane's ten outputs packed into one field element** (they fit in 240 bits), so 32 public inputs. The verifier would cost about 397,000, and the batch about 775,000: **about 48,400 per request**. The contract would carry the packed form, and the adapter would unpack it.
- **Proving K=16:** about 2.5 million constraints, almost all of them the sixteen commitments. Linearly, about 54 s on the same 2 cores, and a few GB of memory.

## What this leaves open

- **The commitment.** Reproducing EZKL's Poseidon in the circuit, halo2's width-3, rate-2 permutation over the same 789 values, would let either backend settle the same payment terms. HYPOTHESIS: about 100,000 constraints, fewer than the Poseidon2 used here.
- **The commitment is 92% of the circuit.** Range-checking the inputs and packing several into each hashed element would cut it several times over. HYPOTHESIS: under 30,000 constraints for the commitment.
- **A setup that is not single-party.** A Groth16 key needs a ceremony; a universal-setup system such as PLONK with KZG would avoid a per-circuit ceremony, at a higher verifier cost.
