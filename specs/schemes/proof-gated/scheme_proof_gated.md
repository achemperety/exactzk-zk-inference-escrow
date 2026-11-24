# Scheme: `proof-gated` (draft)

## Summary

`proof-gated` makes the release of a payment conditional on a succinct proof that a stated computation maps the client's committed input to the output the server delivers. The client signs terms that name a verifier, a content-addressed entry in an on-chain registry, and a commitment to its input. Funds reach the server only in a transaction that verifies a valid proof for that verifier and that commitment, and the same transaction publishes the output. If no valid proof arrives before the deadline, the client's funds stay or come back.

The scheme adds a release condition, not a new escrow. Where `auth-capture` or `batch-settlement` already hold the funds, the condition composes with them ([Relationship](#relationship-to-auth-capture-and-batch-settlement)).

A proof shows that the named circuit maps the committed input to the output, and nothing more. It does not show that the model is any good, and the circuit is a fixed-point quantisation of the model ([Model identity](#model-identity)).

## Example use cases

- An agent pays 0.01 USDC per inference of a pinned 52,650-parameter classifier and receives the ten output values with the settlement transaction.
- A client prepays a channel and signs one voucher per request; the server settles eight or sixteen requests per transaction with one proof.
- Outside x402, the same proof check completes an ERC-8183 job or answers an ERC-8004 validation request.

## The statement

Every proof is checked against one statement, whatever the proof system. For each lane *i* of a proof: "the circuit of entry `verifierId` maps the input committed to by `commitments[i]` to `outputs[i]`". A solo circuit has one lane. Example, the solo circuit of the reference implementation: one input commitment and ten outputs, 11 public inputs, 320 bytes of output.

## Payment flows

| `extra.paymentFlow` | Ordering | Lifecycle |
|---|---|---|
| `authorization` | verify → resource → settle | One settle, after the resource: the transaction checks the proof, collects the client's authorization and pays the server. No hold. Without a valid proof before `proveBy`, nothing moves. |
| `escrow` | settle → resource → settle | The first settle locks the funds before the server proves. The second releases them against a proof, up to `proveBy`. After `proveBy` anyone may refund the client. |

`paymentFlow` is REQUIRED; there is no default. Example: a server that wants the funds locked before it spends 20 s proving offers `escrow`; one that proves in under a second offers `authorization`, which costs one transaction instead of two.

### Telling settles apart

In `escrow` a payment settles twice. A facilitator tells the two apart from the payload: a payload without the `proof` group settles as the lock; a payload with it settles as the release. In `authorization`, a payload without `proof` is refused at `/settle`. The refund after `proveBy` is permissionless and is not relayed.

## Core properties

1. **Proof condition.** Funds MUST reach the server only in a transaction that verified a valid proof for the signed verifier and input commitment, and that transaction MUST publish the output.
2. **Permissionless presentation.** Anyone MAY present a proof. Who presents it MUST NOT change where the funds go: to the recipient the client signed for.
3. **Proof failures are errors, not outcomes.** An invalid proof, and a proof that cannot be checked (unknown entry, or code that is not the registered code), MUST leave the payment as it was and MUST NOT be recorded. They MUST be reported as two distinct `errorReason` values, because the client's next step differs: an invalid proof will not become valid; a check that could not run may succeed later.
4. **Terminal-only history.** What is recorded about a payment, or about one voucher of a channel, MUST be how it ended, in exactly one of these ways: settled against a proof; released by the payee, who gives the money up; refunded to the client after the deadline (for a channel, returned when it is finalized or its hold expires). An `authorization` payment that is never proven ends with nothing moved and nothing recorded.
5. **Lane results describe vouchers.** In a batch, the proof MUST be checked first and once. If it fails, the whole batch MUST revert, with one of the two errors of property 3. Only a batch whose proof verified reports a result per lane, and that result is about the lane's voucher: settled, padding, or why the voucher did not settle.
6. **Full gas for the verifier.** The verifier MUST be given the full gas its registry entry names. A transaction that cannot supply it MUST revert as such, never report the proof invalid, so that a submitter cannot make a valid proof fail by under-funding it.
7. **Content-addressed verifiers.** A registry entry MUST be immutable. Its identifier MUST commit to the proof system, the verifying-key hash, the code hashes of the adapter and the verifier, the shape of the statement and the gas allowance. The code MUST be checked against those hashes at registration and on every use. An account whose code is an EIP-7702 delegation MUST be refused.
8. **Fresh client randomness.** The client MUST draw fresh randomness into its input commitment after the server has named the verifier, and MUST refuse terms whose verifier differs from the one first offered.
9. **Fund safety and replay.** At most the signed amount MUST move, only to the signed recipient, and each client authorization MUST be usable once.

Example of properties 2 and 3 together: a third party submits a tampered proof for someone else's locked payment. The transaction reverts with `ProofInvalid()`, the lock is untouched, nothing is logged, and the server can still release it with the real proof.

## Relationship to `auth-capture` and `batch-settlement`

The discussion of this proposal ([x402-foundation/x402#4390](https://github.com/x402-foundation/x402/issues/4390)) put composition first: both schemes already hold funds; what they lack is a release condition that is a proof rather than the server's consent.

| | `auth-capture` with a proof operator | `batch-settlement` with a proof claim condition | `proof-gated` (this binding) |
|---|---|---|---|
| Hold | The canonical `AuthCaptureEscrow` | A prepaid channel | Lock in `escrow`; none in `authorization` |
| Release condition | A `"custom"` operator captures only with a valid proof; later the reserved `"policy"` type | A claim settles only the vouchers a proof covers | `settle` or `release` checks the proof |
| What the client's signature binds | The escrow's `PaymentInfo`; the terms only through `receiverAuthorizer` | Each voucher binds its input commitment | The terms, directly |
| Client | Stock `auth-capture` client: escrow safety only; the proof condition holds for a client that checks the binding | A voucher-signing client | A proof-aware client |
| Reference, measured (USDC, local) | 895,250 gas for `authorize` + `captureWithProof`; 836,981 for `chargeWithProof` | 113,661 gas per request at K=8, 71,066 at K=16 (own channel contract, not on the x402 wire) | 768,174 for one-transaction `settle` |

Which shape x402 adopts is open: (a) a policy for `auth-capture` and a claim condition for `batch-settlement`, (b) an extension that only advertises proof terms, or (c) a dedicated scheme. This draft specifies (c) and the composition with `auth-capture`, which runs today with an unmodified x402 client.

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

### Network requirements

Every `proof-gated` network binding MUST specify:
1. **Registry**: entries, identifiers, code checks, gas allowance.
2. **Statement encoding**: how commitments and outputs reach the verifier.
3. **Client authorization**: what the client signs and how it binds the terms.
4. **Settlement**: the call per flow; funds and output in one transaction.
5. **Errors**: invalid and unverifiable proofs as distinct reasons.
6. **Deadlines**: how `proveBy` is enforced and funds come back.
7. **Input commitment format**: how the client computes its commitment.

### Network bindings

- [`scheme_proof_gated_evm.md`](./scheme_proof_gated_evm.md): EVM.

## Version History

| Version | Date | Changes | Authors |
|---|---|---|---|
| v0.1 | 2026-11-24 | Draft for discussion | @achemperety |
