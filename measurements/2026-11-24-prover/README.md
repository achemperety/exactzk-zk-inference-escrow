# Prover experiments with the canonical keys, 2026-11-24

Two questions about proving with the canonical solo circuit, answered with its canonical keys, and one that could not be run. Nothing here changes a canonical artifact. Experiments that make new keys are under `measurements/experimental/`.

## Machine

All figures here come from one machine: **2 vCPUs of an Intel Xeon Gold 5220R at 2.20 GHz**, Ubuntu 24.04.

Times are wall-clock on those 2 cores; memory is the peak resident set of the job's largest process. These figures are not comparable with proving times measured earlier on other machines.

## A warm prover, solo

Does keeping the prover in one process make repeated proofs faster? `warm_prover_and_check_mode.py warm` (results in `warm-prover-results.json`):
1. compile the canonical circuit from the pinned `settings.json`, and set up its keys from the canonical SRS;
2. prove the published input, then five more inputs, each the published features with fresh nonces, all in the same process;
3. verify every proof.

| Step | Time | Peak memory |
|---|---:|---:|
| Setup (proving and verifying key) | 18.25 s | 960 MB |
| Witness, each input | 0.23 to 0.29 s | |
| Proof, the first in the process | 20.10 s | 1,393 MB |
| Proofs 2 to 6 in the same process | 19.96, 20.11, 20.10, 20.42, 19.90 s | 1,409 MB |

- **The keys are the canonical ones.** The verifying key set up from the pinned settings and SRS is byte-identical to the pinned `vk.key` (SHA-256 `32439290…9523`). The proof of the published input carries exactly the stored proof's public inputs.
- **Every proof verifies,** in EZKL. One of the fresh proofs, with a new input commitment, was also run against the pinned solo verifier bytecode on a local node, and accepted. With one of its outputs changed, the call reverted.
- **There is no warm gain** at the level of EZKL's Python API. A later proof costs what the first one does, within 0.5 s. The API reads the 659 MB proving key on every call, and the proof itself is bound by computation, on 2 cores.

**Recommendation for v3.1:** do not build a warm-prover service on EZKL's Python API to save time; it saves none. Proving time is set by the cores given to it. A prover that keeps the key in memory, in Rust, could save at most the key's load, which these figures do not separate out (HYPOTHESIS: about a second).

## `check_mode` SAFE

Is the verifying key of the same circuit identical with `check_mode` SAFE instead of UNSAFE? `warm_prover_and_check_mode.py safe` (results in `check-mode-safe-results.json`): the pinned settings with only `check_mode` changed, compiled, keys set up, the published input proved.

**Yes, byte-identical** (SHA-256 `32439290…9523`, the pinned key). The setup took 18.95 s, the proof 20.41 s at 1,398 MB peak, and the proof verifies.

The check mode governs checks made while the witness is computed. It does not enter the circuit or its keys, and so not the verifier.

**Recommendation for v3.1:** provers can run with SAFE, which checks more while computing the witness, and nothing on chain changes: same verifier, same entry, same ids. The only thing that changes is the SHA-256 of the settings file a prover uses, which `circuits/spike-mlp/MANIFEST.md` would have to list beside the pinned one.

## A warm prover at K=8 (not run)

A K=8 proof peaks at about 12.8 GB (earlier measurement, `measurements/2026-09-28-proving-cost/`). That is more memory than the machine above offered, so the K=8 warm prover, and K=16 after it, were not run. They are not planned either: EZKL's API reads the proving key on every call, so a warm process cannot show a gain.

## A finding on reproducing the settings

Regenerating the solo circuit's settings from scratch does not necessarily give the pinned ones. `measurements/experimental/columns/` ran a control: the same model, the same scales and visibility, two inner columns, through EZKL's `gen_settings` and `calibrate_settings`. It produced a circuit of the same size, but a different verifying key. Its settings differ from the pinned ones only in the order of the two entries of `required_range_checks` (`[0, 16383]` and `[-1, 1]`, swapped), and in the timestamp.

The verifier generated from it costs exactly the same gas, 577,544, but its key and code hash differ. The canonical keys are therefore reproduced from the pinned `settings.json`, as the two runs above did, and not from a fresh calibration.
