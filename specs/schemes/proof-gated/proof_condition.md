# A proof condition for x402 settlement (draft)

## Summary

A proof condition makes the release of a payment depend on a succinct proof that a stated computation maps the client's committed input to the output the server delivers. It is not a payment scheme of its own. It attaches to the two x402 schemes that already hold funds:

| Host scheme | Where the condition sits | Status of the text |
|---|---|---|
| `auth-capture` | A read-only policy the operator consults before a capture or a charge: [auth_capture_policy_evm.md](./auth_capture_policy_evm.md) | Normative profile |
| `batch-settlement` | A claim condition, checked by a gate that acts as the channel's `receiverAuthorizer`: [batch_settlement_claim_evm.md](./batch_settlement_claim_evm.md) | Proposal, not normative |

The hold, the channel, the deadlines and the client's exits stay the host scheme's own. This text adds the condition: which proof, checked against which registry entry, with which outcomes. The native contracts that the condition was built and measured with stay as its reference implementation and gas baseline: [reference_evm.md](./reference_evm.md).

A proof shows that the named circuit maps the committed input to the output, and nothing more. It does not show that the model is any good, and the circuit is a fixed-point quantisation of the model ([Model identity](#model-identity)).

## Example use cases

- An agent pays 0.01 USDC per inference of a pinned 52,650-parameter classifier through `auth-capture`. The hold is captured only with a valid proof, and the ten output values travel with the capture.
- A client prepays a `batch-settlement` channel and signs, once per batch, a root over the batch's requests, each an input commitment and the payee it pays. Anyone may claim a request's value with a proof for its commitment; the value goes to that request's payee.
- Outside x402, the same proof check completes an ERC-8183 job or answers an ERC-8004 validation request.

## The statement

Every proof is checked against one statement, whatever the proof system. For each lane *i* of a proof: "the circuit of entry `verifierId` maps the input committed to by `commitments[i]` to `outputs[i]`". A solo circuit has one lane. Example, the solo circuit of the reference implementation: one input commitment and ten outputs, 11 public inputs, 320 bytes of output.

## Outcomes of a check

A check of a proof ends in exactly one of three outcomes, and a host scheme MUST keep them apart:

| Outcome | When | What it tells the client and the server |
|---|---|---|
| Valid | The registered verifier ran on the registered code and accepted | The condition holds |
| Invalid | The registered verifier ran on the registered code and did not accept, or the output does not fit the entry | This proof will never pass |
| Unverifiable | The check could not run: unknown entry, an entry that is not the registered one, or code that is not the registered code | Nothing was decided about the computation; the same proof may pass later |

"Could not be checked" never becomes "invalid": [core property 1](#core-properties).

The words for these outcomes on the wire, and their `errorReason` values, are defined once, in [Status words](./auth_capture_policy_evm.md#status-words). Policies, gates and operators MUST use those and define none of their own.

## Core properties

1. **"Could not be checked" never becomes `ProofInvalid`.** Unverifiable MUST NOT degrade into Invalid by default. An implementation MUST report Invalid only in the case the [table](#outcomes-of-a-check) names, and a failure it cannot classify MUST NOT be reported as Invalid. The other properties rest on this one: a record that folds "not checked" into "invalid" cannot be re-read honestly later, and a verifier outage would become a false rejection.
2. **Proof condition.** Funds MUST reach the server only in a transaction that verified a valid proof for the verifier and input commitment the client signed. That transaction MUST carry the output, in an event or in its call data.
3. **Who presents does not matter.** Who presents a proof MUST NOT change where the funds go: to the recipient the client signed for. Where the host scheme lets anyone submit (`auth-capture`'s `"custom"` route, the `batch-settlement` gate), anyone MAY present a proof. Under `auth-capture`'s `"policy"` type a capture also needs the receiver authorizer's signature, as that type defines.
4. **Two failures, two reasons.** An invalid proof and a proof that cannot be checked MUST leave the payment as it was, MUST NOT be recorded, and MUST be reported as two distinct `errorReason` values, because the next step differs.
5. **A refusal refuses one attempt.** A failed check MUST NOT end an authorization, a hold or a voucher. A hold stays capturable until the host scheme's capture deadline, and the client's exit after it is the host scheme's own: `reclaim` in `auth-capture`, the timed withdrawal in `batch-settlement`.
6. **Terminal-only history.** What is recorded about a payment, or about one request in a batch, MUST be how it ended: settled against a proof; given back by the payee; returned to the client through the host scheme's exit. A payment that is never proven ends with nothing moved and nothing recorded about the proof.
7. **Lane results describe requests.** When one proof covers several requests, the proof MUST be checked first and once. If it fails, the whole call MUST revert with one of the two errors of property 4. Only a call whose proof verified reports a result per lane, and that result is about the lane's request.
8. **Full gas for the verifier.** The verifier MUST be given the full gas its registry entry names. A transaction that cannot supply it MUST revert as such, never report the proof invalid, so that a submitter cannot make a valid proof fail by under-funding it.
9. **Content-addressed verifiers.** A registry entry MUST be immutable. Its identifier MUST commit to the proof system, the verifying-key hash, the code hashes of the adapter and the verifier, the shape of the statement and the gas allowance. The code MUST be checked against those hashes at registration and on every use. An account whose code is an EIP-7702 delegation MUST be refused.
10. **Fresh client randomness.** The client MUST draw fresh randomness into its input commitment after the server has named the verifier, and MUST refuse terms whose verifier differs from the one first offered.
11. **The host's guarantees stand.** The condition MUST NOT weaken the host scheme's fund safety or replay protection: at most the signed amount moves, only to the signed recipient, and each client authorization is usable once.

Example of properties 3, 4 and 5 together: a third party submits a tampered proof for someone else's hold. The attempt reverts with `ProofInvalid`, the hold is untouched, nothing is logged, and the server captures later with the real proof, up to the capture deadline.

## Where the condition attaches

[x402-foundation/x402#4390](https://github.com/x402-foundation/x402/issues/4390) weighed three shapes: (a) a policy for `auth-capture` and a claim condition for `batch-settlement`, (b) an extension that only advertises proof terms, (c) a dedicated scheme. This draft follows (a). The proof is a condition on settlement, and both host schemes already hold the funds. No dedicated scheme is proposed.

| | `auth-capture`, proof policy | `batch-settlement`, claim gate (proposal) | Native contracts (reference) |
|---|---|---|---|
| Hold | The canonical `AuthCaptureEscrow` | `x402BatchSettlement` channel | Own lock, or none |
| Condition | `captureStatus` / `chargeStatus` answer `Authorized` | The gate claims one unit per proven, signed commitment and pays the request's payee | `settle` / `release` check the proof |
| What the client signs that binds the terms | `PaymentInfo.salt`, through a salt nonce derived from the terms | A root over the batch's input commitments and payees | The terms, as the payment's id |
| Client | Must derive the salt nonce from the terms | Must sign the root | Proof-aware client |
| Runs today | Through a `"custom"` operator fixed to the policy | As a prototype, locally | Deployed on a testnet |
| Measured (local; [details](./reference_evm.md#gas-baseline)) | 899,361 gas for `authorize` + capture, 841,355 for a charge (USDC) | 793,491 gas per claim, steady, payee paid in the claim (test token) | 768,174 for one-transaction `settle` (USDC) |

## Model identity

A `verifierId` pins code, not a model. What connects a model to an entry is a chain of reproducible steps, each checkable from public files:

| Step | From | To | Needs the model's weights |
|---|---|---|---|
| 1. Key setup | model file, the **pinned `settings.json`**, SRS, each named by SHA-256 | verifying key; the entry's `vkHash` is its keccak256 | Yes |
| 2. Verifier generation | verifying key, `settings.json`, SRS | verifier source | No |
| 3. Compilation | verifier source, a named compiler and options | runtime bytecode | No |
| 4. Deployment | runtime bytecode | on-chain code; the entry's `targetCodeHash` is its keccak256 | No |

The pinned `settings.json` is part of the circuit's identity. Settings regenerated from the same model, scales and visibility can list their range checks in another order and give a different verifying key, so the mapping starts from the pinned file, not from a fresh calibration. A setting that does not enter the keys can vary: EZKL's `check_mode` SAFE gives the same verifying key byte for byte.

Example, the reference solo entry: model `c3caeb16…1e90`, settings `dcae92a6…c6c4`, SRS `e4690b64…e9be` (SHA-256) → `vkHash` `0x13cff042…4ff2` → solc 0.8.20, optimizer on, 1 run → `targetCodeHash` `0x8cd0b80f…5f49`. The compiler appends a metadata hash that depends on the source path, so a reproduction compares the bytecode without its 53-byte metadata trailer. The reference implementation's `scripts/verify_entry.py` runs all four steps and compares them with the registry entry, read-only.

What the mapping does not settle:
- **Which model is the intended one.** That is a statement by whoever publishes the model, and it needs their signature, not an indexer's word. An ERC-8004 agent's registration file is one place to publish model hashes with their verifier ids.
- **The model as trained.** The proof is of the circuit, a fixed-point quantisation of the model (in the reference circuits, inputs and weights scaled by 2^13 and rounded). "The intended model" can only mean that quantisation of it.

## Appendix

### What a host binding specifies

Every binding of the condition to a host scheme on a network MUST specify:
1. **Registry**: entries, identifiers, code checks, gas allowance.
2. **Statement encoding**: how commitments and outputs reach the verifier.
3. **Binding**: what the client signs, inside the host scheme's own signature, that fixes the verifier and the input commitment.
4. **Check**: which call runs the proof check, and that the check, the movement of funds and the output are one transaction.
5. **Outcomes**: the status words and `errorReason` values of [Status words](./auth_capture_policy_evm.md#status-words).
6. **Refusals**: what a refused attempt leaves, and which host deadline and exit apply.
7. **Input commitment format**: how the client computes its commitment.

### Files

- [`auth_capture_policy_evm.md`](./auth_capture_policy_evm.md): the `auth-capture` policy profile, EVM.
- [`batch_settlement_claim_evm.md`](./batch_settlement_claim_evm.md): the `batch-settlement` claim condition, EVM; a proposal.
- [`reference_evm.md`](./reference_evm.md): the reference contracts, the registry, the binding table, error codes, security and gas.
- [`REVIEW.md`](./REVIEW.md): every requirement and number in these files, with where it holds or was measured.

## Version History

| Version | Date | Changes | Authors |
|---|---|---|---|
| v0.1 | 2026-11-24 | Draft for discussion, as a dedicated scheme | @achemperety |
| v0.2 | 2026-11-25 | Shape (a): a policy profile for `auth-capture` with a reason-returning check, a claim-condition proposal for `batch-settlement`; the native contracts kept as reference and gas baseline | @achemperety |
| v0.3 | 2026-11-25 | "Could not be checked never becomes `ProofInvalid`" moved to core property 1, the others renumbered; `batch-settlement` proposal: a payee in each request, one root per batch | @achemperety |
