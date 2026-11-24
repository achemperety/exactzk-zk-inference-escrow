# Closing a channel: gas, 2026-11-24

Gas of the `ChannelSettlement` close functions (`requestClose`, `challengeClose`, `finalizeClose`, `sweepExpiredHold`, `waive`), measured in `forge test` under the Osaka gas schedule. The figures come from `test/ChannelCloseGas.t.sol` (test token, runs in CI, figures pinned) and `test/ChannelSettlementFork.t.sol` (Circle's USDC on a fork of Base Sepolia at block 62,638,490, opt-in, figures logged). Nothing here was sent to a chain.

## Method

As for the batches (`measurements/2026-11-23-channel-settlement/`): `test/GasMeter.sol` rebuilds a transaction's gas as 21,000, plus calldata at 4 and 16 gas per byte (or the EIP-7623 floor, when higher), plus the gas the call frame used, minus the capped refund. The measured call is the first thing its test does, and the test reads nothing from the token before it: reading would warm the token's account, which `vm.cool` does not undo (see "A correction to the day before" below).

The contract holds one unit of the token of its own, as it will after deployment, so its own balance never returns to zero. Two payers are used: one that kept tokens after depositing ("steady"), and one that deposited all it had, so that the call paying it back makes its token balance non-zero again ("first"). Finalization and the sweep are sent by the payer; challenges and waivers by the provider.

## Figures

| Transaction | Test token | USDC (fork) |
|---|---:|---:|
| `requestClose` | 52,541 | 52,541 |
| `challengeClose` | 41,243 | 41,243 |
| `challengeClose`, raising an earlier claim | 41,231 | |
| `finalizeClose`, nothing held, steady | 48,522 | 59,368 |
| `finalizeClose`, nothing held, payer's first tokens | 65,610 | 76,456 |
| `finalizeClose`, with a hold, steady | 48,685 | 59,531 |
| `finalizeClose`, with a hold, payer's first tokens | 65,773 | 76,619 |
| `sweepExpiredHold`, steady | 48,090 | 58,936 |
| `sweepExpiredHold`, payer's first tokens | 65,178 | 76,024 |
| `waive`, open channel | 39,088 | 39,076 |
| `waive` after finalization, returning one unit, steady | 57,107 | 67,929 |
| `waive` after finalization, returning one unit, payer's first tokens | 74,183 | 85,041 |

`requestClose`, `challengeClose` and a `waive` before finalization do not call the token; their USDC rows equal the test token's (the open-channel `waive` differs by 12 gas of calldata, from the token's address). The functions that pay the payer cost about 10,800 more with USDC, its proxy and its balance checks, as `withdraw` does.

## First against steady

In every row that pays the payer, "first" costs exactly 17,100 more execution than "steady": the payer's balance slot in the token goes from zero to non-zero (20,000) instead of changing (2,900). The figures differ by 12 more or less in calldata, from the two payers' addresses.

`requestClose` has no steady case. It writes the channel's second, cold storage slot for the first time (the challenge window's end), which always goes from zero: 22,100 of its 29,357 of execution. The rest is the channel's hot slot (read 2,100, rewritten 2,900 with the new state) and the event. A challenge rewrites that slot (2,900), so the first challenge and a later one cost the same.

## What closing added to a batch

A lane now checks for one more state, `Held`, before it reads the cold slot. A lane of an open channel never reads it. The added branch costs 13 gas per lane: 7 for the branch, and 6 that appeared when the close functions were added. The 6 is HYPOTHESIS: code layout, since the lane's own code did not change.

| | 2026-11-23 | 2026-11-24 |
|---|---:|---:|
| K=8 batch, eight channels, steady | 909,185 | 909,289 |
| K=8 batch, first accrual | 926,285 | 926,389 |
| K=8 batch, one channel, steady | 860,853 | 860,957 |
| Sweep, execution per frame, steady | 12,706 | 12,719 |
| Sweep, fixed execution, steady | 27,035 | 27,035 |
| `openChannel`, steady | 99,534 | 99,619 |
| `withdraw`, everything, first | 56,866 | 57,035 |

`openChannel` and `withdraw` changed only through the longer function dispatch. The K=8 batch stays within its limit (915,000), and the per-frame cost within its own (14,000).

## A correction to the day before

The 2026-11-23 figure for `withdraw` of all but one unit, steady, was 2,500 too low with the test token (42,078) and about 5,000 too low with USDC (50,424). That test minted (or, on the fork, dealt) the provider its one unit inside the test, before the measured call. Minting touches the token, so its account was warm when the measured call reached it. `vm.cool` cools storage but not an account already touched in the same transaction, which saves 2,500 per warm account. USDC has two: its proxy and its implementation. The unit is now given in `setUp`. Measured the same way on this contract, the row reads 44,747 (test token) and 55,593 (USDC); 169 of each difference is this version's longer dispatch.

No other measured test touches a contract before its measured call. A scan of every gas test was made for that.

## Invariant testing

`test/ChannelInvariant.t.sol` runs a handler over `openChannel`, `settleBatch`, `withdraw`, `requestClose`, `challengeClose`, `waive`, `finalizeClose`, `sweepExpiredHold` and random time jumps of up to half an hour. Each channel it opens has its own windows: prove 60 seconds to an hour, challenge 300 seconds to an hour. Five invariants, each checked after every call, for 512 runs of 50 calls each; see `test/MUTATIONS.md` for the mutations they caught. Figures from one run of the suite:

| Function | Calls | Reverts |
|---|---:|---:|
| `open` | 2,788 | 0 |
| `settle` | 2,870 | 819 |
| `withdraw` | 2,911 | 961 |
| `requestClose` | 2,891 | 715 |
| `challengeClose` | 2,861 | 1,543 |
| `waive` | 2,826 | 62 |
| `finalizeClose` | 2,789 | 1,764 |
| `sweepExpiredHold` | 2,827 | 2,683 |
| `warp` | 2,837 | 0 |

The table is for one of the five invariants. The others ran the same number of calls, with reverts within a few dozen of these.

Most reverts are deliberate. One call in five goes to an arbitrary channel, and one lane in four of a batch is broken on purpose. The rest are calls that found no channel in the right state: there is little to sweep unless a hold has formed and expired. Across the 512 runs of one invariant, channels entered `Closing` 2,179 times, `Held` 336 times and `Closed` 872 times. Batches settled vouchers out of a hold 48 times, and the 144 sweeps that succeeded each returned an expired hold.
