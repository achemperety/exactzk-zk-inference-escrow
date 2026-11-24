# Provenance of carried-over files

This repository starts from a new history. The files below were carried over from the private repository that held the previous version, and nothing else was. Each was copied by content and compared with its source by SHA-256 on 2026-11-22, except one input file carried over on 2026-11-24 (marked below).

Three lists of hashes live in this folder:

| File | What it lists | Checked by |
|---|---|---|
| `COPIED_FILES.sha256` | every carried-over file as it is in this repository | `scripts/hygiene_scan.sh`, on every run |
| `SRS.sha256` | the two structured reference strings, which are not stored here | `scripts/fetch_srs.sh`, before it puts a downloaded file in place |
| `SOURCE_ORIGINALS.sha256` | the source repository's version of each file that was changed after copying | nothing here: those versions are not in this repository |

```
shasum -a 256 -c provenance/COPIED_FILES.sha256
```

## What was confirmed against the source repository's own records

- The SHA-256 of `model.onnx`, `settings.json`, `srs.bin` and `vk.key` for both circuits equals the value recorded in the source repository's manifest.
- `keccak256(vk.key)` for both circuits and the metadata-stripped bytecode hash of both verifiers equal the values recorded there.
- `test/fixtures/verifier_runtime.hex` equals the bytecode embedded in `test/fixtures/Fixtures.sol`.
- `circuits/spike-mlp/run_t3_k5_nonces/proof.json` holds the same 3,840-byte proof and the same 11 public inputs as `test/fixtures/Fixtures.sol`.

The values themselves are in `circuits/spike-mlp/MANIFEST.md`.

## Files stored here

43 files, 2,738,205 bytes. "Same path" means the file sits at the same relative path as in the source repository.

