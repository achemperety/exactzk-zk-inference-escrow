# Scheme: `proof-gated` on `EVM` (draft)

## Summary

This is the EVM binding of [`proof-gated`](./scheme_proof_gated.md). Three contracts realise it; none has an owner, an upgrade path or a fee:

- `VerifierRegistry`: an append-only list of verifiers, each identified by a hash of its contents.
- Proof-system adapters (`IProofVerifier`): one per proof system, for example `Halo2EzklAdapter` for EZKL-generated Halo2 verifiers. Settlement never sees a proof system's own interface.
- `SoloSettlement`: one payment per proof, in the `authorization` flow (`settle`) or the `escrow` flow (`open`, then `release` or `refund`).

The client produces one signature: an ERC-3009 `ReceiveWithAuthorization` whose recipient is `SoloSettlement` and whose nonce is the payment's request id, an EIP-712 struct hash of the terms. Core types (`PaymentRequirements`, `PaymentPayload`, `SettlementResponse`) are those of [x402-specification-v2.md](../../x402-specification-v2.md) and are not redefined here.

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

| Value | Client's signature (request id) | Proof |
|---|---|---|
| Chain id, `SoloSettlement` address, flow | Yes: they are in the request id, and the two flows use different EIP-712 types | No |
| `payer`, `payTo`, `asset`, `amount`, `proveBy`, `salt` | Yes | No |
| `verifierId` | Yes | The proof is checked against that entry's code, so only its circuit's proofs verify |
| `inputCommitment` | Yes | Yes: the first public input of each lane |
| Output | No: unknown when the client signs | Yes: the remaining public inputs; published in `Settled` |

The proof is not bound to a request. A proof for a given verifier and commitment settles any request that names both, so commitments MUST be unique; the client's randomness inside the commitment makes them so.

## `PaymentRequirements`

```json
{
  "scheme": "proof-gated",
  "network": "eip155:84532",
  "amount": "10000",
  "asset": "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
  "payTo": "0xProviderAddress",
  "maxTimeoutSeconds": 600,
  "extra": {
    "name": "USDC",
    "version": "2",
    "paymentFlow": "authorization",
    "settlement": "0x0934cC0B3Fef6d8f9F8f87f40aFCfF59f668c729",
    "verifierId": "0xc302c6867eddfdcd201bbe7fb653191da6ee4c1a178e7df821e9ebca01b6ff9b",
    "inputCommitmentFormat": "ezkl/poseidon/hashed-public/v1",
    "proveWindowSeconds": 600
  }
}
```

