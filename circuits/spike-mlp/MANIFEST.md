# Circuit manifest

Two circuits are pinned in this folder. Check this file before trusting any file under `run_*/`.

Every value below was computed from the files on 2026-11-22. `provenance/COPIED_FILES.sha256` holds the same SHA-256 values in a form `shasum -a 256 -c` can check, and `scripts/hygiene_scan.sh` fails if any pinned file changes. The two `srs.bin` files are not stored in this repository; `bash scripts/fetch_srs.sh` downloads them and checks them against `provenance/SRS.sha256` (see "Where `srs.bin` comes from" below).

## The model

Both circuits prove the same network with the same weights: a multilayer perceptron 784 → 64 → 32 → 10 with **52,650 parameters** (read from the tensor shapes in the ONNX files; `model.onnx.data` and `model_k8.onnx.data` are byte-identical). Each input is 789 values: 784 features followed by 5 nonce values that the network ignores and the input commitment includes.

Visibility is the same in both: inputs hashed with the hash public (a Poseidon commitment), outputs public, parameters fixed in the circuit. Both were generated with EZKL 23.0.5, `input_scale = 13`, `param_scale = 13`, `num_inner_cols = 2`, `check_mode = UNSAFE` (from `settings.json`).

## `run_t3_k5_nonces/`: solo circuit, one inference per proof

| Property | Value | Source |
|---|---|---|
| `logrows` | 16 | `settings.json` |
| Rows used | 33,976 | `settings.json` |
| Public inputs | 11: one input commitment, then 10 outputs | `settings.json`, `test/fixtures/Fixtures.sol` |
| Proof size | 3,840 bytes | `test/fixtures/Fixtures.sol` |
| Proving key size | 658,663,971 bytes (not stored) | `measurements/2026-09-28-proving-cost/results.jsonl` |

| File | Bytes | SHA-256 |
|---|---:|---|
| `model.onnx` | 212179 | `c3caeb161859f91da3233830c3f43e5ed9f0c47cdc2913d1a48ffe42a3a51e90` |
| `model.onnx.data` | 210176 | `b96f93301048ea7af8eeaca094fee834111a4c1a3a639f17fb5f61b0b13a2612` |
| `settings.json` | 1656 | `dcae92a6d5fd8435b299b2df1f727a370fbdf9db9461e6d997c7bdd4b94ac6c4` |
| `srs.bin` (fetched, not stored) | 8388868 | `e4690b6479fceefdc2486372ceeaf274d7a336f908463caa619b7bc42ebfe9be` |
| `vk.key` | 157511 | `32439290a76c2ef71fb6f20ef203b001b54d9835b411554bae827df5364e9523` |
| `Halo2Verifier.sol` | 89881 | `5e9000bc433c2750068a876dce558deb97d8073c3368310bc58c9f9d9987784b` |
| `Halo2Verifier.abi` | 266 | `a303ee1076243655bf7c4a8614dfbc8eaf2f4dd72d339bc9909e6d34dd67ce27` |
| `proof.json` | 23192 | `4a7b0536b741027980b82b71e25c7d1fa2bf1b96b15cd6f909026bc6d397c75d` |
| `input.json` | 16266 | `892c2f91fcd78b846e83f510b70db8c7e5480e692c989a3ed8c6e81632cd84c3` |

`proof.json` is the proof stored in `test/fixtures/Fixtures.sol`, in EZKL's own format; `setup_test_fixtures.py` reads it. `input.json` is the input that proof is about: 784 features and the 5 nonce values, as EZKL reads them. Its Poseidon commitment, computed by the client's own code (`clients/ts/bin/check-commitment.ts`, no proving), equals the proof's first public input.

| Identifier | Value |
|---|---|
| `keccak256(vk.key)` | `0x13cff0426abe00c941934bdd6bb7757f2e703fb9f6862bf08a783eeca08b4ff2` |
| Verifier runtime bytecode, bytes | 17992 |
| `keccak256` of the runtime bytecode as pinned (what `EXTCODEHASH` returns) | `0x8cd0b80f6b67e187a9ee98478fdd1278b8e1b666d666d442920aaf911f485f49` |
| `keccak256` of the runtime bytecode with the compiler metadata trailer removed | `0xf60aad67ed7bf1b55cc6cb097b1997036617c161fbaa7f0fd80661c3bfc7b17c` |
| `keccak256` of the stored proof | `0x17b5d583d79a439abefcbd71cb12658ab13966db89e9b1fc8839efccabf0d92c` |

