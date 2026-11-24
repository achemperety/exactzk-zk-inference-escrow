# Paying through x402's auth-capture escrow with a proof: gas, 2026-11-24

Gas of the `auth-capture` route (x402's escrow from base/commerce-payments v1.1.0, built from source, with `AuthCaptureProofOperator` as its operator) next to this repository's own solo settlement, with the stored solo proof, under the Osaka gas schedule. Figures come from `test/AuthCaptureGas.t.sol`: the test-token rows run in CI and are pinned; the USDC rows run on a fork of Base Sepolia at block 62,638,490 (`FORK_RPC_URL`, `FORK_BLOCK`), opt-in, and are logged. Nothing was sent to a chain.

Method as in `measurements/2026-11-23-solo-settlement/`: `test/GasMeter.sol` rebuilds a transaction's gas; the measured call is the first thing its test does; every account involved, the escrow's token store included, is made cold first. The escrow and collector are compiled with this repository's settings (solc 0.8.28, `via_ir`, 1,000,000 runs), not the authors' deploy profile (`via_ir`, 100,000 runs, Cancun), so the deployed escrow's own gas may differ by some hundreds.

"Steady": the operator's token store exists and holds other payments, the receiver has been paid before, the payer holds more of the token.

## Figures

| Transaction | Test token | USDC (fork) |
|---|---:|---:|
| **Native, one transaction:** `SoloSettlement.settle` | 747,528 | 768,174 |
| **Native, escrow:** `open` + `release` | 812,194 | 841,293 |
| **auth-capture, escrow:** `authorize` through the operator | 126,385 | 148,600 |
| **auth-capture, escrow:** `captureWithProof` | 735,804 | 746,650 |
| **auth-capture, escrow:** `authorize` + `captureWithProof` | 862,189 | 895,250 |
| **auth-capture, one step:** `chargeWithProof` | 812,420 | 836,981 |

The native rows are the 2026-11-23 figures (`measurements/2026-11-23-solo-settlement/`), measured the same way; `SoloSettlement` has not changed since.

First-time rows, test token: `authorize` for the operator's first hold, when its token store's balance starts at zero, 143,485 (17,100 more); `captureWithProof` for its first payout, when the escrow deploys the token store and the receiver is paid for the first time, 790,770 (54,966 more).

## What the composition costs

| | Test token | USDC |
|---|---:|---:|
| Escrow flow: auth-capture over native | +49,995 | +53,957 |
| One-transaction flow: `chargeWithProof` over native `settle` | +64,892 | +68,807 |

The proof layer is the same to the gas in both routes (registry 4,954, adapter 5,659, verifier 577,544 plus its code-hash read). The difference is the escrow's bookkeeping. Steady `captureWithProof`, test token, 735,804:

| Component | Gas |
|---|---:|
| Intrinsic | 21,000 |
| Calldata (proof 60,888, output 3,320, `PaymentInfo`, terms and entry) | 71,696 |
| Proof layer: registry, adapter, verifier | 590,757 |
| Escrow: `getHash` (first touch of the escrow) | 4,236 |
| Escrow: `paymentState` | 2,505 |
| Escrow: `capture` (state update, event, the payout through the operator's token store: 18,397) | 31,209 |
| Operator: salt binding, claim digest, event with the output | 14,401 |

Steady `authorize`, 126,385: the escrow's `authorize` is 118,524 of it (with its first-touch charge). Inside that, the ERC-3009 collector takes 72,833: the token's `receiveWithAuthorization` into the collector, then a transfer on to the token store. The escrow's own state slot, event and balance checks are most of the rest. The collector's balance goes up and back to zero in the same transaction (19,900 refunded). The operator's wrapper adds 1,673.

Where the native contract pays its provider from the payer in one hop, the escrow moves the funds twice: payer to collector to token store on `authorize`, and token store to receiver on capture. It also keeps a payment record of its own. That record is what gives the payer `reclaim` and the receiver `void` without any code of ours.