| Path | Class | Source path | Bytes | SHA-256 | Change |
|---|---|---|---:|---|---|
| `circuits/spike-mlp/export_model.py` | Circuit script | same path | 1311 | `d02b1e137f188c193c82e4c7c07fe12529735a8dee6c379436cc358276e87706` | byte-identical |
| `circuits/spike-mlp/run_mnist_mw_k8/Halo2Verifier_k8.abi` | Circuit input | same path | 266 | `a303ee1076243655bf7c4a8614dfbc8eaf2f4dd72d339bc9909e6d34dd67ce27` | byte-identical |
| `circuits/spike-mlp/run_mnist_mw_k8/Halo2Verifier_k8.sol` | Circuit input | same path | 89881 | `a843bcddb0aff97560139d92fd74c9bdfb0719e0a2fb8e17c92187e4e6da8636` | byte-identical |
| `circuits/spike-mlp/run_mnist_mw_k8/model_k8.onnx` | Circuit input | same path | 215425 | `5e02c0f09825aaa62d79ba93e86d7baa933150650a02c3d9307bb9afddd43c0a` | byte-identical |
| `circuits/spike-mlp/run_mnist_mw_k8/model_k8.onnx.data` | Circuit input | same path | 210176 | `b96f93301048ea7af8eeaca094fee834111a4c1a3a639f17fb5f61b0b13a2612` | byte-identical |
| `circuits/spike-mlp/run_mnist_mw_k8/settings.json` | Circuit input | same path | 6544 | `a1d03ec48a1751397f55d6ad5888509146ba09f91764ccae5b09afd448402f4c` | byte-identical |
| `circuits/spike-mlp/run_mnist_mw_k8/vk.key` | Circuit input | same path | 1247047 | `1ed847e127419bc1d7db2a22779f75284975bf1908b33a43486ca9070e4ef627` | byte-identical |
| `circuits/spike-mlp/run_pipeline.py` | Circuit script | same path | 10599 | `ab80913a7626246c247eea6b983d89f22885bc3bf4924c346535f6a2a8890b3f` | byte-identical |
| `circuits/spike-mlp/run_t3_k5_nonces/Halo2Verifier.abi` | Circuit input | same path | 266 | `a303ee1076243655bf7c4a8614dfbc8eaf2f4dd72d339bc9909e6d34dd67ce27` | byte-identical |
| `circuits/spike-mlp/run_t3_k5_nonces/Halo2Verifier.sol` | Circuit input | same path | 89881 | `5e9000bc433c2750068a876dce558deb97d8073c3368310bc58c9f9d9987784b` | byte-identical |
| `circuits/spike-mlp/run_t3_k5_nonces/input.json` | Circuit input | same path | 16266 | `892c2f91fcd78b846e83f510b70db8c7e5480e692c989a3ed8c6e81632cd84c3` | byte-identical; carried over on 2026-11-24, after the others: the published input of the stored solo proof (784 features, 5 nonce values) |
| `circuits/spike-mlp/run_t3_k5_nonces/model.onnx` | Circuit input | same path | 212179 | `c3caeb161859f91da3233830c3f43e5ed9f0c47cdc2913d1a48ffe42a3a51e90` | byte-identical |
| `circuits/spike-mlp/run_t3_k5_nonces/model.onnx.data` | Circuit input | same path | 210176 | `b96f93301048ea7af8eeaca094fee834111a4c1a3a639f17fb5f61b0b13a2612` | byte-identical |
| `circuits/spike-mlp/run_t3_k5_nonces/proof.json` | Circuit input | same path | 23192 | `4a7b0536b741027980b82b71e25c7d1fa2bf1b96b15cd6f909026bc6d397c75d` | byte-identical; the proof embedded in `test/fixtures/Fixtures.sol` |
| `circuits/spike-mlp/run_t3_k5_nonces/settings.json` | Circuit input | same path | 1656 | `dcae92a6d5fd8435b299b2df1f727a370fbdf9db9461e6d997c7bdd4b94ac6c4` | byte-identical |
| `circuits/spike-mlp/run_t3_k5_nonces/vk.key` | Circuit input | same path | 157511 | `32439290a76c2ef71fb6f20ef203b001b54d9835b411554bae827df5364e9523` | byte-identical |
| `circuits/spike-mlp/setup_test_fixtures.py` | Circuit script | same path | 9281 | `1be6f57823b6b96c8980c9ec901587e329085182974316303d24e5a4b9c0150b` | fixture directory is `test/fixtures/` here; one printed message no longer names a step of an internal plan |
| `circuits/spike-mlp/task3_benchmark.py` | Circuit script | same path | 11841 | `52fd59f14a4bb67d0f4bdcaf95451292e520e1bdea068c5a57e89773e659b9b6` | byte-identical |
| `circuits/spike-mlp/test_batch_verifier_bytecode_repro.py` | Circuit script | same path | 6842 | `8cb4534719a4d3a49070a194f2ffcef6ab1190d9c3411439ac688ca56c35063e` | references to internal notes replaced by a plain description (comments and printed headings only) |
| `circuits/spike-mlp/test_fixtures_bytecode_freshness.py` | Circuit script | same path | 5645 | `e94d4bd2c7b86f2306526c61f39e76b2a582b13a897662e52ca393001962fce6` | fixture directory is `test/fixtures/` here; references to internal notes replaced |
| `circuits/spike-mlp/test_verifier_bytecode_repro.py` | Circuit script | same path | 9755 | `6b9f065b9ebe7cae6f415daf3487a5c63ae167bb5f26ebe47f6245c594b50683` | references to internal notes replaced by a plain description (comments and printed headings only) |
| `measurements/2026-09-18-steady/fixtures_k8.py` | Measurement | same path | 1991 | `d95ac04577c6a111f5764e97a8777a42b1e606c516491e7156c0de2a7ccf9997` | byte-identical |
| `measurements/2026-09-18-steady/gen_fresh_proof.py` | Measurement | same path | 1953 | `742e33577b810dcccafecbf171361c2edeb4ec8322a08d9277cff972f6ae10e0` | byte-identical |
| `measurements/2026-09-18-steady/harness.py` | Measurement | same path | 10081 | `ef002054e0a4ae4a1c2061670a8573626f9204319bd6850dd90c528c4b278944` | references to internal notes replaced by a plain description (comments and printed headings only) |
| `measurements/2026-09-18-steady/proof2_status.json` | Measurement | same path | 147 | `4a326c40f230d94c9a7795b0490f9a1b15f4e05e226ccd8595cccf9351f27827` | byte-identical |
| `measurements/2026-09-18-steady/results.json` | Measurement | same path | 2169 | `80ac3e698bf7615f99ac93b5f1b4c1de4077eea1ea2dcbf8a21688a4bac74740` | byte-identical |
| `measurements/2026-09-18-steady/run_measurement.py` | Measurement | same path | 10648 | `883e81d3e57f983032bc3a05fb3b588e55d5eb623ffbc48ce115811a9332e467` | references to internal notes replaced by a plain description (comments and printed headings only) |
| `measurements/2026-09-28-k16/gen_srs.py` | Measurement | same path | 528 | `7ed69eccaeca335561dd8ff690268d0c3b17d478a0ad1b2e130634c5cd76dc0b` | byte-identical |
| `measurements/2026-09-28-k16/generate_circuit.py` | Measurement | same path | 4230 | `78a50ccafe30320f0c29b3bdc474fef5ffadcf00d33ea3cac67d27770afe6269` | byte-identical |
| `measurements/2026-09-28-k16/merge_result.py` | Measurement | same path | 591 | `fc011ec0b5a85c23789d2a3b9d3d8c561a989bde11d061cd7d382a65ea64c0b4` | byte-identical |
| `measurements/2026-09-28-k16/price_k16.py` | Measurement | same path | 5621 | `5dbe09c7ed5e1cb4c31b23b018e661b905a3d271dcae8de3e1fc050465012743` | references to internal notes replaced by a plain description (comments and printed headings only) |
| `measurements/2026-09-28-k16/price_k16_results.json` | Measurement | same path | 761 | `49cad063b2234362edc27d90323241b55acf96ab7d16cbcc6f0d6745462bf497` | byte-identical |
| `measurements/2026-09-28-k16/results.jsonl` | Measurement | same path | 2596 | `4db4f06d2645abb66bcda6ea83ffb1870d373de447b4047be8d7f34045bf53c3` | byte-identical |
| `measurements/2026-09-28-k16/run_stage.py` | Measurement | same path | 3440 | `e77fddc79347d653aaa8c1c29159277bf08528c33c2c405ccfbec6106a386038` | byte-identical |
| `measurements/2026-09-28-k16/settle_k16.py` | Measurement | same path | 14839 | `ca6a9239d322a2961dd789cb1bb737cca4024ead431cfe73de4472d95da30819` | byte-identical |
| `measurements/2026-09-28-k16/settle_k16_results.json` | Measurement | same path | 1094 | `49b09a9b12808fad828d9b620940627527c6fad09c26e1aa11aac73db8cf3c8c` | byte-identical |
| `measurements/2026-09-28-proving-cost/merge_result.py` | Measurement | same path | 591 | `fc011ec0b5a85c23789d2a3b9d3d8c561a989bde11d061cd7d382a65ea64c0b4` | byte-identical |
| `measurements/2026-09-28-proving-cost/results.jsonl` | Measurement | same path | 1746 | `19be6880b7bb3def3f9a319226b83c187b6adca735915a3f909e3faef2a803ae` | byte-identical |
| `measurements/2026-09-28-proving-cost/run_all.sh` | Measurement | same path | 1736 | `33815b149277e2de2bc63cc9ace2f91ef229466bcfd5958a70e28ca390aa5138` | byte-identical |
| `measurements/2026-09-28-proving-cost/run_stage.py` | Measurement | same path | 3440 | `e77fddc79347d653aaa8c1c29159277bf08528c33c2c405ccfbec6106a386038` | byte-identical |
| `test/fixtures/Fixtures.sol` | Test fixture | `contracts/test/fixtures/Fixtures.sol` | 46100 | `715c5238b7bda39fd5e613dacc2c715d184f5081fd808356ba13ee670469d730` | byte-identical |
| `test/fixtures/FixturesK8.sol` | Test fixture | `contracts/test/fixtures/FixturesK8.sol` | 52177 | `94461cb2f3a72cb8b272401ffa265e6dfb981528c71d9f42538927d395556395` | two comment lines no longer refer to internal notes; bytecode, proof and instances unchanged |
| `test/fixtures/verifier_runtime.hex` | Test fixture | `contracts/test/fixtures/verifier_runtime.hex` | 35986 | `e6778eeac788d7f472eb2561a05e5a62036db8ccf1d0cfe5bd637b86e3b8d6df` | byte-identical |

