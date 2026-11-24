# x402 v2: a proof-gated server and clients

A minimal resource server (Python) and clients (TypeScript) that speak x402 version 2 for one proof-gated inference, in two ways:

- **`proof-gated`** (working name for a scheme of our own): the payer signs one ERC-3009 authorization whose nonce is the request id of `SoloSettlement`, so the payment can only be released by a valid proof for the verifier and input commitment in the signed terms. Two flows: `authorization` (one transaction, `settle`) and `escrow` (`open` before the resource, `release` after it).
- **`auth-capture`** (x402's own scheme), with `AuthCaptureProofOperator` as a `"custom"` operator: the payment is held in x402's escrow and captured only with a valid proof. The payer uses x402's own client, unmodified.

Published-proof mode: the server serves the stored solo proof and can only sell the inference whose input commitment that proof carries. Nothing here proves, generates a witness or runs a model.

The reusable versions of this pair, a client package with the checks a payer makes before signing and server middleware with a `prove()` callback, are in `clients/` (`clients/ts/README.md`, `clients/python/README.md`). `client/conformance.ts` here checks the client package's wire types against x402's own.

## What is pinned

| | Version | Where |
|---|---|---|
| x402 TypeScript packages (`@x402/core`, `@x402/evm`) | `x402-foundation/x402` commit `3eb54b2984a955118845115b3fd5db4c926d0382` (2026-11-23) | fetched from source by `fetch_x402.sh` into `vendor/` (not tracked) |
| Their dependencies | `viem` 2.48.11, `zod` 4.6.7, `typescript` 5.9.2, `tsx` 4.21.0: the versions x402's own lockfile resolves at that commit | `package.json`, `package-lock.json` |
| x402's auth-capture escrow and ERC-3009 collector | `base/commerce-payments` v1.1.0, commit `6b0a5ef3f0df973857f558e2d6b5dd645b5e97f9` | submodule `lib/commerce-payments`, built from source with its own OpenZeppelin (v5.0.2) and solady |
| Server environment | Python 3.13, `web3` 7.14.0 | `server/requirements.txt` |

## Run it

```
npm --prefix x402 install
python3 -m venv x402/server/.venv && x402/server/.venv/bin/pip install -r x402/server/requirements.txt
npm --prefix x402 run typecheck
bash x402/run_e2e.sh
```

`run_e2e.sh` fetches x402's sources, builds the chain state (`script/X402LocalChain.s.sol`: the escrow and collector at the canonical v1.1 addresses, the test token at the testnet USDC address, the verifier registry, the EZKL adapter, the pinned solo verifier, `SoloSettlement` and the operator), starts a local node with chain id 84532, loads the state, starts the server and runs `client/e2e.ts`. The local node's published default accounts are used: 0 sends the server's transactions (the server holds no key), 1 pays, 2 is paid. With `X402_FAULTS=1` (which the script sets) the server can be asked to present a tampered proof, a verifier entry that is not the registered one, or an `auth-capture` offer whose `receiverAuthorizer` is not bound to its terms.

## The wire format

Headers are x402 v2's: `PAYMENT-REQUIRED` (402), `PAYMENT-SIGNATURE` (retry), `PAYMENT-RESPONSE` (answer), each base64 JSON. The resource is `POST /infer` with `{"inputCommitment": "0x…"}`.

### `PaymentRequired`

```json
{
  "x402Version": 2,
  "resource": { "url": "http://127.0.0.1:8402/infer", "description": "…", "mimeType": "application/json" },
  "accepts": [ { "scheme": "proof-gated", "...": "flow authorization" },
               { "scheme": "proof-gated", "...": "flow escrow" },
               { "scheme": "auth-capture", "...": "custom operator" } ],
  "extensions": {}
}
```

### `PaymentRequirements` for `proof-gated`

```json
{
  "scheme": "proof-gated",
  "network": "eip155:84532",
  "asset": "<USDC>",
  "amount": "1000000",
  "payTo": "<provider>",
  "maxTimeoutSeconds": 600,
  "extra": {
    "name": "USD Coin",
    "version": "2",
    "paymentFlow": "authorization",
    "settlement": "<SoloSettlement>",
    "verifierId": "0x…",
    "inputCommitmentFormat": "ezkl/poseidon/hashed-public/v1",
    "proveWindowSeconds": 600
  }
}
```

| `extra` field | Meaning |
|---|---|
| `name`, `version` | EIP-712 domain of the token, for the ERC-3009 signature |
| `paymentFlow` | `authorization` (verify, resource, then `settle` in one transaction) or `escrow` (`open` before the resource, `release` after) |
| `settlement` | The `SoloSettlement` contract; the authorization's `to` |
| `verifierId` | The registry entry whose circuit must produce the proof |
| `inputCommitmentFormat` | How the client commits to its input: EZKL's `hashed/public` input visibility, a Poseidon hash over the input and the circuit's nonce elements. The client computes the value and signs it in the terms |
| `proveWindowSeconds` | How far ahead the client sets `proveBy` |

### `PaymentPayload.payload` for `proof-gated`

```json
{
  "terms": { "payer": "…", "payTo": "…", "asset": "…", "amount": "1000000", "verifierId": "0x…",
             "inputCommitment": "0x…", "proveBy": 1795509622, "salt": "0x…" },
  "authorization": { "from": "…", "to": "<SoloSettlement>", "value": "1000000", "validAfter": "0",
                     "validBefore": "1795509622", "nonce": "<request id>" },
  "signature": "0x…"
}
```

The nonce is `SoloSettlement.paymentRequestId(terms)` for `authorization` and `escrowRequestId(terms)` for `escrow`: the ERC-712 struct hash of the terms with the chain id and the settlement contract (`client/proofGated.ts`, `requestId`).

### `auth-capture` with the proof operator

The offer is a standard `auth-capture` requirement with `operatorType: "custom"`, `captureAuthorizer` = the operator, `paymentFlow: "escrow"`, `captureMode: "deferred"`, zero fees, and `receiverAuthorizer = termsAuthorizer(verifierId, inputCommitment)`: an address derived from the terms, which nobody holds a key for. x402's client binds it into the payment's salt as the scheme prescribes, so the payer's signature commits to the terms. `extra` also carries `verifierId`, `inputCommitment` and `inputCommitmentFormat`, which an `auth-capture` client ignores; a proof-aware client checks that `receiverAuthorizer` is derived from them before signing (`client/e2e.ts`, `onBeforePaymentCreation`).

The server relays the collect call (`operator.authorize`) before the resource and captures with `operator.captureWithProof` after it. Lifecycle is out of band for a custom operator, so the server does it itself rather than through a facilitator.

### `SettleResponse` and the error reasons

```json
{ "success": true, "transaction": "0x…", "network": "eip155:84532", "payer": "…", "amount": "1000000",
  "extra": { "…": "escrow: the open transaction; auth-capture: the authorize transaction and the PaymentInfo" } }
```

| Failure | `errorReason` |
|---|---|
| The proof was checked and rejected (`ProofInvalid`) | `invalid_auth_capture_evm_proof_invalid` |
| The proof could not be checked: unknown verifier, an entry that is not the registered one, or code that is not the registered code (`VerifierUnavailable`) | `invalid_auth_capture_evm_verifier_unavailable` |
| `proveBy` passed (`Expired`) | `invalid_proof_gated_evm_expired` |
| Terms or authorization do not match the offer | `invalid_proof_gated_evm_terms_mismatch`, `…_nonce_mismatch`, `…_authorization_mismatch`, `…_prove_by` |
| The auth-capture salt is not bound to the terms | `invalid_auth_capture_evm_salt_binding_mismatch` (x402's own code) |

A failed check answers 402 with the failing `PAYMENT-RESPONSE` and no output. Every contract call is simulated first; a revert becomes an `errorReason` without a transaction.

## Validation against x402's definitions

Every `PaymentRequired`, `PaymentRequirements` and `PaymentPayload` the run produces or receives is parsed with x402's own zod schemas (`@x402/core/schemas`), and every value is typed with x402's TypeScript types, checked by `npm run typecheck`. x402 has no zod schema for `SettleResponse`; `client/x402Checks.ts` mirrors its TypeScript type, and the type-check fails if the two differ. x402's schemas are looser than its types (any string for `network`, `extra` optional), so both are applied.

## What the run shows (2026-11-24)

| Scenario | Result |
|---|---|
| `proof-gated`, authorization, real proof | 200; 1 USDC from payer to payTo; output delivered |
| `proof-gated`, escrow, real proof | 200; locked, then released |
| `proof-gated`, each flow, tampered proof | 402, `invalid_auth_capture_evm_proof_invalid`; nothing paid (escrow: stays locked, refundable after `proveBy`) |
| `proof-gated`, each flow, wrong entry | 402, `invalid_auth_capture_evm_verifier_unavailable`; nothing paid |
| `auth-capture`, x402's client, real proof | 200; held, then captured for payTo |
| `auth-capture`, offer not bound to its terms | the proof-aware check refuses to sign; nothing moves |
| `auth-capture`, wrong entry | 402, `invalid_auth_capture_evm_verifier_unavailable`; held, not captured |
| `auth-capture`, tampered proof | 402, `invalid_auth_capture_evm_proof_invalid`; held, not captured; after the capture deadline the payer reclaims it all |

Objects validated in one run: 10 `PaymentRequired`, 30 `PaymentRequirements`, 9 `PaymentPayload`, 9 `SettleResponse`. Peak memory: client 242 MB, server 74 MB, local node 30 MB.

## Limits

- No facilitator: the server settles directly. An x402 facilitator would relay the `auth-capture` collect call to the operator (it is the escrow's `authorize`, open to anyone); the `proof-gated` scheme has no facilitator implementation.
- x402's `auth-capture` client does not understand proof terms: it binds whatever `receiverAuthorizer` the server sends. Payment still needs a valid proof for the bound terms, but only a proof-aware client checks that those are the terms it was offered.
- `receiverAuthorizer` is 160 bits of a 256-bit hash. Finding two sets of terms with the same address takes about 2^80 work for a server that sees the input commitment before it names the verifier, and about 2^160 when the client adds fresh randomness to the commitment after that (`docs/spec-notes.md`). The published-proof run here serves one fixed input, so it has no such randomness.
