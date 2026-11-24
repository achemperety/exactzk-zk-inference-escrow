# Solo settlement gas, 2026-11-23

Gas of each solo settlement transaction (`src/SoloSettlement.sol`) with the stored solo proof, measured in `forge test` under the Osaka gas schedule. The tests that produce these figures are `test/SoloSettlementGas.t.sol` (test token, runs in CI, figures pinned) and `test/SoloSettlementFork.t.sol` (Circle's USDC on a fork of Base Sepolia, opt-in, figures logged). Nothing here was sent to a chain.

## Method

A Foundry test runs as one transaction, so a transaction's gas is rebuilt (`test/GasMeter.sol`):

- 21,000 base;
- plus calldata at 4 gas per zero byte and 16 per non-zero byte (the EIP-7623 floor of 10 and 40 is lower for every call here);
- plus the gas used by the call frame;
- minus the storage refund, capped at a fifth of the total.

Each measured call is the first thing its test does, and every account and slot involved is made cold first. Balances and locks it depends on are created in `setUp`, which runs as a separate transaction. That matters: `vm.cool` makes storage cold again but not an account the test has already touched, and an earlier version of these tests read 2,500 gas low for that reason.

"First" means the recipient's token balance starts at zero: the provider's first payment in that token, or the first lock the contract holds. "Steady" means every balance written was already non-zero.

## Results

| Transaction | Test token | USDC (fork) | Limit |
|---|---:|---:|---:|
| `settle` (one transaction), steady | 747,528 | 768,174 | target 775,000 |
| `settle`, first payment to the provider | 764,628 | 785,274 | target 775,000, hard limit 795,000 |
| `settle`, ERC-1271 payer, steady | | 772,271 | |
| `open`, steady | 97,978 | 116,231 | 130,000 |
| `open`, first lock held by the contract | 115,078 | 133,331 | 130,000 |
| `release`, steady | 714,216 | 725,062 | |
| `release`, first payment, last lock | 726,516 | 737,362 | |
| `open` + `release`, steady | 812,194 | 841,293 | 870,000 |
| `open` + `release`, first lock and first payment | 841,594 | 870,693 | 870,000 |
| `refund`, steady | 46,605 | 57,451 | |
| `refund`, last lock | 41,805 | 52,651 | |

The USDC column was measured on a fork of Base Sepolia at block 62,638,490 (`FORK_BLOCK=62638490`). An earlier run at block 62,623,107 gave the same figures.

With USDC, three figures miss a limit:

- **`settle`, first payment to the provider: 10,274 over the 775,000 target, under the 795,000 hard limit.** The provider's USDC balance goes from zero to non-zero (22,100 instead of 5,000). It happens once per provider.
- **`open`, first lock: 3,331 over 130,000.** The contract's own USDC balance goes from zero to non-zero.
- **`open` + `release`, first lock and first payment: 693 over 870,000.** The two zero-to-non-zero writes above in one escrow.

The contract's balance is zero whenever it holds no lock at all. Seeding it with one unit of USDC at deployment keeps it non-zero for good: every amount paid out was paid in for that request. With the seed, the worst escrow case becomes `open` steady plus `release` steady plus the provider's zero-to-non-zero write: 116,231 + 725,062 + 17,100 = 858,393. That figure is derived, not measured.

## Where the gas goes

Steady case, figures from the call trace of each test (`forge test -vvvv`). "Cold access" is the 2,600 the caller pays to touch an account for the first time in a transaction (100 when warm). The settlement contract's own frame is the same with both tokens; only the token's frames differ.

| Component | `settle` test token | `settle` USDC | `open` USDC | `release` USDC |
|---|---:|---:|---:|---:|
| Intrinsic | 21,000 | 21,000 | 21,000 | 21,000 |
| Calldata, proof bytes (3,840) | 60,888 | 60,888 | | 60,888 |
| Calldata, output (320 bytes) | 3,320 | 3,320 | | 3,320 |
| Calldata, everything else | 7,540 | 7,540 | 4,292 | 5,908 |
| Proof layer: registry (frame 2,354 + cold access) | 4,954 | 4,954 | | 4,954 |
| Proof layer: adapter (frame 2,959 + code-hash read + call) | 5,659 | 5,659 | | 5,659 |
| Proof layer: verifier (`verifyProof` 577,544 + code-hash read) | 580,144 | 580,144 | | 580,144 |
| Token pull, `receiveWithAuthorization` (frame + cold access) | 46,259 | 64,559 | 64,559 | |
| Token push, `transfer` (frame + access) | 7,917 | 10,263 | | 26,063 |
| Refund: the contract's balance returns to its starting value | −2,800 | −2,800 | | |
| Storage: the request's state slot | | | 22,100 | 5,000 |
| Events emitted by the settlement contract | 4,947 | 4,947 | 2,012 | 4,947 |
| Logic: decoding, hashing, building the adapter's call | 7,700 | 7,700 | 2,268 | 7,179 |
| **Total** | **747,528** | **768,174** | **116,231** | **725,062** |

The proof layer around the verifier (registry, adapter, code-hash reads) is 13,213 gas, plus some of the logic line: the entry's hash and the copy of the proof into the adapter's calldata. USDC's `receiveWithAuthorization` costs 18,300 more than the test token's and its `transfer` 2,346 more (after a pull) or 10,846 more (cold, in `release`): USDC is a proxy, checks a pause flag and blacklist bits, and computes its signature domain on each call.

## Compared with the previous version

The previous version's solo path cost 953,756 gas on Base Sepolia in two transactions (open 248,838, settle 704,918). The one-transaction flow does the same job for 768,174 with USDC, 185,582 less. The escrow flow, which keeps the lock, costs 841,293 in two transactions, 112,463 less. Most of the difference is the lock record: the previous version stored the request in eight storage slots, this one stores one slot (escrow flow) or none (one-transaction flow).