The directory name is historical. An earlier manifest described this circuit as a 530-parameter model with a 329 MB proving key; that was wrong, and the table above is what the files contain.

## `run_mnist_mw_k8/`: batch circuit, eight inferences per proof

| Property | Value | Source |
|---|---|---|
| `logrows` | 19 | `settings.json` |
| Rows used | 298,133 | `settings.json` |
| Lanes | 8 | ONNX inputs `x_0` … `x_7` |
| Public inputs | 88: eight input commitments, then 8 × 10 outputs, lane by lane | `settings.json`, `test/fixtures/FixturesK8.sol` |
| Proof size | 3,840 bytes | `test/fixtures/FixturesK8.sol` |
| Proving key size | 5,269,293,603 bytes (not stored) | `measurements/2026-09-28-proving-cost/results.jsonl` |

| File | Bytes | SHA-256 |
|---|---:|---|
| `model_k8.onnx` | 215425 | `5e02c0f09825aaa62d79ba93e86d7baa933150650a02c3d9307bb9afddd43c0a` |
| `model_k8.onnx.data` | 210176 | `b96f93301048ea7af8eeaca094fee834111a4c1a3a639f17fb5f61b0b13a2612` |
| `settings.json` | 6544 | `a1d03ec48a1751397f55d6ad5888509146ba09f91764ccae5b09afd448402f4c` |
| `srs.bin` (fetched, not stored) | 67109124 | `d1a1655b4366a766d1578beb257849a92bf91cb1358c1a2c37ab180c5d3a204d` |
| `vk.key` | 1247047 | `1ed847e127419bc1d7db2a22779f75284975bf1908b33a43486ca9070e4ef627` |
| `Halo2Verifier_k8.sol` | 89881 | `a843bcddb0aff97560139d92fd74c9bdfb0719e0a2fb8e17c92187e4e6da8636` |
| `Halo2Verifier_k8.abi` | 266 | `a303ee1076243655bf7c4a8614dfbc8eaf2f4dd72d339bc9909e6d34dd67ce27` |

| Identifier | Value |
|---|---|
| `keccak256(vk.key)` | `0xdd03fb0c69e96cc02cbcc6bed8ef51665f934c01cddaf2a855bd1c7fce94675f` |
| Verifier runtime bytecode, bytes | 17990 |
| `keccak256` of the runtime bytecode as pinned (what `EXTCODEHASH` returns) | `0x471c8109f1a03375b17ae6afd421f5857346edf92bf37fce1c7b90a3e02d7ef1` |
| `keccak256` of the runtime bytecode with the compiler metadata trailer removed | `0xd0cab4041caaf77ea95fe45a29d14950be503ce26eb982af11026634112d8c67` |
| `keccak256` of the stored proof | `0xcd9916b6f9155895dba7b9333344331309ea76b69c27b233fd3dab440e404cfe` |

## Which hash identifies the verifier

There are two bytecode hashes per circuit because they answer different questions.

- **The pinned hash** is what the chain sees. The verifier registry in `src/` stores it and re-checks it with `EXTCODEHASH` on every use. To get the same value on another chain, deploy the pinned runtime bytes from `test/fixtures/` as they are; do not recompile.
- **The stripped hash** is what an independent reproduction compares. The generated verifier was compiled with solc's default metadata, which ends the bytecode with a hash that depends on the path the source was compiled from. Two parties who regenerate the verifier from `vk.key`, `settings.json` and `srs.bin` therefore get different raw bytecode and the same stripped bytecode. `test_verifier_bytecode_repro.py` and `test_batch_verifier_bytecode_repro.py` in this folder perform that comparison.

