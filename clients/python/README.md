# Server middleware: selling proof-gated inference over x402

Python 3.10 or later, `web3` 7.14 (`requirements.txt`). The package is `exactzk_x402`; the core is framework-independent (`ProofGatedMiddleware.handle`), with a standard-library server and a WSGI application on top.

```python
from web3 import Web3
from exactzk_x402 import ProofGatedMiddleware, serve

d = json.load(open("deployments/base-sepolia.json"))
w3 = Web3(Web3.HTTPProvider("https://sepolia.base.org"))
mw = ProofGatedMiddleware(
    w3=w3,
    sender=w3.eth.account.from_key(os.environ["SERVER_KEY"]),  # pays gas; or an address the node signs for
    deployment=d,
    verifier_id=d["verifierIds"]["solo"],  # the registered entry this server proves with
    price=10_000,                          # USDC units (6 decimals)
    pay_to="0x…",                          # where the payments go
    prove=my_prover,                       # body -> (input_commitment, output, proof), all bytes
)
serve(mw, port=8402)                       # POST /infer on 127.0.0.1; or wsgi_app(mw) for any WSGI server
```

Published-proof mode, which serves the one stored proof and needs no prover, is `python -m exactzk_x402 --rpc … --deployment … --proof clients/ts/published/solo-proof.json --price … --pay-to … --key-env NAME`.

## What it does

Without a `PAYMENT-SIGNATURE` header, a request gets 402 with `PAYMENT-REQUIRED`: base64 JSON of x402's `PaymentRequired`, offering `proof-gated` in both flows and, once the request names its input commitment, `auth-capture` with `receiverAuthorizer` derived from the terms. With one, the middleware checks the payment against its own offer, then:

| Offer | Before proving | After proving |
|---|---|---|
| `proof-gated`, `authorization` | checks terms, request id and authorization | `SoloSettlement.settle`: the proof and the payment in one transaction |
| `proof-gated`, `escrow` | `SoloSettlement.open` locks the payment | `release` pays it against the proof; otherwise the payer can `refund` after `proveBy` |
| `auth-capture` | checks the bound salt; `AuthCaptureProofOperator.authorize` holds the payment | `captureWithProof`; otherwise the payer reclaims after the capture deadline |

`prove(body)` must return the commitment the proof is about. The middleware refuses to settle a proof of any other input than the one the payer signed for (`invalid_proof_gated_evm_prover_commitment_mismatch`). Every contract call is simulated first, so a payment that would fail costs no transaction. The answer is 200 with `{"output": …}`, or 402, each with `PAYMENT-RESPONSE`: base64 JSON of x402's `SettleResponse`.

## errorReason values

| Contract error | `errorReason` |
|---|---|
| `ProofInvalid()`: the proof was checked and rejected | `invalid_proof_gated_evm_invalid_proof` |
| `VerifierUnavailable(bytes32)`: unknown verifier, an entry that is not the registered one, or code that is not the registered code | `invalid_proof_gated_evm_verifier_unavailable` |
| `Expired()`, `AlreadyOpened`, `NotOpen`, `TermsMismatch()`, `TransferFailed()`, `InsufficientGasForVerifier` | `invalid_proof_gated_evm_expired`, `…_payment_already_used`, `…_not_open`, `…_terms_mismatch`, `…_transfer_failed`, `…_insufficient_gas` |
| Checks before any call | `invalid_proof_gated_evm_terms_mismatch`, `…_nonce_mismatch`, `…_authorization_mismatch`, `…_prove_by`, `…_prover_commitment_mismatch`, `invalid_auth_capture_evm_extra`, `…_salt_binding_mismatch` |

The first two are the distinct pair the specification requires (`docs/spec-notes.md`, rule 2). The names follow x402's `invalid_<scheme>_evm_*` convention, with "proof-gated" as the scheme's working name.

Tested end to end with the TypeScript client in `clients/e2e/run.sh`; see `clients/ts/README.md`.
