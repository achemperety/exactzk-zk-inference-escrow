# A proof condition on EVM: reference implementation and gas baseline

## Summary

This file describes the contracts that realise the [proof condition](./proof_condition.md) on EVM: the parts every host binding shares (registry, adapters, proof check), the native settlement contracts that serve as the reference implementation and the gas baseline, and the two `auth-capture` operators. None has an owner, an upgrade path or a fee.

| Contract | Role |
|---|---|
| `VerifierRegistry` | An append-only list of verifiers, each identified by a hash of its contents |
| Proof-system adapters (`IProofVerifier`) | One per proof system, for example `Halo2EzklAdapter` for EZKL-generated Halo2 verifiers. Nothing above the adapter sees a proof system's own interface |
| `ProofCheck` | The one place a proof is checked; returns Valid, Invalid or Unverifiable |
| `SoloSettlement` | Native: one payment per proof, in one transaction (`settle`) or through a lock (`open`, then `release` or `refund`) |
| `ChannelSettlement` | Native: prepaid channels, one proof settles up to K requests |
| `ProofCapturePolicy`, `PolicyCaptureOperator` | `auth-capture`: the [proof policy](./auth_capture_policy_evm.md) and the `"custom"` operator fixed to it |
| `AuthCaptureProofOperator` | `auth-capture`: the [terms-authorizer binding](#the-terms-authorizer-binding), which an unmodified x402 client can pay |

The native contracts settle payments of their own, with their own wire format in the reference server and clients. That format is not proposed for x402; the contracts stay because they are the condition in its plainest form and the baseline the compositions are measured against.

## Verifier registry

```solidity
struct VerifierEntry {
    address adapter;          // IProofVerifier
    uint32  lanes;            // statements per proof; 1 for a solo circuit
    uint32  outputSize;       // bytes of output per lane
    uint32  verifyGas;        // gas handed to the adapter
    address target;           // the system-specific verifier contract
    bytes32 adapterCodeHash;  // EXTCODEHASH of adapter
    bytes32 targetCodeHash;   // EXTCODEHASH of target
    bytes32 vkHash;           // keccak256 of the verifying key; declared, not enforced
    bytes32 emptyLane;        // commitment of a padding lane; 0 if none
}
verifierId = keccak256(abi.encode(adapter.proofSystem(), vkHash, targetCodeHash, adapterCodeHash,
                                  lanes, outputSize, verifyGas, emptyLane))
```

- `register(entry)` is open to anyone and MUST revert if the id exists, if either account has no code or other code than declared, or if either account's code begins with `0xef0100` (an EIP-7702 delegation, whose code hash stays fixed while the code that runs lives elsewhere). Entries never change.
- The id commits to code, not to addresses: whoever registers first chooses the deployed copies. Adapters and generated verifiers read no storage, so every copy behaves the same.
- Every use MUST re-check both code hashes. A mismatch, an unknown id or an entry that does not hash to the registered one makes the proof **unverifiable**, not invalid.
- The gas allowance is part of the id, so the same circuit with another allowance is another entry. A transaction MUST carry at least `verifyGas + verifyGas/63 + 5,000` gas at the check, or revert with `InsufficientGasForVerifier`. An adapter that reverts, runs out of gas or returns anything but one word equal to 1 means **invalid**.

Example, the reference solo entry: `lanes` 1, `outputSize` 320, `verifyGas` 600,000, `targetCodeHash` `0x8cd0b80f…5f49`, `vkHash` `0x13cff042…4ff2`, `emptyLane` 0, id `0xc302c686…ff9b`.

## What binds what

| Value | Native `SoloSettlement`: the payment's id | `auth-capture` proof policy: `PaymentInfo.salt` | `batch-settlement` gate: the commitment root | The proof |
|---|---|---|---|---|
| Chain id, the contract | Yes, in the id; the two flows use different EIP-712 types | Through the escrow's payment hash and the token signature | The gate's EIP-712 domain; the channel id | No |
| Payer, recipient, asset, amount, deadline | Yes | Yes, `PaymentInfo` | The channel and the voucher | No |
| `verifierId` | Yes | Yes, in the salt nonce | Yes, in the root's struct | Checked against that entry's code, so only its circuit's proofs verify |
| `inputCommitment` | Yes | Yes, in the salt nonce | Yes, as the leaf at its position | Yes: the first public input of each lane |
| Output | No: unknown when the client signs | No | No | Yes: the remaining public inputs |

The proof is not bound to a payment. A proof for a given verifier and commitment satisfies any payment that names both, so commitments MUST be unique; the client's randomness inside the commitment makes them so.

## Native settlement

`SoloSettlement` takes one ERC-3009 `ReceiveWithAuthorization` whose nonce is the payment's id, an EIP-712 struct hash of the terms:

```
requestId = keccak256(abi.encode(TYPEHASH, chainId, settlement, payer, payTo, asset, amount,
                                 verifierId, inputCommitment, proveBy, salt))
TYPEHASH  = keccak256("ProofGatedPayment(uint256 chainId,address settlement,address payer,address payTo,address asset,uint256 amount,bytes32 verifierId,bytes32 inputCommitment,uint64 proveBy,bytes32 salt)")
            for one transaction; "ProofGatedEscrow(…same fields…)" for the lock
```

| Call | Effect |
|---|---|
| `settle(terms, entry, validBefore, signature, output, proof)` | Proof checked, authorization collected, `payTo` paid, `Settled(requestId, verifierId, payTo, output)` |
| `open(terms, validBefore, signature)` | Amount locked; `Opened` |
| `release(terms, entry, output, proof)` | Proof checked up to `proveBy`; `payTo` paid; `Settled` |
| `refund(terms)`, by anyone after `proveBy` | Payer repaid; `Refunded` |

`entry` is the registered entry, passed whole so the contract authenticates it with one storage read instead of six. The proof for the reference circuits is 3,840 bytes.

`ChannelSettlement` applies the condition to prepaid channels: a voucher per request, `Voucher(bytes32 channelId,uint48 seq,uint96 amount,uint96 cumAmount,bytes32 inputCommitment,uint40 proveBy)`, and `settleBatch` with one proof for up to K vouchers. `BatchSettled` carries one result per lane only after the proof verified ([property 6](./proof_condition.md#core-properties)). A channel's windows have floors: prove window ≥ 60 s, challenge window ≥ 300 s. Clients SHOULD default to 10 minutes and 24 hours, long enough to fill and prove a batch, and to answer a close request through an outage.

### Before signing

Whatever the host scheme, a client MUST:
1. Accept only a `verifierId` it knows to stand for the circuit it wants (the id fixes the shape), read the entry, and refuse it unless it exists and its code hashes match the accounts' code. A client that does not rerun the [model identity](./proof_condition.md#model-identity) steps relies on whoever published the model-to-entry mapping.
2. Draw its randomness after it has received `verifierId`, compute `inputCommitment` over its input and that randomness, and refuse a later offer naming another `verifierId`.

## The terms-authorizer binding

`AuthCaptureProofOperator` is a `"custom"` operator that runs with x402's own client, unmodified. The server publishes the terms as the receiver authorizer, an address nobody holds a key for:

```
receiverAuthorizer = address(uint160(uint256(keccak256(abi.encode(
    keccak256("ProofGatedTerms(bytes32 verifierId,bytes32 inputCommitment)"), verifierId, inputCommitment)))))
```

The client binds `receiverAuthorizer` into the salt as `auth-capture` prescribes, with `policy` zero. Anyone may then call `captureWithProof` or `chargeWithProof` with the terms, the client's `saltNonce` and a valid proof; the operator's plain `charge` always reverts. The receiver may give a hold back (`voidByReceiver`); after the capture deadline the payer reclaims it from the escrow.

- **A stock client gets escrow safety only.** It signs whatever `receiverAuthorizer` it is offered. At most the signed amount goes to the signed receiver, and the payer can reclaim after the deadline, but a server could bind terms it can prove trivially. The proof condition holds for a client that recomputes `receiverAuthorizer` from the terms it means to pay for and compares it before signing.
- **Collision bounds.** `receiverAuthorizer` keeps 160 bits. If the client draws its randomness after the server named the verifier, capturing with other terms needs a second preimage of a random 160-bit target: about 2^160 hash evaluations. A server that saw the commitment before naming the verifier could vary both sides and search for any collision: about 2^80. Both figures assume keccak256 truncated to 160 bits behaves as a random function.
- **It cannot move to the `"policy"` type.** That type requires the receiver authorizer to sign every capture on chain, and nobody holds this address's key. The [proof policy](./auth_capture_policy_evm.md#binding-the-terms) binds through the salt nonce instead, at 256 bits, and needs a client that derives it.

## Error codes

Every contract error maps to one outcome of [proof_condition.md](./proof_condition.md#outcomes-of-a-check) and one `errorReason`. The `auth-capture` reasons are defined in [Status words](./auth_capture_policy_evm.md#status-words), and the reference middleware and clients (`clients/`, `x402/`) emit them for the native contracts too. The last column gives the names v3.0.0-testnet emitted. The middleware now emits the specification's names for the two proof failures, and still emits the names in the last column for the other errors.

| Contract error | Outcome | `errorReason` | Emitted by v3.0.0-testnet |
|---|---|---|---|
| `ProofInvalid()` | Invalid | `invalid_auth_capture_evm_proof_invalid` | `invalid_proof_gated_evm_invalid_proof` |
| `VerifierUnavailable(bytes32)` | Unverifiable | `invalid_auth_capture_evm_verifier_unavailable` | `invalid_proof_gated_evm_verifier_unavailable` |
| `PolicyRefused(bytes32 status)` | By the word | By the word | |
| `InsufficientGasForVerifier(uint256,uint256)` | None: the transaction was short of gas | Not a refusal | `invalid_proof_gated_evm_insufficient_gas` |
| `TermsMismatch()` (terms-authorizer operator) | Denied | `invalid_auth_capture_evm_policy_denied` | `invalid_proof_gated_evm_terms_mismatch` |
| `Expired()` (native) | | | `invalid_proof_gated_evm_expired` |
| `AlreadyOpened(bytes32)` (native) | | | `invalid_proof_gated_evm_payment_already_used` |
| `NotOpen(bytes32)` (native) | | | `invalid_proof_gated_evm_not_open` |
| `TransferFailed()` (native) | | | `invalid_proof_gated_evm_transfer_failed` |

The reference middleware also maps the terms-authorizer operator's `PartialAuthorization` and `WrongOperator()`, and defines reasons for checks made before any contract call: `invalid_proof_gated_evm_nonce_mismatch`, `…_authorization_mismatch`, `…_prove_by`, `…_unsupported_payment_flow`, `…_signature`, `…_verify_gas_too_high`, `…_prover_commitment_mismatch` (the server's prover proved another input than the client committed to), `…_simulation_failed` and `…_transaction_reverted`.

A failed check answers 402 with the failing `PAYMENT-RESPONSE` and no output. Example, a tampered proof; the client's authorization stays unused:

```json
{ "success": false, "transaction": "", "network": "eip155:84532", "payer": "0xPayerAddress",
  "errorReason": "invalid_auth_capture_evm_proof_invalid" }
```

## Security considerations

- **Replay.** Native: the payment's id is the ERC-3009 nonce, which the token accepts once; the lock also records the id, and two flows use two EIP-712 types. `auth-capture`: the escrow's payment hash commits to every `PaymentInfo` field and the token accepts the nonce once. Example: resubmitting a settled `settle` reverts in the token (nonce used); a second `open` of the same terms reverts with `AlreadyOpened`.
- **Authorization scope.** The client's signature fixes recipient, amount, asset, verifier, commitment and deadline. A submitter chooses only the proof and when to submit it.
- **Settlement atomicity.** Payment and published output are the same state transition.
- **Griefing.** Failed proofs revert and record nothing, so a third party cannot attach a failure to someone else's payment. Under-funding the verifier reverts rather than failing a valid proof.
- **The registry does not vouch for the verifying key.** `vkHash` is declared; the mapping from model to code is checked off-chain ([Model identity](./proof_condition.md#model-identity)).
- **Setup assumptions.** The reference circuits use a KZG reference string generated locally by one party: adequate for a testnet, not for value.
- **Unaudited.** The reference contracts are deployed on a testnet only and have not been audited. `ProofCapturePolicy`, `PolicyCaptureOperator` and the `batch-settlement` gate are not deployed.

## Reference deployment

Contracts from this repository's `src/`, on Base Sepolia (chain id 84532), deployed from a fresh account:

| Contract | Address |
|---|---|
| `VerifierRegistry` | `0xc754b4d635a1f4C67Bb09156aE078f648ae06cF1` |
| `Halo2EzklAdapter` | `0x070d8A6485ea5a813E949FeB57BCE9b2d35a64a5` |
| `SoloSettlement` | `0x0934cC0B3Fef6d8f9F8f87f40aFCfF59f668c729` |
| `ChannelSettlement` | `0x93e8E5745dB6eAb0eAC16FF2Dbfdd78A0C55c56B` |
| `AuthCaptureProofOperator` (escrow `0xf968…B19c`) | `0x039e3fFd1778bb91be2961b09999FDf58EcF68Ab` |

Registered: solo `0xc302c686…ff9b` (`verifyGas` 600,000) and K=8 `0xff34bcad…1107` (660,000). Measured on Base Sepolia with USDC: `settle` 766,226 gas; `open` + `release` 839,705; K=8 batch from one channel 860,315 (receipts in `measurements/2026-11-24-testnet/`). A TypeScript client and Python middleware are in `clients/`.

## Gas baseline

Local, Osaka schedule, real proofs, every account cold, steady unless marked. USDC is Circle's on a fork of Base Sepolia at block 62,638,490. Sources in [REVIEW.md](./REVIEW.md#numbers).

| Route | Gas |
|---|---:|
| Native, one transaction: `settle`, USDC | 768,174 |
| Native, lock: `open` + `release`, USDC | 841,293 |
| Native, channel: per request in a K=8 batch; K=16 | 113,661; 71,066 |
| `auth-capture`, terms-authorizer operator: `authorize` + `captureWithProof`; `chargeWithProof`, USDC | 895,250; 836,981 |
| `auth-capture`, proof policy: `authorize` + `captureWithPolicy`; `chargeWithPolicy`, USDC | 899,361; 841,355 |
| `batch-settlement` gate (prototype): one claim, steady; the channel's first claim | 769,210; 797,428 |

Of each solo-proof row, 577,544 is the generated verifier.

## Version History

| Version | Date | Changes | Authors |
|---|---|---|---|
| v0.1 | 2026-11-24 | The EVM binding of the dedicated-scheme draft | @achemperety |
| v0.2 | 2026-11-25 | The reference implementation and gas baseline of the proof condition; the dedicated scheme's wire format removed | @achemperety |
