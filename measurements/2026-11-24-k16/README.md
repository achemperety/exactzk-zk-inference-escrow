# K=16 batches with the real proof, 2026-11-24

Gas of `ChannelSettlement.settleBatch` at K=16 with a real proof, under the Osaka schedule (`test/ChannelSettlementK16Gas.t.sol`, method as in `measurements/2026-11-23-channel-settlement/`). It answers the acceptance question for K=16: at most 1,170,000 gas for a steady batch, 73,100 per request, against 96,400.6 for the previous version. Nothing was proved, and no key was made.

## Where the verifier and the proof come from

The K=16 batch circuit (sixteen inferences per proof, the same 52,650-parameter model, logrows 20) is not one of the two pinned circuits in `circuits/spike-mlp/MANIFEST.md`. Its verifying key and a proof made with that key were produced for the 2026-09-28 K=16 measurement (`measurements/2026-09-28-k16/`) and kept outside this repository. On 2026-11-24:

1. The verifier source was regenerated from that verifying key with EZKL 23.0.5 (`create_evm_verifier`, no proving). It is byte-identical to the source generated in September.
2. EZKL deployed it on a local node (`deploy_evm`, its own compilation path). The runtime code, 17,991 bytes with keccak256 `0xba70c4c8…bf60`, is stored in `test/fixtures/FixturesK16.sol` with the stored proof (3,840 bytes) and its 176 public inputs: 16 input commitments, then 16 × 10 outputs.
3. The tests register it as a 16-lane entry with a gas allowance of 730,000, about 4% above the 702,349 it uses, as for the pinned entries. The entry exists only in the tests; it is not registered or deployed on any network.

SHA-256 of the source files, as in the fixture's header:

| File | SHA-256 |
|---|---|
| `vk.key` | `533045deb1e157d0aa516dbe6e7b45f845f8f4b957edc06b6c090902a832bcc0` |
| `settings.json` | `e29fb79f53fba2739863faa34229dbc189e8618c09c0734e763bccbb95d6272a` |
| `proof.json` | `5dc7f0dcba82e5498e7a5af5d9afbcd0f39b3a906e0f86c140d602cf6b9554b7` |
| `Halo2Verifier_k16.sol` | `225dc2135dde265e6c8951708b05d75b6dd4230e0e723d39b4e665dc43d1de3a` |

Verifier generation ran on the Mac (Apple M4 Pro): 3.4 s, peak memory 1.49 GB.

## Figures

| Batch, K=16, real proof | Gas | Per request |
|---|---:|---:|
| Sixteen channels, steady | **1,137,050** | **71,065.6** |
| Sixteen new channels, the provider's first accrual | 1,154,162 | 72,135.1 |
| One channel, sixteen of its vouchers, steady | 1,033,130 | 64,570.6 |
| One channel, its first sixteen vouchers, the provider's first accrual | 1,050,182 | 65,636.4 |

**Acceptance: met.** 1,137,050 is 32,950 under 1,170,000, and 71,065.6 per request is 26.3% below the previous version's 96,400.6 (26.7% below it at the Osaka schedule; `MEASUREMENTS.md`). The held option of passing the provider and the asset once per batch (`docs/deployment-notes.md`) is therefore not applied.

Where the steady batch's gas goes: calldata 183,352 (the proof's 3,840 bytes, 176 public inputs, sixteen configs and frames), execution 932,698 (the verifier itself 702,349), intrinsic 21,000. The verifier costs 8,097 gas more under Osaka than under Prague, the same as the solo and K=8 verifiers.

The first and steady rows of the sixteen-channel batch differ by 17,112. Of that, 17,100 is the provider's accrued balance going from zero; the 12 left over is calldata, because the vouchers and their signatures differ.