| `extra` field | Required | Type | Description |
|---|---|---|---|
| `name`, `version` | Yes | `string` | EIP-712 domain of the token, for the ERC-3009 signature |
| `paymentFlow` | Yes | `"authorization"` \| `"escrow"` | See [Payment flows](./scheme_proof_gated.md#payment-flows) |
| `settlement` | Yes | `address` | The `SoloSettlement` contract: the authorization's `to` and the request id's `settlement` |
| `verifierId` | Yes | `bytes32` | The registry entry whose circuit must produce the proof |
| `inputCommitmentFormat` | Yes | `string` | How the client computes `inputCommitment`. `ezkl/poseidon/hashed-public/v1`: EZKL's Poseidon over the quantised input followed by the circuit's nonce elements |
| `proveWindowSeconds` | Yes | `uint` | How far ahead the client sets `proveBy`; `proveBy` MUST be at most `now + proveWindowSeconds + maxTimeoutSeconds` |
| `assetTransferMethod` | No | `"eip3009"` | The only method |

A server SHOULD set `proveWindowSeconds` to at least its proving time plus two blocks; the reference server uses 600.

## Client payment payload

```json
{
  "terms": {
    "payer": "0xPayerAddress", "payTo": "0xProviderAddress",
    "asset": "0x036CbD53842c5426634e7929541eC2318f3dCF7e", "amount": "10000",
    "verifierId": "0xc302c6867eddfdcd201bbe7fb653191da6ee4c1a178e7df821e9ebca01b6ff9b",
    "inputCommitment": "0x…", "proveBy": 1795509622, "salt": "0x…"
  },
  "authorization": {
    "from": "0xPayerAddress", "to": "0x0934cC0B3Fef6d8f9F8f87f40aFCfF59f668c729", "value": "10000",
    "validAfter": "0", "validBefore": "1795509622", "nonce": "0x<request id>"
  },
  "signature": "0x…"
}
```

The nonce is the request id:

```
requestId = keccak256(abi.encode(TYPEHASH, chainId, settlement, payer, payTo, asset, amount,
                                 verifierId, inputCommitment, proveBy, salt))
TYPEHASH  = keccak256("ProofGatedPayment(uint256 chainId,address settlement,address payer,address payTo,address asset,uint256 amount,bytes32 verifierId,bytes32 inputCommitment,uint64 proveBy,bytes32 salt)")
            for authorization; "ProofGatedEscrow(…same fields…)" for escrow
```

Before signing, a client MUST:
1. Accept only a `verifierId` it knows to stand for the circuit it wants (the id fixes the shape), read the entry, and refuse it unless it exists and its code hashes match the accounts' code. A client that does not rerun the [model identity](./scheme_proof_gated.md#model-identity) steps relies on whoever published the model-to-entry mapping.
2. Draw its nonce elements after it has received `verifierId`, compute `inputCommitment` over its input and them, and refuse a later offer naming another `verifierId`.
3. Set `validAfter` 0 and `validBefore` to `now + maxTimeoutSeconds` or later. In `authorization` the payment can settle only while both `validBefore` and `proveBy` hold.

## Completing the payload for settlement

After the resource has run, the server adds the proof group to the payload before `/settle`:

```json
"proof": {
  "entry": { "adapter": "0x070d…64a5", "lanes": 1, "outputSize": 320, "verifyGas": 600000, "…": "…" },
  "output": "0x<320 bytes>",
  "proof": "0x<3,840 bytes for the reference circuits>"
}
```

`entry` is the registered entry, passed whole so the contract authenticates it with one storage read instead of six.

## Verification

For a payload with or without the proof group, a facilitator MUST, in order:
1. **Scheme, network, flow**: `proof-gated`, the same `eip155:<chainId>` on both sides, `paymentFlow` one of the two values.
2. **Terms match the offer**: `payTo`, `asset`, `amount`, `verifierId` equal the requirements; `authorization.to` and `extra.settlement` equal the settlement contract; `authorization.value` equals `amount`.
3. **Deadlines**: `now < proveBy ≤ now + proveWindowSeconds + maxTimeoutSeconds`; `validAfter` 0; `validBefore > now`.
4. **Nonce**: recompute the request id for the flow and require it to equal `authorization.nonce`. This binds every term at once.
5. **Signature**: verify the ERC-3009 signature for `payer` (ECDSA or ERC-1271).
6. **Entry**: `registry.exists(verifierId)`; with a proof group, `keccak256(abi.encode(entry)) == registry.entryHash(verifierId)`.
7. **Simulate** the call of [Settlement](#settlement) and require success. A revert is mapped through [Error codes](#error-codes).

`/verify` never needs the proof; the resource server calls it before proving.

## Settlement

| Flow | Payload | Call | Effect |
|---|---|---|---|
| `authorization` | with proof group | `settle(terms, entry, validBefore, signature, output, proof)` | Proof checked, authorization collected, `payTo` paid, `Settled(requestId, verifierId, payTo, output)` |
| `escrow`, first | without | `open(terms, validBefore, signature)` | Amount locked; `Opened` |
| `escrow`, second | with proof group | `release(terms, entry, output, proof)` | Proof checked up to `proveBy`; `payTo` paid; `Settled` |
| `escrow`, after `proveBy` | not relayed | `refund(terms)`, by anyone | Payer repaid; `Refunded` |

A facilitator MUST re-verify, submit with a gas limit that covers the entry's `verifyGas` plus the call ([measured totals](#reference-implementation)), wait for the receipt, and return the transaction hash. Settlement is atomic: the proof check, the token movement and the published output are one transaction, or none of them happens.

`SettlementResponse.extra` for `escrow`'s first settle SHOULD carry the request id, so the server can release it later.

## `/supported`

```json
{
  "kinds": [{
    "x402Version": 2, "scheme": "proof-gated", "network": "eip155:84532",
    "extra": { "settlements": ["0x0934cC0B3Fef6d8f9F8f87f40aFCfF59f668c729"], "maxVerifyGas": 1000000 }
  }],
  "extensions": [], "signers": { "eip155:*": ["0xFacilitatorSignerAddress"] }
}
```

- `settlements` lists the settlement contracts the facilitator relays to. A server MUST use one of them as `extra.settlement`.
- `maxVerifyGas` is the largest entry allowance the facilitator will pay for; it MUST refuse a larger one with `invalid_proof_gated_evm_verify_gas_too_high`.

## Error codes

Reasons this binding defines are namespaced `invalid_proof_gated_evm_*`; standard x402 reasons such as `invalid_network` keep their names.

| Error code | Contract error | When |
|---|---|---|
| `invalid_proof_gated_evm_invalid_proof` | `ProofInvalid()` | The proof was checked and rejected. Retrying the same proof cannot succeed. |
| `invalid_proof_gated_evm_verifier_unavailable` | `VerifierUnavailable(bytes32)` | The proof could not be checked: unknown entry, an entry that is not the registered one, or code that is not the registered code. Nothing was decided about the computation. |
| `invalid_proof_gated_evm_insufficient_gas` | `InsufficientGasForVerifier(uint256,uint256)` | The transaction could not give the verifier its allowance |
| `invalid_proof_gated_evm_expired` | `Expired()` | `proveBy` has passed |
| `invalid_proof_gated_evm_payment_already_used` | `AlreadyOpened(bytes32)` | The escrow request id was already opened |
| `invalid_proof_gated_evm_not_open` | `NotOpen(bytes32)` | Release or refund of a request that is not locked |
| `invalid_proof_gated_evm_transfer_failed` | `TransferFailed()` | The token refused the transfer |
| `invalid_proof_gated_evm_terms_mismatch` | | Terms differ from the requirements |
| `invalid_proof_gated_evm_nonce_mismatch` | | The nonce is not the request id |
| `invalid_proof_gated_evm_authorization_mismatch` | | `to` or `value` differ from the terms |
| `invalid_proof_gated_evm_prove_by` | | `proveBy` is outside the allowed window |
| `invalid_proof_gated_evm_unsupported_payment_flow` | | `paymentFlow` is missing or unknown |
| `invalid_proof_gated_evm_signature` | | The ERC-3009 signature does not verify |
| `invalid_proof_gated_evm_verify_gas_too_high` | | The entry's allowance exceeds the facilitator's `maxVerifyGas` |
| `invalid_proof_gated_evm_prover_commitment_mismatch` | | The server's prover proved another input than the client committed to (server-side check before settling) |
| `invalid_proof_gated_evm_simulation_failed` | | Simulation reverted with an unmapped error |
| `invalid_proof_gated_evm_transaction_reverted` | | The confirmed transaction reverted |

A failed check answers 402 with the failing `PAYMENT-RESPONSE` and no output. Example, a tampered proof in `authorization`; the client's authorization stays unused:

```json
{ "success": false, "transaction": "", "network": "eip155:84532", "payer": "0xPayerAddress",
  "errorReason": "invalid_proof_gated_evm_invalid_proof" }
```

## Composition with `auth-capture`

The same proof check drives a `"custom"` operator for x402's `auth-capture` EVM binding, with no change to the escrow, the facilitator or the client. The server publishes the terms as the receiver authorizer, an address nobody holds a key for:

```
receiverAuthorizer = address(uint160(uint256(keccak256(abi.encode(
    keccak256("ProofGatedTerms(bytes32 verifierId,bytes32 inputCommitment)"), verifierId, inputCommitment)))))
```

The requirement is a standard `auth-capture` one with `operatorType: "custom"`, `captureAuthorizer` = the operator, `paymentFlow: "escrow"`, `captureMode: "deferred"`, `policy` zero, and `extra.verifierId`, `extra.inputCommitment`, `extra.inputCommitmentFormat` added. The client binds `receiverAuthorizer` into the salt as that binding prescribes. Anyone may then call `captureWithProof` or `chargeWithProof` with the terms, the client's `saltNonce` and a valid proof; the operator's plain `charge` always reverts. The receiver may give a hold back (`voidByReceiver`); after the capture deadline the payer reclaims it from the escrow.

- **A stock `auth-capture` client gets escrow safety only.** It signs whatever `receiverAuthorizer` it is offered. At most the signed amount goes to the signed receiver, and the payer can reclaim after the deadline, but a server could bind terms it can prove trivially. The proof condition holds for a client that recomputes `receiverAuthorizer` from the terms it means to pay for and compares it before signing.
- **Collision bounds.** `receiverAuthorizer` keeps 160 bits. If the client draws its randomness after the server named the verifier (core property 8), capturing with other terms needs a second preimage of a random 160-bit target: about 2^160 hash evaluations. A server that saw the commitment before naming the verifier could vary both sides and search for any collision: about 2^80. Both figures assume keccak256 truncated to 160 bits behaves as a random function and that the server cannot predict the client's randomness.

## Batches

`ChannelSettlement` applies the condition to prepaid channels: a voucher per request, `Voucher(bytes32 channelId,uint48 seq,uint96 amount,uint96 cumAmount,bytes32 inputCommitment,uint40 proveBy)`, and `settleBatch` with one proof for up to K vouchers. `BatchSettled` carries one result per lane only after the proof verified (core property 5). Example: one K=8 proof settling eight channels' vouchers costs 909,289 gas locally, 113,661 per request. A channel's windows have floors: prove window ≥ 60 s, challenge window ≥ 300 s. Clients SHOULD default to 10 minutes and 24 hours, long enough to fill and prove a batch, and to answer a close request through an outage. Its x402 wire format belongs to the `batch-settlement` composition and is not specified here.

## Security considerations

- **Replay.** The request id is the ERC-3009 nonce, which the token accepts once; the escrow flow also records the id. Two flows use two EIP-712 types, so an authorization signed for one cannot settle the other. Example: resubmitting a settled `settle` reverts in the token (nonce used); a second `open` of the same terms reverts with `AlreadyOpened`.
- **Authorization scope.** The signature fixes recipient, amount, asset, verifier, commitment and deadline. A relayer chooses only the proof and when to submit it.
- **Settlement atomicity.** Payment and published output are the same state transition.
- **Griefing.** Failed proofs revert and record nothing, so a third party cannot attach a failure to someone else's payment. Under-funding the verifier reverts rather than failing a valid proof.
- **The registry does not vouch for the verifying key.** `vkHash` is declared; the mapping from model to code is checked off-chain ([Model identity](./scheme_proof_gated.md#model-identity)).
- **Setup assumptions.** The reference circuits use a KZG reference string generated locally by one party: adequate for a testnet, not for value.
- **Unaudited.** The reference contracts are deployed on a testnet only and have not been audited.

## Reference implementation

Contracts from this repository's `src/`, on Base Sepolia (chain id 84532), deployed from a fresh account:

| Contract | Address |
|---|---|
| `VerifierRegistry` | `0xc754b4d635a1f4C67Bb09156aE078f648ae06cF1` |
| `Halo2EzklAdapter` | `0x070d8A6485ea5a813E949FeB57BCE9b2d35a64a5` |
| `SoloSettlement` | `0x0934cC0B3Fef6d8f9F8f87f40aFCfF59f668c729` |
| `ChannelSettlement` | `0x93e8E5745dB6eAb0eAC16FF2Dbfdd78A0C55c56B` |
| `AuthCaptureProofOperator` (escrow `0xf968…B19c`) | `0x039e3fFd1778bb91be2961b09999FDf58EcF68Ab` |

Registered: solo `0xc302c686…ff9b` (`verifyGas` 600,000) and K=8 `0xff34bcad…1107` (660,000). Measured on Base Sepolia with USDC: `settle` 766,226 gas; `open` + `release` 839,705; K=8 batch from one channel 860,315 (receipts in `measurements/2026-11-24-testnet/`). A TypeScript client and Python middleware are in `clients/`.

## Version History

| Version | Date | Changes | Authors |
|---|---|---|---|
| v0.1 | 2026-11-24 | Draft for discussion | @achemperety |