## Files changed after copying

Eight files differ from their source. Only comments, docstrings, printed messages and, in two scripts, one directory path changed; no logic, data, bytecode or proof did. The references that were removed pointed to working notes of the previous repository, which are not published.

| Path | SHA-256 in the source repository | SHA-256 here |
|---|---|---|
| `circuits/spike-mlp/setup_test_fixtures.py` | `49d5dafa94d4356e05b3400aff862bf192284ebb61984bf99b134d2903d3e16e` | `1be6f57823b6b96c8980c9ec901587e329085182974316303d24e5a4b9c0150b` |
| `circuits/spike-mlp/test_batch_verifier_bytecode_repro.py` | `dc2c15f48e8f2f64c16e20f278207de7410b873e4ead9fdb4dafbd6f2493a7e0` | `8cb4534719a4d3a49070a194f2ffcef6ab1190d9c3411439ac688ca56c35063e` |
| `circuits/spike-mlp/test_fixtures_bytecode_freshness.py` | `7c4a26ba92794318e1e37447cde5184c3e8791483334b15972ddfa66fb31912e` | `e94d4bd2c7b86f2306526c61f39e76b2a582b13a897662e52ca393001962fce6` |
| `circuits/spike-mlp/test_verifier_bytecode_repro.py` | `d76dc09522c563a5428a975557052a3afeba8a071c89e80d87a445aa20cc184f` | `6b9f065b9ebe7cae6f415daf3487a5c63ae167bb5f26ebe47f6245c594b50683` |
| `measurements/2026-09-18-steady/harness.py` | `b6bda0c7c2281a3d31b259243652de395806a092e5c1b90472f9b1fba107d382` | `ef002054e0a4ae4a1c2061670a8573626f9204319bd6850dd90c528c4b278944` |
| `measurements/2026-09-18-steady/run_measurement.py` | `a35da2878d36005798c0d16c72eaa803bf3f8ed36bdd012dd08ac52253e4e31e` | `883e81d3e57f983032bc3a05fb3b588e55d5eb623ffbc48ce115811a9332e467` |
| `measurements/2026-09-28-k16/price_k16.py` | `3a5382b516a94fa75897f76a018ebd08beff4b08536135e20a47bc7fa7e53ae1` | `5dbe09c7ed5e1cb4c31b23b018e661b905a3d271dcae8de3e1fc050465012743` |
| `test/fixtures/FixturesK8.sol` | `10bb2f130b6383a8c62d8c1c40d2ac953a8bda2c1403e859aeb4b626edefc6cd` | `94461cb2f3a72cb8b272401ffa265e6dfb981528c71d9f42538927d395556395` |

## Not stored: the structured reference strings

`circuits/spike-mlp/run_t3_k5_nonces/srs.bin` (8,388,868 bytes) and `circuits/spike-mlp/run_mnist_mw_k8/srs.bin` (67,109,124 bytes) are byte-identical to the copies published in the public repository `achemperety/exactzk-mnistmlp-provenance-demo` (`solo/srs.bin` and `srs.bin`). They are not committed here. `bash scripts/fetch_srs.sh` downloads both from fixed commits of that repository and keeps a file only if its SHA-256 equals the value in `SRS.sha256`. No test reads them.

## Left behind on purpose

- Contracts and their tests: rewritten here, not copied.
- Proving keys, witnesses, compiled circuits and raw logs: large or regenerable.
- Deployment scripts, deployment records and any file naming a deployed address.
- Working notes and design documents.

## Added here, not copied

`circuits/spike-mlp/passport_attest.py` holds two small helper functions that three of the copied scripts import. It was written for this repository.
