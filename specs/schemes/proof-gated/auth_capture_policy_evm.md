# `auth-capture` on EVM: a proof policy (draft profile)

## Summary

This is a profile of the reserved `"policy"` operator type of x402's [`auth-capture` EVM binding](https://github.com/x402-foundation/x402/blob/main/specs/schemes/auth-capture/scheme_auth_capture_evm.md#future-operator-type-policy) for one kind of policy: one whose condition is a proof ([proof_condition.md](./proof_condition.md)). It specifies:

1. A **reason-returning check**, in place of the boolean hook, for policies whose refusals differ in kind.
2. The **status words** and their `errorReason` values, defined once for every policy.
3. The **proof policy**: how the terms are bound into the payment, what the policy reads, and what each outcome does.
4. The **route that works today**: a `"custom"` operator fixed to one policy, usable before the `"policy"` type exists.
5. An **optional two-step route**: the proof checked and recorded in a transaction of its own, the payment opened by the record's key.

The escrow, the payment's identity, the deadlines and `reclaim` are `auth-capture`'s own and are not changed. Core types are those of [x402-specification-v2.md](https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md).

## Why a boolean is not enough

The binding's appendix sketches `ICaptureAuthorizer`, whose `view` predicates return `bool`, and an operator that turns `false` into `AuthorizationDenied`, reported as `invalid_auth_capture_evm_policy_denied`. For a proof, `false` collapses two outcomes that call for opposite next steps:

| The policy's `false` meant | The server should | If the server cannot tell |
|---|---|---|
| The proof is invalid | Not resubmit that proof | It retries a proof that never passes, until the capture deadline |
| The proof could not be checked | Resubmit once the entry or the code is available again | It gives up a payment it could still capture, and the payer reclaims |

Example: a facilitator submits a capture with an entry that is not the registered one. With a boolean, the server sees `policy_denied` and cannot tell this from a tampered proof. With a status word, it sees `verifier_unavailable`, resubmits with the registered entry, and captures.

## The reason-returning check

```solidity
interface ICapturePolicyStatus {
    function captureStatus(
        PaymentInfo calldata paymentInfo, uint256 amount, uint256 feeAmount, address feeReceiver,
        bytes calldata policyData
    ) external view returns (bytes32 status);

    function chargeStatus(
        PaymentInfo calldata paymentInfo, uint256 amount, uint256 feeAmount, address feeReceiver,
        bytes calldata policyData
    ) external view returns (bytes32 status);
}
```

- The parameters are those of the appendix's `authorizeCapture` and `authorizeCharge`. The last one carries the policy's data, where the appendix passes `""`.
- Both functions are `view`. The ERC-165 identifier is `captureStatus.selector ^ chargeStatus.selector`. A policy MUST advertise it, and a facilitator MUST refuse a non-zero `extra.policy` that does not, with `invalid_auth_capture_evm_policy`.
- A policy MAY also implement the boolean hooks. They MUST return `true` exactly when the matching status is `Authorized`.
- `authorize` and `void` are not gated by this profile; they stay as the appendix defines them.

### Status words

A status is a short ASCII name, left-aligned in 32 bytes. The zero word is none of them, so a contract that answers with zeros never reads as `Authorized`.

| Word | Meaning | `errorReason` |
|---|---|---|
| `"Authorized"` | The condition holds; the operation may proceed | none |
| `"ProofInvalid"` | The registered verifier ran on the registered code and did not accept, or the output does not fit the entry | `invalid_auth_capture_evm_proof_invalid` |
| `"VerifierUnavailable"` | The proof could not be checked: unknown entry, an entry that is not the registered one, or code that is not the registered code | `invalid_auth_capture_evm_verifier_unavailable` |
| `"Denied"` | The policy refuses for a reason that is not about a proof, such as data that does not belong to this payment | `invalid_auth_capture_evm_policy_denied` |
| Any other word, zero included | Unknown to the facilitator | `invalid_auth_capture_evm_policy_denied` |

These are the only words and reasons. A policy or an operator MUST NOT define reasons of its own.

