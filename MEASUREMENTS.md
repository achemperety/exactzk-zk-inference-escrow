# Measurements

Every gas figure of version 3, next to the previous version's figure for the same job where one exists. Re-run on the final code on 2026-11-24. Method, breakdowns and the tests behind each row are in the folders under `measurements/`. The testnet rows are receipts from Base Sepolia, each with its transaction hash in `measurements/2026-11-24-testnet/`.

## How the figures were taken

- **Local (version 3).** `forge test`, Osaka gas schedule. `test/GasMeter.sol` rebuilds a transaction's gas from its parts: 21,000, plus calldata at 4 and 16 gas per zero and non-zero byte (or the EIP-7623 floor, when higher), plus the call frame's execution, minus the capped refund. Every account the call touches starts cold. "Test token" is the repository's ERC-3009 mock. "USDC" is Circle's USDC on a fork of Base Sepolia at block 62,638,490. A batch never calls the token, so its gas is the same with either. Gas does not depend on the machine.
- **Testnet (version 3).** Receipts of transactions against the deployment, read back with `cast receipt`. They differ from the local figures by calldata bytes, and by 2,500 when the payer also sends the transaction; `measurements/2026-11-24-testnet/` accounts for both, to the unit where it can.
- **Previous version (v2).** Receipts on a local Anvil node (2026-09) and on Base Sepolia, from this repository's carried-over result files. Those files do not record the gas schedule. HYPOTHESIS: the Anvil runs used a schedule from before Osaka, Anvil's default at the time. The same pinned verifiers, measured here, cost **8,097 gas more per proof verification under Osaka**: solo 577,544 against 569,447, K=8 635,807 against 627,710, K=16 702,349 against 694,252, the same under Prague and Cancun. The "v2 at Osaka" column adds 8,097 to each transaction that verifies one proof. That is exact for the verifier, and nothing else these contracts do is priced differently. For the Base Sepolia run of v2, it is not known whether the testnet already priced modexp as Osaka does, so that row shows both.

## Headline: version 2 against version 3

| Job | v2 as measured | v2 at Osaka | v3, Osaka | v3 against v2 at Osaka | Sources |
|---|---:|---:|---:|---:|---|
| **Solo, one request:** v2 `open` + `settle`; v3 one-transaction `settle`, steady, USDC | 953,756 (Base Sepolia, 2 transactions: 248,838 + 704,918) | 953,756 or 961,853 | **768,174** | −185,582 to −193,679 (−19.5% to −20.1%) | v2: `measurements/2026-11-23-solo-settlement/`; v3: `test/SoloSettlementFork.t.sol` |
| Solo, v3 escrow flow (`open` + `release`), steady, USDC | (as above) | 953,756 or 961,853 | 841,293 (116,231 + 725,062) | −112,463 to −120,560 (−11.8% to −12.5%) | the same |
| **K=8 batch, real proof, steady, eight channels** | 1,111,371 (Anvil) | 1,119,468 | **909,289** | −210,179 (−18.8%) | v2: `measurements/2026-09-18-steady/results.json`; v3: `test/ChannelSettlementGas.t.sol` |
| per request | 138,921.4 | 139,933.5 | **113,661.1** | | |
| **K=16 batch, real proof, steady, sixteen channels** | 1,542,409 (Anvil) | 1,550,506 | **1,137,050** | −413,456 (−26.7%) | v2: `measurements/2026-09-28-k16/settle_k16_results.json`; v3: `test/ChannelSettlementK16Gas.t.sol` |
| per request (acceptance target: at most 73,100, that is 1,170,000 per batch) | 96,400.6 | 96,906.6 | **71,065.6** | **met** | |

## First-time rows, kept separate

A balance or accrual that goes from zero to non-zero is a 20,000-gas storage write instead of 2,900 (and 22,100 instead of 5,000 in a token). These rows happen once per provider, per payer or per contract.

