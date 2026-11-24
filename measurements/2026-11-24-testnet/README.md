# Testnet gas: the deployment on Base Sepolia, 2026-11-24

Gas of real transactions against this repository's Base Sepolia deployment (`deployments/base-sepolia.json`, deployed from commit `07d7e1c`), with Circle's testnet USDC and the stored proofs. Every figure is a receipt's `gasUsed`, read again from the chain's public endpoint with `cast receipt <hash> --rpc-url https://sepolia.base.org`; every transaction succeeded. The gas price was 0.006 gwei throughout; the L1 data fee of each was between 275 and 4,784 wei.

The transactions were sent by the quickstart (`quickstart.sh`) and `clients/ts/bin/measure.ts`, from the quickstart's throwaway key. That account is both the payer and the sender of each transaction. The payee is the testnet-only account in `deployments/base-sepolia-quickstart.json`.

## Figures

| Transaction | Hash | Block | Gas | Local figure | Difference |
|---|---|---:|---:|---:|---:|
| `SoloSettlement.settle`, first payment to the payee | `0x7387e2b54b7d8c2150aafa40263dd84d7d6403aa562ac865d1d11467b5454461` | 62,983,372 | 783,326 | 785,274 | −1,948 |
| `SoloSettlement.settle`, steady | `0xb16a286f8d2305799f9e8f218d334d3d69b3e29dd45c56a497ef18d5375ce50b` | 62,984,464 | 766,226 | 768,174 | −1,948 |
| `SoloSettlement.open`, steady | `0x38eefe0c8722c6d833f16e09c1420987107c970dfd55f23cf9a6ee18f35dbf8d` | 62,984,479 | 114,091 | 116,231 | −2,140 |
| `SoloSettlement.release`, steady | `0xbb4a19fde8033f6db7bcf867f2040a9c6da51d481c0aaf0e1d645af1baec094e` | 62,984,485 | 725,614 | 725,062 | +552 |
| `ChannelSettlement.openChannel`, steady | `0xb906fd866d6dafa06ef67bb706a895611c199d4401a21d80250430f24d9dbcc3` | 62,984,519 | 115,723 | 117,919 | −2,196 |
| `ChannelSettlement.settleBatch`, K=8, one channel, its vouchers 1–8, the payee's first accrual | `0xc5190aa38691eaf655138341988324cad41bc146f0495494b116fa9e5cefde73` | 62,984,525 | 877,463 | 878,033 | −570 |
| `ChannelSettlement.settleBatch`, K=8, the same channel, vouchers 9–16, steady | `0x771d3e2c4bd4e7f0d0018543aa0a786e3a9ad2b23673c4e5b4cff3611740913a` | 62,984,530 | 860,315 | 860,957 | −642 |

The escrow flow, `open` and `release`, cost 839,705 in two transactions; the one-transaction flow 766,226 steady.

"Local figure" is the same transaction measured in `forge test` under the Osaka gas schedule before the deployment: `measurements/2026-11-23-solo-settlement/` (USDC on a fork) for `settle`; `docs/deployment-notes.md` for `open` and `openChannel` (USDC on a fork, the contract already holding USDC); the escrow flow's 841,293 (`measurements/2026-11-24-x402-auth-capture/`) less that `open` for `release`; the pinned `ChannelSettlementGas` tests for the one-channel batches (878,033 and 860,957, re-run on the final code on 2026-11-24; a batch's gas does not depend on the token). All local figures are the final code's, re-run on 2026-11-24 (`MEASUREMENTS.md`).

## Why the figures differ from the local ones

For the four `SoloSettlement` transactions the difference is accounted for to the unit by two things:

- **Calldata.** The testnet transactions carry different bytes: a random salt, a different amount, different signatures. Counting zero and non-zero bytes of each transaction's input at 4 and 16 gas, `settle` pays 72,300 against the local measurement's 71,748 (+552), `release` 70,668 against 70,116 (+552), `open` 4,652 against 4,292 (+360).
- **The payer sent the transaction.** In the local measurements the payer and the sender are different accounts, and every account starts cold. Here they are the same account, which is warm from the start of the transaction. The difference is 2,500 gas (a cold account access costs 2,600, a warm one 100) in exactly the three transactions that call USDC's `receiveWithAuthorization` (`settle`, `settle`, `open`), and not in `release`, which does not. USDC checks whether the payer has code before it checks the signature, and that check is what touches the payer's account. The arithmetic is exact; the mechanism is the explanation that fits all four.

So: 785,274 + 552 − 2,500 = 783,326; 768,174 + 552 − 2,500 = 766,226; 116,231 + 360 − 2,500 = 114,091; 725,062 + 552 = 725,614.

The same accounting also shows that Base Sepolia charges the verifier's three modexp calls as the Osaka schedule does, which the local measurements assumed. A rehearsal of the same transactions on a local fork of Base Sepolia, with Anvil's default schedule rather than Osaka, came out 8,049 to 8,121 gas lower in every transaction that runs the verifier, and identical (114,091) for `open`, which does not.

`openChannel` is 2,196 lower, consistent with the same 2,500 and 304 more calldata; the local measurement's calldata was not broken down, so this one is not confirmed to the unit. The two batches are 570 and 642 lower. A batch does not call the token, and its vouchers are verified by signature recovery, which does not touch the payer's account, so the difference is calldata: the vouchers' amounts, deadlines and signatures and the channel's 32-byte salt differ from the local test's. It was not broken down.

## The deployment itself

13 transactions, 16,869,040 gas, 0.000101 ETH including 29,063 wei of L1 data fees (blocks 62,968,700 to 62,968,830). Per contract, see `docs/deployment-notes.md`.
