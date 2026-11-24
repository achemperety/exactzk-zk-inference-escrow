# Specification notes

Points agreed in the discussion of [x402-foundation/x402#4390](https://github.com/x402-foundation/x402/issues/4390) that the specification must state, with how the contracts in `src/` already follow them.

## The rule

1. **Presenting a proof is permissionless.** Anyone holding a valid proof may submit it. Who submits changes nothing about where the money goes: it goes to the recipient the payer signed for.
2. **A proof that fails is an error, not an outcome.** An invalid proof, or a proof that cannot be checked, leaves the payment exactly as it was and records nothing about it. The two failures are distinct and must stay distinct for the client: a facilitator reports them as two different `SettlementResponse.errorReason` values. One means the proof was checked and rejected (`ProofInvalid`); the other means it could not be checked, because the verifier is unknown or its code is not the registered code (`VerifierUnavailable`).
3. **A payment's recorded history is terminal only.** What the chain records about a payment, or about one voucher of a channel, is how it ended, and it ends in exactly one of three ways: settled against a proof; released by the payee, who gave it up; or refunded to the payer after its deadline (for a channel, returned to the payer when the channel is finalized or its hold is swept). Attempts that failed are not part of it.

   A release is its own record, not a refund. Recording it is safe under rule 2: only a party to the payment can produce it (the payee, who is the one giving up money), so anyone else's failed proofs still leave nothing behind. It is not a verdict on any proof.
4. **Per-lane result codes describe vouchers, never proofs.** In a batch, the proof is checked first and once. If it fails, the batch reverts with one of the errors above and no lane is reported. Only when it has verified does `BatchSettled` report a result per lane, and that result is about the lane's voucher: settled, padding, or why the voucher did not settle (other provider, verifier not allowed, channel not open, wrong sequence number, expired, beyond the prove window, insufficient balance, bad signature).

## How the contracts follow it

| Rule | `SoloSettlement` | `ChannelSettlement` |
|---|---|---|
| 1. Permissionless presentation | `settle` and `release` take any sender; the payment goes to `payTo` in the signed terms. | `settleBatch` takes any sender; what settles accrues to the provider named in the channel's config. |
| 2. Failures are errors | `ProofInvalid()` and `VerifierUnavailable(verifierId)` revert; the lock, if any, is untouched. | The same two errors revert the whole batch before any lane is read. |
| 3. Terminal history only | `Settled` (with the output) or `Refunded` (after `proveBy`). A lock cannot be released by the payee: it ends settled or refunded. | Per voucher: `FrameSettled` (settled) or `FrameWaived` (released by the payee). Per channel: `ChannelFinalized` and `HoldSwept` return what was not settled, released amounts included, after the challenge window and after the hold. |
| 4. Lane codes are about vouchers | One payment, no lanes. | `BatchSettled(verifierId, payTo, asset, total, laneResults)` is emitted only after the proof verified; a batch in which no lane settles reverts with `NothingSettled(laneResults)`. |

## The same rule in the ERC-8183 evaluator and the ERC-8004 validator

| Rule | `ProofEvaluator8183` | `ProofValidator8004` |
|---|---|---|
| 1. Permissionless presentation | `evaluate` takes any sender; the job contract pays the job's provider, and the evaluator fee it pays this contract goes to the same provider in the same call. | `respond` takes any sender; the answer goes to the request the arguments hash to, and only if the agent the registry recorded for that request is the agent the hash commits to. |
| 2. Failures are errors | `ProofInvalid()` and `VerifierUnavailable(verifierId)` revert; the job stays Submitted. The evaluator never rejects a job because a proof failed. | The same two errors revert; nothing is written to the registry. |
| 3. Terminal history only | A job ends Completed (its reason is the claim's digest), Rejected because its provider forfeited it (`forfeit`, reason `FORFEITED`: released by the payee), or Expired through the job contract's `claimRefund`. | Only what a valid proof establishes is written: 100 when it shows the claimed output, 0 when it shows a different one. Could-not-check and no-answer are never written, because the registry averages answers and has no value for them. |
| 4. Lane codes are about vouchers | One proof per job, no lanes. | One proof per request, no lanes. |

## The same rule when composing with x402's `auth-capture`

| Rule | `AuthCaptureProofOperator` |
|---|---|
| 1. Permissionless presentation | `captureWithProof` and `chargeWithProof` take any sender; the escrow pays the `receiver` in the payment the payer signed. |
| 2. Failures are errors | `ProofInvalid()` and `VerifierUnavailable(verifierId)` revert; the hold stays as it was. The operator's `charge` with the escrow's own arguments always reverts, so nothing pays out without a proof. |
| 3. Terminal history only | A hold ends captured against a proof (`CapturedWithProof`), given back by the receiver (`VoidedByReceiver`: released by the payee), or reclaimed by the payer from the escrow after the capture deadline (the escrow's `PaymentReclaimed`). |
| 4. Lane codes are about vouchers | One proof per payment, no lanes. |

### What binds the terms, and for which client

The payer's signature covers the escrow's `PaymentInfo`, whose salt x402's client derives from `receiverAuthorizer`. The server sets `receiverAuthorizer = termsAuthorizer(verifierId, inputCommitment)`: the last 160 bits of a keccak256 hash of the terms. The operator captures only with a valid proof for terms that hash to the same address.

1. **The client MUST add fresh randomness to its input commitment after the server has chosen the verifier.** The 402 answer names `verifierId` before the client draws the nonce part of its input (for the EZKL circuits here, the five nonce values inside the Poseidon commitment), and the client refuses terms whose `verifierId` differs from the one it was first offered. Then the address the payer signs for is a random 160-bit target the server could not influence. To capture with a proof of other terms (a verifier it controls, any input), the server must find a second `verifierId` (with any commitment) that hashes to that target: a second-preimage search of about 2^160 hash evaluations. If the server could see the commitment before choosing the verifier, it could instead vary both sides (the many entries that describe the same circuit, and entries for a verifier it controls) and look for any pair that collide: a birthday search of about 2^80. Both figures assume that keccak256 truncated to 160 bits behaves as a random function and that the server cannot predict the client's randomness. The published-proof mode serves one fixed, public input and so has no fresh randomness; it is a demonstration, not a payment in which the client needs this protection.
2. **A stock `auth-capture` client gets escrow safety only.** x402's client signs whatever `receiverAuthorizer` the offer carries, without knowing what it encodes. The escrow still guarantees that at most the signed amount goes to the signed receiver, through the named operator, and that the payer can reclaim it after the authorization expiry if nothing was captured. The guarantee that a capture needs a proof of the terms the payer meant to buy holds only for a client that recomputes `termsAuthorizer(verifierId, inputCommitment)` from the terms it means to pay for and compares it with `extra.receiverAuthorizer` before signing. Against a stock client, a server could bind terms that it can prove trivially.

## Open points for the specification

- **Names of the two error reasons.** The specification fixes them as `invalid_auth_capture_evm_proof_invalid` and `invalid_auth_capture_evm_verifier_unavailable` (`specs/schemes/proof-gated/auth_capture_policy_evm.md`, "Status words"), and the server in `x402/`, the middleware and the client use those names. The names v3.0.0-testnet emitted are in the error table of `specs/schemes/proof-gated/reference_evm.md`.