| Job | v2 as measured | v2 at Osaka | v3, Osaka | Sources |
|---|---:|---:|---:|---|
| Solo `settle`, first payment to the provider, USDC | | | 785,274 | `test/SoloSettlementFork.t.sol` |
| Solo escrow, `open` when the contract holds no USDC, USDC | | | 133,331 | the same |
| Solo escrow, `release`, first payment to the provider, USDC | | | 737,362 | the same |
| K=8 batch, eight new channels, the provider's first accrual (v2: its first batch) | 1,265,247 (Anvil) | 1,273,344 | 926,389 | v2: `measurements/2026-09-18-steady/results.json`; v3: `test/ChannelSettlementGas.t.sol` |
| K=8 batch, eight new channels, provider paid before | | | 909,289 | the same |
| K=16 batch, sixteen new channels, the provider's first accrual (v2: its first batch) | 1,833,193 (Anvil) | 1,841,290 | 1,154,162 | v2: `measurements/2026-09-28-k16/settle_k16_results.json`; v3: `test/ChannelSettlementK16Gas.t.sol` |
| per request | 114,574.6 | 115,080.6 | 72,135.1 | |

In version 2 the first batch paid 17,100 per frame, because each channel's cumulative-amount slot went from zero. In version 3 it pays 17,100 per batch, for the provider's accrued balance only.

## Batches from one channel (version 3 only)

