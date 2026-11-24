# EXPERIMENTAL: the solo circuit's verifier gas against its column count, and an arg-max head, 2026-11-24

**EXPERIMENTAL. Every key here is new and none of it is canonical.** The pinned circuits, keys and verifiers (`circuits/spike-mlp/MANIFEST.md`) are unchanged. These variants exist to decide what a later circuit version (v3.1) should look like. Their proving keys were deleted after use; nothing here is registered or deployed anywhere.

## What was varied

The canonical solo circuit's model, weights, scales (2^13), visibility and `check_mode`, with only one thing changed per variant:
- **Inner columns:** EZKL's `num_inner_cols` set to 1, 2, 3, 4 or 6, the canonical value being 2. Each variant's settings come from `gen_settings` and `calibrate_settings` (target "resources", scale 13), which also chose its logrows.
- **Arg-max head:** an ArgMax node, cast to float, appended to the model, so that the circuit's public output is the predicted digit instead of ten logits. ArgMax's integer output was rejected by EZKL's model importer, hence the cast.

`variants.py` sets up (each variant's settings are in `EXPERIMENTAL-settings-<variant>.json`) the keys from the canonical SRS files, proves the published input, verifies the proof and writes the EVM verifier. `variant_gas.py` deploys each verifier through EZKL's own compilation path on a local node (Osaka) and sends one `verifyProof` with its proof.

**Machines.** Setup and proving ran on 2 vCPUs of an Intel Xeon Gold 5220R at 2.20 GHz. The gas measurement ran on the Mac (Apple M4 Pro); gas does not depend on the machine.

## Results

| Variant | logrows | Public inputs | Proof (bytes) | Verifier code (bytes) | `verifyProof` execution | Whole transaction | Setup | Prove | Peak memory | Proving key |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 column | 17 | 11 | 2,912 | 15,197 | **479,538** | **551,058** | 192.9 s | 195.9 s | 2,099 MB | 1,066 MB |
| 2 columns (the canonical layout; control) | 16 | 11 | 3,840 | 17,992 | 577,544 | 663,840 | 41.9 s* | 48.0 s* | 1,394 MB | 659 MB |
| 3 columns | 15 | 11 | 4,928 | 21,358 | 683,061 | 786,669 | 47.9 s | 51.7 s | 902 MB | 392 MB |
| 4 columns | 15 | 11 | 6,048 | 24,220 | 796,078 | 917,234 | 49.6 s | 55.4 s | 1,085 MB | 466 MB |
| 6 columns | 15 | 11 | 6,464 | 28,271 | 895,925 | 1,023,701 | 53.9 s | 57.3 s | 1,235 MB | 571 MB |
| 2 columns, arg-max head | 16 | 2 | 6,016 | 24,172 | 781,433 | 898,825 | 23.5 s | 32.5 s | 2,175 MB | 910 MB |

\* The control's setup and proof overlapped another job on the same 2 cores; the canonical circuit alone takes 18.25 s and 20.10 s (`measurements/2026-11-24-prover/`). Every other row ran alone.

- **Verifier gas rises by about 100,000 per inner column**, while the proof grows and the proving key shrinks. The control reproduces the canonical verifier's 577,544 exactly, though its key differs (`measurements/2026-11-24-prover/`, "A finding on reproducing the settings").
- **One column is the cheapest to verify:** 98,006 less execution than the canonical circuit (−17.0%), and a proof 928 bytes shorter; 112,782 less per transaction (−17.0%). It costs about ten times the canonical proving time on the same cores, and a proving key 62% larger.
- **Six columns produce a verifier of 28,271 bytes,** over the 24,576-byte contract-size limit: it could not be deployed on Base or Ethereum.
- **The arg-max head makes verification dearer, not cheaper.** It removes nine public outputs (288 bytes of calldata), but the arg-max is computed with extra lookups, so its verifier costs 203,889 more than the canonical one.

## Recommendations for v3.1

- **Column count:** keep two columns for interactive use. Consider **one column** where gas dominates and proving latency does not. It saves 17% per verification, at the solo size. HYPOTHESIS: the same holds at K=8 and K=16, where the keys are larger, so one column there needs its memory measured first. Three or more columns only raise gas.
- **Arg-max head:** do not add an arg-max head to the circuit. If smaller outputs are wanted, pack the ten outputs into fewer field elements outside the model's arithmetic instead (not tested here).
