# PROTOTYPE: hash-only `policyData` for the `auth-capture` proof policy

Not part of the specification and not to be merged as it stands. The policy profile in `specs/schemes/proof-gated/auth_capture_policy_evm.md` is unchanged.

`RecordedProofPolicy.sol` splits today's one-step capture in two:

1. `recordCheck(verifierId, inputCommitment, output, proof)`, open to anyone, runs the proof check and stores `Valid` or `Invalid` under `keccak256(abi.encode(verifierId, inputCommitment, keccak256(abi.encode(output, proof))))`. A check that cannot run stores nothing, so the proof can be presented again once it can be checked. A stored result never changes.
2. The policy hook takes `policyData` with no proof in it: the salt's two addresses, `verifierId`, `inputCommitment`, and the hash of the output and the proof. Terms that do not open the payment's salt are `Denied`; no record is `VerifierUnavailable`, never `ProofInvalid`; a recorded `Invalid` is `ProofInvalid`; a recorded `Valid` is `Authorized`.

The capture runs through the unchanged `PolicyCaptureOperator`.

## The key holds the input commitment in the clear

The request was a record under `keccak256(verifierId, proof)`. A proof is valid or invalid only for its public inputs, so those must be in what is hashed. And the policy can tie a record to a payment only through the terms the payer's salt binds, `verifierId` and `inputCommitment`. If the commitment were hidden inside the proof's hash, a presenter could pair a payment with a valid record for another commitment. `test_a_valid_record_for_another_commitment_does_not_open_this_payment` shows the refusal; mutation HP1, a key without the commitment, makes it pass that payment.

## Gas

Real solo proof, Osaka schedule, x402's escrow built from source, every account cold, steady. `recordCheck` writes a fresh record; its slot is cleared before measuring, as for a payment with its own fresh input commitment. USDC is Circle's on a fork of Base Sepolia at block 62,638,490. Today's one-step figure is `test/ProofCapturePolicyGas.t.sol`, the same method; its USDC figure was measured again in the same session.

| | Test token | USDC |
|---|---:|---:|
| `recordCheck`, a fresh record | 727,888 | 727,888 |
| `captureWithPolicy`, hash-only `policyData` | 74,270 | 85,116 |
| **Two steps** | **802,158** | **813,004** |
| Today: one-step `captureWithPolicy` | 739,872 | 750,718 |
| Difference | +62,286 | +62,286 |

The difference is a second transaction (21,000), the new storage slot (22,100 with its cold access), the event carrying the output, the policy's cold storage read at capture, and the entry read from the registry inside `recordCheck`.

## What it changes against the profile

- **The output is not in the transaction that moves the funds.** It is in `recordCheck`'s `CheckRecorded` event; the capture carries only its hash. Core property 2 of `proof_condition.md` requires the paying transaction to carry the output, so the profile would have to accept the record's event in its place.
- **Records are shared.** A `Valid` record serves every payment with the same verifier, commitment, output and proof; the input commitment's fresh nonces keep it to one payment. A third party can record only the true result of the exact bytes it submits, so it cannot pin `Invalid` on someone else's proof.
- **"Not checked" is the absence of a record.** A capture before anyone recorded the proof, and a capture whose verifier cannot run, both read `VerifierUnavailable`.

## Tests

`RecordedProofPolicy.t.sol`: 9 behaviour tests, one gas test, and one opt-in USDC fork test. Mutations HP1–HP10 are in `test/MUTATIONS.md`.

    forge test --match-path 'test/experimental/hash-policy/*.t.sol' -vv
    FORK_RPC_URL=https://sepolia.base.org FORK_BLOCK=62638490 \
        forge test --match-path 'test/experimental/hash-policy/*.t.sol' -vv