| Batch, real proof, one channel | First (the provider's first accrual) | Steady | Steady per request |
|---|---:|---:|---:|
| K=8 | 878,033 | 860,957 | 107,619.6 |
| K=16 | 1,050,182 | 1,033,130 | 64,570.6 |

## K-sweep, contract cost (version 3 only)

The EZKL adapter with a target that accepts everything, so the figures are the contract's cost and the adapter's, without a real verifier. The 3,840-byte K=8 proof is the filler, and every lane is a different channel of a different payer (`test/ChannelSettlementGas.t.sol`, `ChannelSweep*`; method in `measurements/2026-11-23-channel-settlement/`).

| K | 1 | 2 | 4 | 8 | 16 | 32 |
|---|---:|---:|---:|---:|---:|---:|
| First batch | 209,490 | 227,460 | 260,520 | 334,360 | 476,210 | 767,806 |
| Steady | 209,490 | 227,430 | 260,490 | 334,330 | 476,210 | 759,910 |

Where the two rows are equal, the EIP-7623 calldata floor sets the transaction's price, not its execution. Over K from 1 to 32, each further voucher in a batch costs 12,719 gas of execution and about 7,100 of calldata.

## The verifiers alone

Gas inside `verifyProof` for the stored proofs; the registry's entry gives the adapter about 4% more.

| Verifier | Osaka | Prague or Cancun | Entry's `verifyGas` |
|---|---:|---:|---:|
| Solo (pinned) | 577,544 | 569,447 | 600,000 |
| K=8 (pinned) | 635,807 | 627,710 | 660,000 |
| K=16 (regenerated from its key; measurement only) | 702,349 | 694,252 | 730,000 |

### The proof check on top of the verifier

Gas used on top of the generated verifier's own `verifyProof`, measured in `forge test` (Osaka) by the tests that pin these figures (`test/Halo2EzklAdapter.t.sol`, `test/ProofCheck.t.sol`):

| | Solo | K=8 |
|---|---:|---:|
| Adapter alone, verifier account already touched | 2,959 | 5,441 |
| Adapter alone, first touch of the verifier account | 5,459 | 7,941 |
| Whole check through `ProofCheck`, entry supplied by the caller | 17,429 | 20,435 |
| Whole check through `ProofCheck`, entry read from the registry | 28,320 | 31,325 |

Of the 17,429 and 20,435, 9,900 is the first touch of three accounts and one storage slot. Reading the entry from the registry instead adds five more storage slots.

The K=16 verifier is not one of the two pinned circuits. It is the September K=16 circuit's verifier, regenerated from that circuit's existing verifying key: the source came out byte-identical to the one generated then, and it accepts the proof stored with that key. It is used only by `test/ChannelSettlementK16Gas.t.sol` (`measurements/2026-11-24-k16/`), and is neither registered nor deployed on any network.

## Testnet (version 3, Base Sepolia)

| Transaction | Gas | Local figure (Osaka) |
|---|---:|---:|
| `settle`, steady | 766,226 | 768,174 |
| `settle`, first payment to the payee | 783,326 | 785,274 |
| `open` + `release`, steady | 839,705 | 841,293 |
| `openChannel`, steady | 115,723 | 117,919 |
| K=8 batch, one channel, first | 877,463 | 878,033 |
| K=8 batch, one channel, steady | 860,315 | 860,957 |
| The deployment, 13 transactions | 16,869,040 | |

Hashes, blocks and the reconciliation are in `measurements/2026-11-24-testnet/`. Not measured on the testnet yet: batches across eight or sixteen channels, which need as many funded payers.

## Other version 3 transactions

Steady unless marked. "Test token" and "USDC" as above.

| Transaction | Test token | USDC | Measured in |
|---|---:|---:|---|
| Solo one transaction: `settle` | 747,528 | 768,174 | `test/SoloSettlementGas.t.sol`, `test/SoloSettlementFork.t.sol` |
| Solo escrow: `open`; `release` | 97,978; 714,216 | 116,231; 725,062 | the same |
| Solo escrow: `open` + `release` | 812,194 | 841,293 | the same |
| `openChannel`; first deposit the contract holds | 99,619; 116,719 | 117,919; 135,019 | `test/ChannelSettlementGas.t.sol`, `test/ChannelSettlementFork.t.sol` |
| `withdraw`, all but one unit; everything, the provider's first tokens | 44,747; 57,035 | 55,593; 67,881 | the same |
| `requestClose`; `challengeClose` | 52,541; 41,243 | 52,541; 41,243 | `test/ChannelCloseGas.t.sol`, `test/ChannelSettlementFork.t.sol` |
| `finalizeClose`, nothing held; with a hold | 48,522; 48,685 | 59,368; 59,531 | the same |
| `sweepExpiredHold` | 48,090 | 58,936 | the same |
| `waive`, open channel; held channel | 39,088; 57,107 | 39,076; 67,929 | the same |
| Solo `refund` | 46,605 | 57,451 | `test/SoloSettlementGas.t.sol`, `test/SoloSettlementFork.t.sol` |
| ERC-8183 `setTerms`; `forfeit`, steady | 97,317; 78,840 | | `test/StandardsGas.t.sol` |
| ERC-8183 `evaluate`, steady, evaluator fee forwarded; without a fee | 769,085; 760,498 | | the same |
| ERC-8004 `respond`: first answer, 100; first answer, 0; answered before | 803,767; 783,939; 724,184 | | the same |
| x402 auth-capture: `authorize` + `captureWithProof` | 862,189 | 895,250 | `test/AuthCaptureGas.t.sol` |
| x402 auth-capture: `chargeWithProof` | 812,420 | 836,981 | the same |
| x402 auth-capture, proof policy: `authorize` + `captureWithPolicy` | 866,257 (126,385 + 739,872) | 899,361 (148,643 + 750,718) | `test/ProofCapturePolicyGas.t.sol` |
| x402 auth-capture, proof policy: `chargeWithPolicy` | 816,774 | 841,355 | the same |
| x402 batch-settlement claim gate (PROTOTYPE): `claimWithProof`, payee paid in the claim, steady; the channel's first claim | 793,491; 841,297 | not measured | `test/experimental/batch-gate/ProofClaimGate.t.sol` |

The proof policy against the terms-authorizer operator, steady, test token: `captureWithPolicy` 739,872 = 21,000 + 72,280 call data + 646,592 execution; `captureWithProof` 735,804 = 21,000 + 71,696 + 643,108. The 4,068 difference is 584 of call data and 3,484 of execution: `policyData` is one ABI-encoded `bytes` argument decoded into memory, and the check is one more call, into the policy. `chargeWithPolicy` against `chargeWithProof`: 596 and 3,758, 4,354 in all. The gate's claim, test token: first 797,428 = 21,000 + 76,272 + 700,156; steady 769,210 = 21,000 + 75,760 + 672,450. Every account cold, as above; the gate's channel contract is x402's, built with this repository's compiler settings (`test/external/README.md`).

The first-time rows of these transactions are in the measurement folders named. Of each `settle`, `release`, `evaluate` and `respond`, 577,544 is the generated solo verifier and 13,213 the rest of the proof check (registry, adapter, code-hash reads).

## Calldata floor on the testnet

Base Sepolia applies EIP-7623's calldata floor: a transaction is charged at least 10 gas per calldata token (a zero byte, or a quarter of a non-zero byte). `scripts/calldata_floor_check.py`, read-only, found two data-carrying transactions to accounts without code in two scans of 100 and 600 recent blocks (63,007,256 to 63,007,355 and 63,007,604 to 63,008,203). Each used exactly 21,000 plus the floor (21,360 and 22,490), not the standard price (21,144 and 21,596). `test/GasMeter.sol` already prices every figure above this way. Among them, the K-sweep rows where first batch and steady are equal are set by the floor.

## Proving cost

Proving does not run on the Mac. Every figure below comes from 2 vCPUs of an Intel Xeon Gold 5220R at 2.20 GHz. They are not comparable with proving times measured earlier on other machines.

| Solo circuit, canonical keys | Time | Peak memory | Source |
|---|---:|---:|---|
| Key setup from the pinned settings (verifying key byte-identical to the pinned one) | 18.25 s | 960 MB | `measurements/2026-11-24-prover/` |
| Witness | 0.23 to 0.29 s | | the same |
| Proof, first in the process | 20.10 s | 1,393 MB | the same |
| Proofs 2 to 6 in the same process | 19.90 to 20.42 s | 1,409 MB | the same |
| The same with `check_mode` SAFE (verifying key byte-identical) | 20.41 s | 1,398 MB | the same |

The K=8 and K=16 provers were not run on that machine: a K=8 proof peaked at 12.8 GB in an earlier measurement (`measurements/2026-09-28-proving-cost/`).

### Checking a registry entry from the published files

`scripts/verify_entry.py`, on the same machine, the same day (`measurements/2026-11-24-verify-entry/`). Every run compared its result with the testnet registry entry, read-only.

| Run | Result | Time | Peak memory |
|---|---|---:|---:|
| Solo: model, pinned settings, SRS → key → verifier → chain | MATCH | 21.68 s (key setup 18.00 s) | 996 MB |
| Solo from the published key | MATCH | 3.56 s | 125 MB |
| K=8 from the published key | MATCH | 8.14 s | 742 MB |
| Solo with the two range checks of `settings.json` swapped | MISMATCH, as it must | 21.12 s | 1,012 MB |

The K=8 key setup was not run: measured on a Mac in September at 15.1 s and 6.35 GB peak (`measurements/2026-09-28-proving-cost/results.jsonl`), it was not run on that machine.

## Second proof system (EXPERIMENTAL, preliminary)

A Groth16 version of the same model (`measurements/experimental/groth16/`), EXPERIMENTAL. Two caveats apply to every figure here:
- **Its trusted setup is a single-party local setup, insecure for anything but measurement.** Nothing from it is deployed or registered.
- **It does not prove the same statement.** Its input commitment is gnark's Poseidon2, not the canonical EZKL Poseidon commitment, so a payment signed for one cannot be settled with the other's proof.

Its outputs equal EZKL's on 25 of 25 inputs.

| Solo, Osaka | Groth16 prototype | Canonical Halo2 |
|---|---:|---:|
| Proof time, 2 vCPUs (Xeon Gold 5220R) | 3.35 s (mean of 25) | 20.10 s |
| Proof size | 256 bytes | 3,840 bytes |
| Adapter and verifier | 265,728 | 577,544 (verifier alone) |
| `settle`, steady, test token | 372,965 | 747,528 |
| `settle`, steady, USDC | ≈ 393,611 (derived, not measured: test token + 20,646) | 768,174 |

K=16 with this verifier is projected, not measured, at about 48,400 gas per request with packed outputs, and about 105,000 without packing. Both are HYPOTHESIS; the folder gives the arithmetic.