- A policy MUST answer with a status for every outcome it can name, and MUST NOT revert to express one.
- A policy MUST answer `"ProofInvalid"` only in the case the table names. "Could not be checked" MUST NOT degrade into `"ProofInvalid"` by default ([core property 1](./proof_condition.md#core-properties)): an unknown entry, an entry that is not the registered one, code that is not the registered code, and any failure the policy cannot classify MUST NOT be answered `"ProofInvalid"`.
- An operator MUST consult the check after its own unconditional checks, as the appendix orders them. On any status but `"Authorized"` it MUST revert with `PolicyRefused(bytes32 status)`, passing the word on unchanged.
- A facilitator MUST map a `PolicyRefused` word through this table. It MUST NOT map an unknown word, an unrecognised revert, or a revert with no data to `invalid_auth_capture_evm_proof_invalid`.

### What each outcome does

| Status | This attempt | The authorization |
|---|---|---|
| `"Authorized"` | Proceeds; the escrow's own checks still apply | Captured or charged |
| `"ProofInvalid"` | Reverts: nothing moves, nothing is recorded | Unchanged |
| `"VerifierUnavailable"` | Reverts: nothing moves, nothing is recorded | Unchanged |
| `"Denied"` | Reverts: nothing moves, nothing is recorded | Unchanged |

Neither proof failure ends the authorization; both refuse only this attempt. A hold stays capturable until its capture deadline (`PaymentInfo.authorizationExpiry`) and is reclaimable by the payer from that moment on, as `auth-capture` defines. A charge's token authorization stays usable until it expires (`preApprovalExpiry`).

Example: a hold of 1 USDC with a capture deadline one hour away. A capture with a tampered proof reverts with `ProofInvalid`. A capture while the verifier's code differs from the registered code reverts with `VerifierUnavailable`. One second before the deadline, the valid proof captures the whole hold. From the deadline on, no proof captures and the payer reclaims.

A transaction that cannot give the verifier its gas allowance reverts with `InsufficientGasForVerifier(uint256 required, uint256 available)` before any status is formed ([proof_condition.md](./proof_condition.md#core-properties), property 8). That is not a refusal. A facilitator MUST raise its gas limit and MUST NOT report the proof invalid.

## The proof policy

### Binding the terms

The client binds the verifier and its input commitment through its contribution to the bound salt, with the derivation `auth-capture` already defines:

```
saltNonce = uint256(keccak256(abi.encode(PROOF_TERMS_TYPEHASH, verifierId, inputCommitment)))
salt      = uint256(keccak256(abi.encode(SALT_BINDING_TYPEHASH, receiverAuthorizer, policy, saltNonce)))
PROOF_TERMS_TYPEHASH  = keccak256("ProofGatedTerms(bytes32 verifierId,bytes32 inputCommitment)")
SALT_BINDING_TYPEHASH = keccak256("x402AuthCaptureSaltBinding(address receiverAuthorizer,address policy,uint256 saltNonce)")
```

- **Why the salt nonce.** Under `"policy"` the receiver authorizer signs every capture on chain, so it cannot be an address derived from the terms that nobody holds a key for, as in the [binding for an unmodified client](./reference_evm.md#the-terms-authorizer-binding). The salt nonce is the one input left that the client controls.
- **Uniqueness.** The input commitment already carries the client's fresh randomness ([property 10](./proof_condition.md#core-properties)), so the salt nonce is unique per payment without a further random value.
- **Strength.** The terms are bound by the full 256-bit hash, not by an address truncated to 160 bits. If the client draws its randomness after the server named the verifier (property 10), capturing with other terms needs a second preimage: about 2^256 hash evaluations. A server that saw the commitment before naming the verifier could vary both sides and search for any collision: about 2^128. Both figures assume keccak256 behaves as a random function.
- **Clients.** A client MUST derive the salt nonce from the terms it means to pay for. x402's own client draws it at random today. Such a payment opens to no terms, so every attempt answers `"Denied"` and the payer reclaims after the deadline. A server MUST check the binding before it runs the resource and refuse a payment whose salt nonce is not derived from the terms it offered.

The requirement adds `extra.verifierId`, `extra.inputCommitment` and `extra.inputCommitmentFormat` to an `auth-capture` requirement; clients ignore `extra` keys they do not know. `inputCommitmentFormat` names how the client computes the commitment. The reference circuits use `ezkl/poseidon/hashed-public/v1`: EZKL's Poseidon hash over the quantised input followed by the circuit's nonce elements. Before signing, a client MUST check that `extra.inputCommitment` is the commitment it computed, and that `extra.verifierId` is the verifier first offered and stands for the circuit it wants ([reference_evm.md](./reference_evm.md#before-signing)).

### What the policy reads

```solidity
struct ProofData {
    address receiverAuthorizer;   // extra.receiverAuthorizer of the payment
    address policy;               // extra.policy of the payment: the policy itself ("policy") or zero ("custom")
    bytes32 verifierId;
    bytes32 inputCommitment;
    VerifierEntry entry;          // the registered entry of verifierId
    bytes output;                 // the circuit's public output, entry.outputSize bytes
    bytes proof;
}
policyData = abi.encode(ProofData)
```

The policy, in order:
1. Answers `"Denied"` unless `policy` is zero or the policy's own address, and unless the salt recomputed from the first four fields equals `paymentInfo.salt`.
2. Checks the proof against the registry entry ([reference_evm.md](./reference_evm.md#verifier-registry)) and answers `"Authorized"`, `"ProofInvalid"` or `"VerifierUnavailable"`.

It reverts only when `policyData` is not an encoding of `ProofData`, and with `InsufficientGasForVerifier`. It has no owner and no storage. Reference: `src/ProofCapturePolicy.sol`.

### Under the `"policy"` type

The appendix's operator ABI has no parameter for `policyData`, and its capture payload has no field for it. This profile needs both:
- `capture` and `charge` take a trailing `bytes policyData`, passed to the check unchanged.
- The `capture` lifecycle payload carries `"policyData": "0x…"`. For a `charge`, the server adds it to the client's payload before `/settle`.

The facilitator's further checks for a payload whose `extra.policy` advertises this interface:
1. `extra.policy` has code and advertises `ICapturePolicyStatus` through ERC-165, otherwise `invalid_auth_capture_evm_policy`.
2. The payload carries `policyData`, otherwise `invalid_auth_capture_evm_payload_format`.
3. Simulation; a `PolicyRefused(bytes32)` revert maps through [Status words](#status-words).

## The route today: a `"custom"` operator fixed to one policy

Until the `"policy"` type exists, a `"custom"` operator can consult one policy fixed at its deployment. The payer's signature commits to the operator through `PaymentInfo.operator`, and so to the policy. Reference: `src/PolicyCaptureOperator.sol`.

| Function | What it does |
|---|---|
| `authorize(paymentInfo, amount, tokenCollector, collectorData)` | The escrow's collect call, open to anyone; collects the full maximum |
| `charge(…)`, the escrow's ABI | Always reverts with `PolicyRequired()` |
| `captureWithPolicy(paymentInfo, policyData)` | Anyone; captures the whole hold, less the payer's minimum fee, if `captureStatus` answers `"Authorized"` |
| `chargeWithPolicy(paymentInfo, tokenCollector, collectorData, policyData)` | Anyone; collects and pays out in one step if `chargeStatus` answers `"Authorized"` |
| `voidByReceiver(paymentInfo)` | The receiver gives the hold back before the capture deadline |

The requirement is a standard `auth-capture` one with `operatorType: "custom"`, `captureAuthorizer` = the operator, `policy` zero, a non-zero `receiverAuthorizer` (the server's address; it signs nothing on this route) and `paymentFlow: "escrow"`. As for any `"custom"` operator, the facilitator relays only the collect call; `captureWithPolicy` and `chargeWithPolicy` are submitted out of band. The operator emits `CapturedWithPolicy(paymentInfoHash, amount, keccak256(policyData))`; the output itself is in the transaction's call data.

## Optional: two steps, a recorded check

The one-step route above is this profile's route. A policy MAY instead split it in two: a transaction that checks the proof and records the result, then a capture or charge whose `policyData` carries the hash of the output and the proof instead of the proof. The payer's side is unchanged: the salt binding, the requirement and the operator are those of the one-step route. Reference: `test/experimental/hash-policy/RecordedProofPolicy.sol`, through the unchanged `PolicyCaptureOperator`.

### The record

```solidity
function recordCheck(bytes32 verifierId, bytes32 inputCommitment, bytes calldata output, bytes calldata proof)
    external returns (ProofStatus);

event CheckRecorded(
    bytes32 indexed key, bytes32 indexed verifierId, bytes32 indexed inputCommitment, bool valid, bytes output
);
```

```
proofHash = keccak256(abi.encode(output, proof))
key       = keccak256(abi.encode(verifierId, inputCommitment, proofHash))
```

- Wherever a record exists, it MUST be stored under this key. The policy can tie a record to a payment only through the terms the payer's salt binds, so the input commitment MUST stand in the key beside the verifier id, not only inside `proofHash`. A key without it would let a presenter open one payment with a valid record for another commitment.
- Only `Valid` and `Invalid` MUST be recorded. A check that ends `Unverifiable` MUST store nothing, so the same proof can be presented again once it can be checked ([core property 1](./proof_condition.md#core-properties)).
- A recorded result MUST NOT change. A call for a key already recorded returns the stored result without checking again; a registered entry's code cannot change ([property 9](./proof_condition.md#core-properties)), so a second check would give the same answer.
- The record's event MUST carry the key and the output ([property 2](./proof_condition.md#core-properties)).
- `recordCheck` MAY be open to anyone. It checks the proof against the registry entry as the one-step policy does, and reverts with `InsufficientGasForVerifier`, recording nothing, when it cannot give the verifier its allowance.

### What the policy reads on this route

```solidity
struct HashData {
    address receiverAuthorizer;   // as in ProofData
    address policy;               // as in ProofData
    bytes32 verifierId;
    bytes32 inputCommitment;
    bytes32 proofHash;            // keccak256(abi.encode(output, proof))
}
policyData = abi.encode(HashData)
```

The policy, in order:
1. Answers `"Denied"` unless `policy` is zero or the policy's own address, and unless the salt recomputed from the first four fields equals `paymentInfo.salt`, as on the one-step route.
2. Reads the record under the key of `verifierId`, `inputCommitment` and `proofHash`. `Valid` is `"Authorized"`, `Invalid` is `"ProofInvalid"`, and no record is `"VerifierUnavailable"`. No record MUST NOT be answered `"ProofInvalid"`: a proof that nobody has recorded yet and a proof whose verifier cannot run read the same, and neither was decided.

The status words, the outcomes and the error codes are this profile's. A capture that finds no record reverts with `PolicyRefused("VerifierUnavailable")`; the server records the check and captures again.

### What changes against one step

- **Where the output is.** It is in `recordCheck`'s `CheckRecorded` event, not in the transaction that moves the funds. That transaction carries `verifierId`, `inputCommitment` and `proofHash`, from which the key follows ([property 2](./proof_condition.md#core-properties)).
- **Records are shared.** A `Valid` record serves every payment bound to the same verifier and commitment with the same output and proof; the commitment's fresh randomness ([property 10](./proof_condition.md#core-properties)) keeps that to one payment. A third party can record only the true result for the exact bytes it submits: an `Invalid` record for a tampered proof has a key of its own and does not touch the real proof's.
- **Cost.** One more transaction and one new storage slot per payment.

### Gas, two steps

Measured as in [Gas](#gas), steady. `recordCheck` writes a fresh record, as for a payment with its own fresh input commitment. The one-step figures are those of [Gas](#gas).

| Transaction | Test token | USDC |
|---|---:|---:|
| `recordCheck`, a fresh record | 727,888 | 727,888 |
| `captureWithPolicy`, `HashData` | 74,270 | 85,116 |
| **Two steps** | **802,158** | **813,004** |
| One step: `captureWithPolicy`, `ProofData` | 739,872 | 750,718 |
| Difference | +62,286 | +62,286 |

Most of the difference is the second transaction's 21,000 and the new slot's 22,100, cold access included; the rest is the event carrying the output, the registry entry read inside `recordCheck`, and the policy's cold storage read at capture.

## Error codes

Two reasons are added to `auth-capture`'s list; the others are its own.

| Error code | When |
|---|---|
| `invalid_auth_capture_evm_proof_invalid` | A policy answered `"ProofInvalid"`. Resubmitting the same proof cannot succeed. |
| `invalid_auth_capture_evm_verifier_unavailable` | A policy answered `"VerifierUnavailable"`. Nothing was decided about the computation; the same proof may succeed later, up to the capture deadline. |
| `invalid_auth_capture_evm_policy_denied` | Existing. A policy answered `"Denied"` or a word the facilitator does not know. |

| Typed simulation revert | `invalidReason` |
|---|---|
| `PolicyRefused(bytes32 status)` | By the word, through [Status words](#status-words) |
| `InsufficientGasForVerifier(uint256,uint256)` | Not a refusal: raise the gas limit and simulate again |

## Gas

Measured locally under the Osaka schedule with the real solo proof, every account cold, x402's escrow built from source (`test/ProofCapturePolicyGas.t.sol`). "Steady": the operator has paid out before and holds another payment. USDC is Circle's on a fork of Base Sepolia at block 62,638,490.

| Transaction, steady | Test token | USDC | The same through `captureWithProof` |
|---|---:|---:|---:|
| `authorize` | 126,385 | 148,643 | 126,385; 148,600 |
| `captureWithPolicy` | 739,872 | 750,718 | 735,804; 746,650 |
| `authorize` + capture | 866,257 | 899,361 | 862,189; 895,250 |
| `chargeWithPolicy` | 816,774 | 841,355 | 812,420; 836,981 |

The reason-returning policy costs about 4,100 gas more per payment than the [terms-authorizer operator](./reference_evm.md#the-terms-authorizer-binding). For a capture with the test token, 584 of the 4,068 is call data (`policyData` is ABI-encoded inside a `bytes` argument and also names the two bound addresses) and 3,484 is execution (decoding into memory, and one more call, into the policy). 577,544 of each capture is the generated verifier.

## Security considerations

- **Read-only.** The check is `view`: it cannot move value, re-enter the escrow or leave state. Its only cost is gas. The operator's own checks run whatever it answers.
- **No silent downgrade.** Unknown words and unrecognised reverts map to `policy_denied` or `simulation_failed`, never to `proof_invalid`. A server that sees `proof_invalid` knows a verifier ran and said no.
- **Griefing.** Every refusal reverts and records nothing, so a third party cannot attach a failure to someone else's hold, and the hold stays capturable. On the two-step route a third party can record a check, but only the true result for the bytes it submits, under those bytes' own key.
- **Stock clients.** A client that does not derive the salt nonce from the terms cannot be captured under this policy: escrow safety only, and its hold returns to it after the deadline.
- **What the policy does not decide.** The policy does not constrain the amount or the fee. Under `"policy"` the authorizer's signature fixes them; on the `"custom"` route the operator takes the whole hold and the payer's minimum fee.
- The reference contracts are unaudited; see [reference_evm.md](./reference_evm.md#security-considerations).

## Open points for the maintainers

- Whether the reserved type's hooks can return a status word instead of a `bool`, with the words of this profile in the binding's own text.
- Whether the operator ABI and the `capture` payload can carry `policyData`, which the appendix currently passes as `""`.
- Whether the two new reasons belong to `auth-capture`'s namespace or to a shared one that `batch-settlement` would use too.

## Version History

| Version | Date | Changes | Authors |
|---|---|---|---|
| v0.2 | 2026-11-25 | First draft of the profile | @achemperety |
| v0.3 | 2026-11-25 | Optional two-step route: a recorded check, opened by its key; one step stays the profile's route | @achemperety |