Neither hash proves that the bytecode embeds the verifying key above. Regenerating the verifier from the pinned inputs and comparing the stripped hash is what establishes that link. `scripts/verify_entry.py` does it end to end, against the registry entry of the testnet deployment (`deployments/`): model, pinned settings and SRS → verifying key → verifier source → solc 0.8.20 with the optimizer at 1 run → runtime bytecode, compared with the entry's code without its 53-byte metadata trailer.

## The pinned `settings.json` is part of the circuit's identity

A circuit is identified by its model files, **its pinned `settings.json`** and its SRS together. Settings regenerated from the same model with EZKL's `gen_settings` and `calibrate_settings`, with the same scales, visibility and column count, can list their two range checks in the other order. That gives a circuit of the same size with a different verifying key, and a verifier that costs the same gas but has another code hash (`measurements/2026-11-24-prover/`, "A finding on reproducing the settings"). The mapping from model to verifying key therefore starts from the pinned file, never from a fresh calibration. A field that does not enter the keys can change: with `check_mode` SAFE instead of UNSAFE, the verifying key is byte-identical.

## Where `srs.bin` comes from

`ezkl.gen_srs()` is not deterministic, so these two exact files are needed to regenerate the verifying keys and verifiers to match; nothing else can stand in for them. Everything else is derived from tracked inputs: `vk.key` and the proving key from the ONNX model, the pinned `settings.json` and `srs.bin`; the verifier source from `vk.key`, `settings.json` and `srs.bin`.

They are not committed here because together they are 75 MB. The same bytes are published in the public repository [`achemperety/exactzk-mnistmlp-provenance-demo`](https://github.com/achemperety/exactzk-mnistmlp-provenance-demo), which exists so that anyone can reproduce these verifying keys:

| Here | There | Commit |
|---|---|---|
| `run_t3_k5_nonces/srs.bin` | `solo/srs.bin` | `40e9ca269dfb3d0a4ab53aaf339d5f22c0a1203f` |
| `run_mnist_mw_k8/srs.bin` | `srs.bin` | `b35e0d95b299d3d351b9fdd30455b04f49438885` |

`bash scripts/fetch_srs.sh` downloads both from those commits and keeps a file only if its SHA-256 equals the value in `provenance/SRS.sha256` (the same values as in the tables above). The Foundry tests do not read either file.

These reference strings were generated locally by a single party. They are test parameters, not the output of a public ceremony.

## Regenerating in order

A change to `srs.bin` or `vk.key` must be followed, in this order, by regenerating:

1. the proving key;
2. the verifier source (`Halo2Verifier.sol`, `Halo2Verifier_k8.sol`), because the key's curve points are written into it;
3. the fixtures in `test/fixtures/`, which embed that verifier's bytecode and a proof.

Skipping step 2 or 3 leaves a verifier that deploys, has the right interface and rejects every real proof. `test_fixtures_bytecode_freshness.py` checks step 3.

## Scripts in this folder

| Script | Purpose | Needs |
|---|---|---|
| `export_model.py` | Export the model to ONNX | PyTorch |
| `run_pipeline.py`, `task3_benchmark.py` | Earlier end-to-end EZKL runs and proving benchmarks | EZKL, several GB of memory |
| `setup_test_fixtures.py` | Rebuild `test/fixtures/Fixtures.sol` from `run_t3_k5_nonces/proof.json` and a freshly deployed verifier | EZKL, Anvil, `srs.bin` |
| `test_verifier_bytecode_repro.py`, `test_batch_verifier_bytecode_repro.py` | Regenerate each verifier and compare stripped bytecode hashes | EZKL, Anvil |
| `test_fixtures_bytecode_freshness.py` | Check that the fixtures embed the verifier the pinned key produces | EZKL, Anvil |
| `passport_attest.py` | The two bytecode-hash helpers the scripts above import | |

The scripts were written for the previous repository layout and are carried over for the record. Their references to the previous repository's working notes were replaced by plain descriptions, and two of them had one path changed (see `provenance/README.md`, which lists every changed file with its old and new SHA-256). None of them has been run in this repository yet. The only private key they contain is Anvil's published default account 0.
