# Channel settlement gas, 2026-11-23

Gas of `ChannelSettlement` transactions (`src/ChannelSettlement.sol`), measured in `forge test` under the Osaka gas schedule. The tests that produce these figures are `test/ChannelSettlementGas.t.sol` (test token, runs in CI, figures pinned) and `test/ChannelSettlementFork.t.sol` (Circle's USDC on a fork of Base Sepolia at block 62,638,490, opt-in, figures logged). Nothing here was sent to a chain.

## Method

The same as for solo settlement (`measurements/2026-11-23-solo-settlement/`): a transaction's gas is rebuilt by `test/GasMeter.sol` as 21,000, plus calldata at 4 gas per zero byte and 16 per other byte (or the EIP-7623 floor of 10 and 40, when that is higher), plus the gas used by the call frame, minus the storage refund capped at a fifth. Each measured call is the first thing its test does; the channels, earlier batches and balances it depends on are created in `setUp`, a separate transaction, and its calldata is built there or from the test contract's own storage.

Every lane of a batch is a different channel of a different payer, unless the row says one channel. Signatures are 65-byte ECDSA signatures; channel salts are short.

- **First**: the channels' first vouchers, and the provider's accrued balance starts at zero.
- **New channels, provider paid before**: the channels' first vouchers; the provider's accrued balance is already non-zero.
- **Steady**: the same channels' next vouchers; the provider's accrued balance is non-zero.

## K=8, the stored proof

| Batch | Test token | USDC (fork) | Limit |
|---|---:|---:|---:|
| Eight channels, steady | **909,185** | 909,185 | 915,000 |
| Eight new channels, provider paid before | 909,185 | | |
| Eight new channels, provider's first accrual | 926,285 | | |
| One channel, eight of its vouchers, steady | 860,853 | | |
| One channel, its first eight vouchers, provider's first accrual | 877,929 | | |

Per request, steady: 113,648 with eight channels and 107,607 with one, against 138,921 for the previous version (1,111,371 per K=8 batch, `measurements/2026-09-18-steady/`).

The limit was missed once: the first version of the contract measured 915,649, 649 over. One change brought it under: the channel id and the voucher digest are now hashed in scratch memory instead of through `abi.encode`, which allocated about 19 words per lane that were never reused. That saved 6,288 per batch. A later simplification of the frame parser saved another 176.

## Other transactions

| Transaction | Test token | USDC (fork) |
|---|---:|---:|
| `openChannel`, steady (the contract holds tokens already) | 99,534 | 117,834 |
| `openChannel`, first deposit the contract holds | 116,634 | 134,934 |
| `withdraw`, all but one unit, steady | 42,078 (too low, see the correction) | 50,424 (too low) |
| `withdraw`, everything, the provider's first tokens | 56,866 | 67,712 |

A batch never calls the token, so its gas is the same in any token; the fork run confirms it to the unit (909,185 with USDC).

**Correction, 2026-11-24.** The steady `withdraw` row was measured with the provider's one unit minted (on the fork, dealt) inside the test, just before the measured call. That warmed the token's account, and `vm.cool` does not cool an account already touched in the same transaction. The figures are therefore 2,500 too low with the test token and 5,000 too low with USDC, whose proxy and implementation were both warm. Correctly measured on this contract they would be 44,578 and 55,424. The other rows are unaffected: no other measured test touches a contract before its measured call. The re-measured figures, on the next version of the contract, are in `measurements/2026-11-24-channel-close/`.

## Cold against steady

The first and steady rows differ by exactly 17,100 gas of execution, at K=8 with the real proof and at every K of the sweep below. All of it is one storage slot: the provider's accrued balance, written once per batch. Going from zero to non-zero costs 20,000; changing a non-zero value costs 2,900; both follow the same 2,100 cold read. "Eight new channels, provider paid before" costs exactly the steady figure, so a new channel costs nothing extra: `openChannel` already wrote the channel's slot non-zero (deposit and state), so its first voucher's write is a change, like every later one. In the one-channel rows the totals differ by 17,076 because the later vouchers' calldata is 24 gas dearer; execution differs by 17,100.

In the previous version the difference was 17,100 per frame: each channel's cumulative-amount slot went from zero on its first settlement. Here it is 17,100 per batch, and only when the provider's accrued balance is zero: its first batch, or the first after it withdrew everything. A provider that withdraws all but one unit never pays it again.

The same mechanism, in the token, is behind the first-time rows of the other transactions: `openChannel` when the contract's token balance is zero, and `withdraw` when the provider's is.

## K-sweep

Entries with K = 1, 2, 4, 8, 16 and 32 lanes, each behind the EZKL adapter with a target that accepts everything, so the figures are the contract's cost plus the adapter's. The 3,840-byte K=8 proof is passed as filler; the K=8 commitments and outputs are repeated across lanes; every lane is a different channel of a different payer. Execution is the gas of the call frame (no refund occurs in any of these calls); calldata is at 4 and 16 gas per byte.

| K | First: execution | Steady: execution | Steady: calldata | Steady: transaction | EIP-7623 floor binds |
|---:|---:|---:|---:|---:|---|
| 1 | 56,855 | 39,755 | 75,396 | 209,490 | yes |
| 2 | 69,684 | 52,584 | 82,572 | 227,430 | yes |
| 4 | 94,997 | 77,897 | 95,796 | 260,490 | yes |
| 8 | 145,632 | 128,532 | 125,332 | 334,330 | yes |
| 16 | 247,299 | 230,199 | 182,084 | 476,210 | yes |
| 32 | 450,814 | 433,714 | 295,564 | 759,910 | yes |

Least-squares lines through these points (`ChannelSweepFitTest` computes them from the pinned figures and checks the limit):

| Series | Fixed | Per frame | Largest residual |
|---|---:|---:|---:|
| Execution, steady | 27,035 | **12,706** | 150 |
| Execution, first | 44,135 | 12,706 | 150 |
| 21,000 + calldata + execution, steady | 116,170 | 19,816 | 740 |
| Previous version, execution, steady (the same sweep on the previous contracts) | 29,804 | 38,797 | |

The limit, 14,000 per frame, is met by the execution term, which is how the previous version's 38,797 was measured (gas used minus 21,000 minus calldata, with nothing refunded). Each frame also carries 668 bytes of calldata, about 7,100 gas: its channel's config (224 bytes), the packed frame (92: a 27-byte header and a 65-byte signature), its commitment (32) and its outputs (320). The previous version carried 640 bytes per frame; the config that used to sit in storage is now in calldata, and packing the frame paid for it.

With a verifier this cheap, the transaction's calldata is dearer at the EIP-7623 floor (10 and 40 gas per byte) than at standard pricing plus execution, so the floor sets the transaction's gas at every point of the steady sweep. It does not bind with the real verifier: the K=8 batch's floor is 330,790 against 909,185.

## Where the gas goes, per frame

Each component was removed in turn from a copy of the contract and the steady sweep run again at K = 8, 16 and 32; the table gives the drop in the per-frame slope, (K=32 − K=8) / 24, which is 12,716 for the unchanged contract (the least-squares slope over all six points is 12,706). The storage write could not be removed that way, since the steady case needs it; its cost is the protocol's. The previous version's figures are from its own decomposition with the same sweep.

| Component | This version | Previous version |
|---|---:|---:|
| Storage reads: the channel's one slot (cold) | 2,100 | 15,000 (seven slots) |
| Storage writes: the same slot, changed | 2,900 | 8,700 (three slots) |
| Per-lane log: `FrameSettled(channelId, seq)` | 1,426 | 4,709 (with the ten outputs) |
| Signature: `ecrecover` (3,000) and its handling | 3,775 | 3,000 (`ecrecover` alone counted) |
| Voucher digest (two hashes) | 347 | in the rest |
| Adapter's share of the lane (field checks, copying the lane's inputs) | 381 | none (no adapter) |
| The rest: reading the frame and the config, the channel id, the checks, the loop | 1,787 | 7,388 |
| **Per frame** | **12,716** | **38,797** |

