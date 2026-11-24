# ERC-8183 evaluator and ERC-8004 validator: gas, 2026-11-24

Gas of `ProofEvaluator8183` (`setTerms`, `evaluate`, `forfeit`) and `ProofValidator8004` (`respond`) with the stored solo proof, measured in `forge test` under the Osaka gas schedule. The figures come from `test/StandardsGas.t.sol`, which runs in CI and pins them. Nothing here was sent to a chain.

The evaluator works against the ERC-8183 reference job contract and the validator against the ERC-8004 reference registries, both built from source (`test/external/README.md`). They are compiled with this repository's settings (solc 0.8.28, `via_ir`, 1,000,000 runs), not with their authors' (the ERC-8004 repository uses solc 0.8.24 and 200 runs). The parts of each figure spent inside them are marked below; as deployed by others they would cost somewhat more or less. The token is the test token, not USDC.

## Method

As for the settlement contracts (`measurements/2026-11-23-solo-settlement/`): `test/GasMeter.sol` rebuilds a transaction's gas as 21,000, plus calldata at 4 and 16 gas per byte, plus the gas the call frame used, minus the capped refund. The measured call is the first thing its test does; jobs, requests and balances are made in `setUp`. Every account involved is made cold first, the proxies' implementations included.

A first version of these tests read 2,500 gas low on every row. They read each proxy's implementation address with `vm.load` in the test body, to list it among the accounts to cool. That read touches the proxy's account, and `vm.cool` cools storage but not an account already touched in the same transaction. The addresses are now read in `setUp`. Every figure rose by exactly 2,500.

"Steady": the job contract holds other jobs' budgets and the provider has been paid before. "First": the job is the only one held and the provider's balance goes from zero.

## Figures

| Transaction | Gas |
|---|---:|
| `setTerms` | 97,317 |
| `evaluate`: completed, evaluator fee (5 %) passed on, steady | 769,085 |
| `evaluate`: completed, no evaluator fee, steady | 760,498 |
| `evaluate`: completed, evaluator fee passed on, provider's first payment, last job held | 781,385 |
| `forfeit`, steady | 78,840 |
| `respond`: first answer to a request, 100 | 803,767 |
| `respond`: first answer to a request, 0 | 783,939 |
| `respond`: a request answered before, 100 again | 724,184 |

The first-payment `evaluate` costs 17,100 more execution than steady (the provider's balance goes from zero) and gets 4,800 more refund (the job contract's balance returns to zero): 769,085 + 17,100 − 4,800 = 781,385.

## Where the gas goes

From the call trace of each test (`forge test -vvvv`). "Cold access" is the 2,600 the caller pays to touch an account for the first time in a transaction (100 when warm). The proof layer is the same as in solo settlement, to the gas.

| Component | `evaluate`, fee | `evaluate`, no fee | `setTerms` | `forfeit` |
|---|---:|---:|---:|---:|
| Intrinsic | 21,000 | 21,000 | 21,000 | 21,000 |
| Calldata, proof bytes (3,840) | 60,888 | 60,888 | | |
| Calldata, output (320 bytes) | 3,320 | 3,320 | | |
| Calldata, everything else | 3,784 | 3,784 | 1,584 | 572 |
| Job contract: `getJob` through its proxy (frame 23,794 + cold access) | 26,394 | 26,394 | 26,394 | 26,394 |
| Proof layer: registry (frame 2,354 + cold access) | 4,954 | 4,954 | | |
| Proof layer: adapter (frame 2,959 + code-hash read + call) | 5,659 | 5,659 | | |
| Proof layer: verifier (`verifyProof` 577,544 + code-hash read) | 580,144 | 580,144 | | |
| Job contract: `complete` (pays the provider and the fee) or `reject` (refunds the client) | 52,876 | 27,529 | | 27,340 |
| Fee pass-on: `paymentToken`, two `balanceOf`, one `transfer` | 11,471 | 8,480 | | |
| Refund: the evaluator's balance returns to zero | −19,900 | | | |
| Terms: two new storage slots | | | 44,200 | |
| Events emitted by the evaluator | 4,947 | 4,947 | 2,131 | 1,500 |
| Logic: reading the terms, decoding the job, building the adapter's call | 13,548 | 13,399 | 2,008 | 2,034 |
| **Total** | **769,085** | **760,498** | **97,317** | **78,840** |

| Component | `respond`, 100 | `respond`, 0 | `respond`, again |
|---|---:|---:|---:|
| Intrinsic | 21,000 | 21,000 | 21,000 |
| Calldata, proof bytes (3,840) | 60,888 | 60,888 | 60,888 |
| Calldata, output (320 bytes) | 3,320 | 3,320 | 3,320 |
| Calldata, everything else | 5,140 | 5,212 | 5,128 |
| Registry: `getValidationStatus` through its proxy (frame + cold access) | 23,648 | 23,648 | 23,663 |
| Proof layer: registry, adapter, verifier (as above) | 590,757 | 590,757 | 590,757 |
| Registry: `validationResponse` (warm) | 89,123 | 69,223 | 9,523 |
| Event emitted by the validator | 2,012 | 2,012 | 2,012 |
| Logic: request hash, output hash, claim digest, building the calls | 7,879 | 7,879 | 7,893 |
| **Total** | **803,767** | **783,939** | **724,184** |

Third-party code in these figures: in `evaluate`, 79,270 (fee) or 53,923 (no fee) is the job contract; in `respond`, 112,771 (first 100), 92,871 (first 0) or 33,186 (again) is the Validation Registry. A first answer writes four new storage slots in the registry (response hash, tag, the answered flag, and the response itself when it is 100), which is most of the difference between the rows.

## Two costs of the design

**Passing the evaluator fee on.** With a fee, `evaluate` costs 8,587 more than without: the job contract pays the fee as a separate transfer with its own event (25,347 more inside `complete`), the evaluator forwards it (2,991), and the evaluator's balance going up and back down to zero in the same transaction earns back 19,900. Without a fee, the evaluator still asks for the payment token and reads its balance twice (8,480), of which 2,500 is touching the token's account first, which `complete` would otherwise do; so about 5,980 is spent to find out that there is no fee (derived from the trace, not measured separately). The ERC's text has no evaluator fee, and the reference code's fee formula is not part of any interface, so the evaluator measures what arrives rather than computing it.

**Checking which agent a request belongs to.** `respond` reads the request back from the registry before answering and refuses one opened for another agent than the one its hash commits to. Measured by running the same tests with the check removed, it costs 3,220 (first answer, 100), 3,228 (first answer, 0) and 3,249 (again): the 23,648 read leaves the request's slots warm for the write that follows.
