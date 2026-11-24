# Checking the registry entries against the published files, 2026-11-24

`scripts/verify_entry.py` regenerates what the chain runs from the published circuit files and compares it with the registry entries of the testnet deployment, read-only (`eth_call`, `eth_getCode`). This folder holds its runs: `verify.log` (the script's output for the four runs, one after the other) and one JSON result per run (`ve-*.json`).

## Machine

**2 vCPUs of an Intel Xeon Gold 5220R at 2.20 GHz**, Ubuntu 24.04. Python 3.12.3, EZKL 23.0.5, solc 0.8.20 (the linux-amd64 release build, checked against its published SHA-256). Blocks 63,082,345 to 63,082,513. Times are wall-clock; memory is the peak resident set of the script's process, in which EZKL runs (solc, a separate process, peaked at 49 MB compiling the same source on a Mac).

## Results

| Run | What it regenerates | Result | Time | Key setup | Peak memory |
|---|---|---|---:|---:|---:|
| `solo` | model, pinned settings, SRS → verifying key → verifier → chain | **MATCH**, 19 of 19 checks | 21.68 s | 18.00 s | 996 MB |
| `k8 --from-vk` | pinned key → verifier → chain | **MATCH**, 17 of 17 | 8.14 s | not run | 742 MB |
| `solo --from-vk` | pinned key → verifier → chain | **MATCH**, 17 of 17 | 3.56 s | not run | 125 MB |
| `solo --settings <swapped>` | as `solo`, from settings whose two range checks are swapped | **MISMATCH**, 5 of 19 checks fail, exit 1 | 21.12 s | 17.51 s | 1,012 MB |

Each MATCH establishes, for its entry: the inputs have their published SHA-256; the regenerated key (full run) and verifier source are byte-identical to the pinned ones; the entry is the registered one and its fields hash to its id; the adapter and verifier hold the registered code, and neither is a delegated account; keccak256 of the key equals the entry's `vkHash`; and the regenerated runtime bytecode equals the on-chain verifier's, both without their 53-byte metadata trailer (solo: 17,939 bytes, keccak256 `0xf60aad67…b17c`; K=8: 17,937 bytes, `0xd0cab404…8c67`). The rest of each run's time is reading and hashing the inputs; the chain reads took 1.1 to 1.3 s.

**The negative run** is the reproducibility finding made concrete. Settings that differ from the pinned file only in the order of `required_range_checks`, as a fresh `calibrate_settings` can produce, give a different verifying key (`0x46b51e37…da68`) and a different verifier (`0xc8769485…afbe` without trailer). The script reports both and exits 1, while every check of the entry itself still matches. The pinned `settings.json` is part of the circuit's identity.

## K=8 from the model: not run here

The full K=8 run needs EZKL's key setup for the K=8 circuit. Measured earlier at **15.1 s and 6.35 GB peak** on a Mac (macOS, `/usr/bin/time -l`; `measurements/2026-09-28-proving-cost/results.jsonl`, stage `compile_setup`, circuit `batch`), it was not run on this machine; only the step that needs no model weights (`--from-vk`) was run for K=8. A machine with about 8 GB free runs `python3 scripts/verify_entry.py k8` unchanged.

## A first run, discarded

The same four runs were made once before (16:36 UTC) with the same verdicts. Their output reported a second memory figure, "largest child (solc)", that was not what it said: a child created by fork counts the pages it shares with its parent, so it repeated the parent's peak. That run also hashed the K=8 key twice. The script was corrected and the runs repeated; only the repeat is kept.

## Reproduce

```
bash scripts/fetch_srs.sh
python3 scripts/verify_entry.py solo
python3 scripts/verify_entry.py k8 --from-vk
python3 scripts/verify_entry.py solo --from-vk
S=circuits/spike-mlp/run_t3_k5_nonces/settings.json
sed 's/\[\[-1,1\],\[0,16383\]\]/[[0,16383],[-1,1]]/' $S > swapped.json
python3 scripts/verify_entry.py solo --settings swapped.json
```

Each run was given `--json ve-<name>.json`.