## Where the gas goes, K=8 steady batch

From the call trace of `test_gas_k8_steady` (`forge test -vvvv`). "Cold access" is the 2,600 the caller pays the first time it touches an account in a transaction.

| Component | Gas |
|---|---:|
| Intrinsic | 21,000 |
| Calldata: proof (3,840 bytes) | 61,060 |
| Calldata: commitments and outputs (8 × 32 + 8 × 320 bytes) | 30,700 |
| Calldata: channel configs (8 × 224 bytes) | 17,024 |
| Calldata: frames (8 × 92 bytes) | 10,412 |
| Calldata: entry, verifier set, set index, selector | 4,720 |
| Generated verifier, `verifyProof` | 635,807 |
| Around the verifier: registry (frame 2,354 + cold access) | 4,954 |
| Around the verifier: adapter (frame 5,441 + code-hash read + call) | 8,141 |
| Around the verifier: verifier's code-hash read | 2,600 |
| Frame walk, eight lanes (8 × 12,335: the per-frame figure less the adapter's share, which is in the adapter's frame) | 98,680 |
| Batch: decoding, set hash, domain, entry hash, building the adapter's calldata, accrual write (5,000), `BatchSettled` (the rest) | 14,087 |
| **Total** | **909,185** |

## Compared with the previous version

| Component | Previous version, K=8 | This version, K=8 |
|---|---:|---:|
| Intrinsic | 21,000 | 21,000 |
| Calldata | 114,384 | 123,916 |
| Generated verifier | 635,807 | 635,807 |
| Around the verifier (registry, adapter, code-hash reads) | none | 15,695 |
| Frame walk | 310,376 (8 × 38,797) | 98,680 (8 × 12,335) |
| Batch | 29,804 | 14,087 |
| **Total** | **1,111,371** | **909,185** |
| Per request | 138,921 | 113,648 |

The previous version's column takes its fixed and per-frame terms from its own sweep and the verifier from the stored proof; calldata is what is left of the measured 1,111,371. Where the 202,186 went:

- The frame walk is 211,696 cheaper: one storage slot per channel instead of seven read and three written, a 32-byte log instead of the outputs logged again, no copy of the outputs into memory.
- The batch is 15,717 cheaper: one storage write for the provider's accrual instead of a token transfer, and no model record to read.
- Calldata is 9,532 dearer: each channel's config (224 bytes, 2,128 gas) now travels with the batch instead of being read from storage; packing the frames (92 bytes instead of 288) recovers most of it.
- The proof layer costs 15,695 that the previous version did not pay: the registry read, the adapter, and the code-hash checks that make the verifier's identity a matter of its code rather than of an owner's record.
