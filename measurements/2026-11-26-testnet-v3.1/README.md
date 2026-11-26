# Testnet gas: version 3.1 on Base Sepolia, 2026-11-26

Gas of real transactions against the v3.1 deployment (`deployments/base-sepolia-v3.1.json`, deployed from commit `e1beaa7`), with Circle's testnet USDC and the stored proofs. Version 3.1 is the fix for [docs/known-issues/2026-11-out-of-gas-as-invalid.md](../../docs/known-issues/2026-11-out-of-gas-as-invalid.md). Every figure is a receipt's `gasUsed`, read again from the chain's public endpoint, and every transaction succeeded. The gas price was 0.006 gwei throughout.

The method is the one in `measurements/2026-11-24-testnet/`. The same programs sent the same kinds of transaction: the quickstart (`quickstart.sh`, run twice) and `clients/ts/bin/measure.ts escrow` and `batch`. They were sent from a new throwaway key that is both the payer and the sender, and they paid the same testnet-only payee. Each row is set next to the same transaction of v3.0.

## Figures

| Transaction | Hash | Block | v3.1 | v3.0 | Difference | of which call data | of which the rest |
|---|---|---:|---:|---:|---:|---:|---:|
| `SoloSettlement.settle`, the contract's first payment | `0xd0078e7cabb81264623db8c2970af7e1dc34c5b2841db40a4c19ce1539b7ac97` | 64,048,150 | 766,319 | 783,326 (the payee's first payment) | see below | 0 | |
| `SoloSettlement.settle`, steady | `0xd01f4be4fe808b6bc07ef4ef0e94bec2cc989737c25f3e8c32011116ab566f18` | 64,048,194 | 766,295 | 766,226 | +69 | −24 | +93 |
| `SoloSettlement.open`, steady | `0x947d56898e5f8e91028fea0dcc7b18dae3994ece2bf758c0cac1b1fe57554b28` | 64,048,209 | 114,091 | 114,091 | 0 | 0 | 0 |
| `SoloSettlement.release`, steady | `0x6cc19080e5606ec230e5c105e28e0746a9ebeaa8d57b95dee742bed5016074ac` | 64,048,216 | 725,707 | 725,614 | +93 | 0 | +93 |
| `ChannelSettlement.openChannel`, steady | `0x3bd7d6f85607144817cd447a753ab3f5283bcc9ab0c8f5f765dd8b172d886729` | 64,048,252 | 115,719 | 115,723 | −4 | −24 | +20 |
| `ChannelSettlement.settleBatch`, K=8, one channel, vouchers 1–8, the provider's first accrual in the channel | `0x08f3ca6395e11052a2e24cc74b8b338f0abc717a9c9ef5e1062ac3bcc79f0e95` | 64,048,259 | 877,564 | 877,463 | +101 | −12 | +113 |
| `ChannelSettlement.settleBatch`, K=8, the same channel, vouchers 9–16, steady | `0x7d190953625a188e2f720c07e705172e46c44002ccae59f0835390ebfb1f1984` | 64,048,266 | 860,404 | 860,315 | +89 | −24 | +113 |

The escrow flow, `open` and `release`, cost 839,798 in two transactions (v3.0: 839,705). The one-transaction flow cost 766,295 steady (v3.0: 766,226).

"Call data" counts each transaction's input at 4 and 16 gas per zero and non-zero byte. The inputs differ only in random salts, signatures and the verifier id. "The rest" is the receipt less that.

## Where the difference comes from

Both versions run the same verifier on the same proof. The verifier's call frame is identical in each pair: 569,447 for solo and 627,710 for K=8. A replay of the two steady batches and the two `release` transactions with `cast run` splits the rest:

- **+44 in the adapter.** `Halo2EzklAdapterV2.verify` used 572,450 against `Halo2EzklAdapter`'s 572,406 (solo), and 633,195 against 633,151 (K=8). It records `gasleft()` before calling the verifier.
- **+49 in `SoloSettlement`, +69 in `ChannelSettlement`.** This is the check's own classification: it measures the gas the adapter used and compares it with the entry's allowance. The local sweep in `test/ChannelSettlementGas.t.sol`, which uses a stand-in adapter, rose by the same 69 when the check changed.

So `release` is +93 = 44 + 49, and each batch is +113 = 44 + 69. `settle` has the same +93 as `release`: they run the same check in the same contract.

`open` does not verify, and it is identical to the unit. `openChannel` does not verify either. It is 20 higher in execution, with a different random salt and signature; this was not broken down further.

The first `settle` through the v3.1 contract is not comparable with v3.0's first row. v3.0's first payment was also the payee's first USDC, which costs a zero-to-non-zero balance write. By v3.1 the payee already held USDC, so the first and the steady `settle` differ only by 24 gas of call data. Their execution is the same, 694,019.

## Local figures on the same code

`forge test`, Osaka schedule, on main at `e1beaa7`; the fork tests with `FORK_RPC_URL=https://sepolia.base.org FORK_BLOCK=62638490`:

| Job | v3.0 | v3.1 | Test |
|---|---:|---:|---|
| `settle`, USDC, steady | 768,174 | 768,267 | `test/SoloSettlementFork.t.sol` |
| `release`, USDC, steady | 725,062 | 725,155 | the same |
| K=8 batch, one channel, steady | 860,957 | 861,094 | `test/ChannelSettlementGas.t.sol` |
| K=8 batch, eight channels, steady | 909,289 | 909,342 | the same |
| K=16 batch, sixteen channels, steady | 1,137,050 | 1,137,131 | `test/ChannelSettlementK16Gas.t.sol` |
| `authorize` + `captureWithProof`, USDC | 895,250 | 895,352 (148,612 + 746,740) | `test/AuthCaptureGas.t.sol` |
| `authorize` + `captureWithPolicy`, USDC | 899,361 | 899,410 (148,611 + 750,799) | `test/ProofCapturePolicyGas.t.sol` |
| `batch-settlement` claim gate, one claim, steady, test token | 793,491 | 793,587 | `test/experimental/batch-gate/ProofClaimGate.t.sol` |
| ERC-8183 `evaluate`, test token, steady | 769,085 | 769,173 | `test/StandardsGas.t.sol` |

The testnet figures differ from the local ones as in v3.0: by call data, and by 2,500 where the payer also sends the transaction (`measurements/2026-11-24-testnet/`). For example, 768,267 − 2,500 + 528 of call data = 766,295.

## The deployment itself

The deployment was 9 transactions in blocks 64,043,944 to 64,043,988, using 7,504,813 gas. It cost 0.0000392 ETH, of which 0.0000011 ETH was L1 data fees. The hashes are in `deployments/base-sepolia-v3.1.json`.
