"""x402 version 2 server middleware for proof-gated inference.

    mw = ProofGatedMiddleware(w3=w3, sender=account, deployment=d, verifier_id=d["verifierIds"]["solo"],
                              price=10_000, pay_to=payee, prove=my_prover)
    status, body, headers = mw.handle(url, request_body, request_headers)

`handle` speaks x402 v2: without a `PAYMENT-SIGNATURE` header it answers 402 with `PAYMENT-REQUIRED`
(base64 JSON `PaymentRequired`); with one, it checks the payment, calls `prove(body)` and settles,
answering 200 with the output or 402, both with `PAYMENT-RESPONSE` (base64 JSON `SettleResponse`).
Offers, for the verifier this server proves with:

  * "proof-gated", paymentFlow "authorization": checks, prove, then `SoloSettlement.settle` pays
    against the proof in one transaction;
  * "proof-gated", paymentFlow "escrow": `open` locks the payment before proving, `release` pays
    against the proof after (the payer can `refund` after proveBy if no valid proof comes);
  * "auth-capture" (x402's scheme, `AuthCaptureProofOperator` as a custom operator), once the request
    names its input commitment: `authorize` holds the payment, `captureWithProof` takes it.

`prove(body)` returns `(input_commitment, output, proof)` as bytes. The commitment must be the one
the payer signed for; the middleware never settles a proof of anything else. A proof that fails and a
verifier that cannot be run become distinct `errorReason` values (docs/spec-notes.md, rule 2). Every
contract call is simulated first, so a failing proof costs no transaction.
"""
import base64, json, time

from eth_abi import encode as abi_encode
from eth_utils import keccak, to_checksum_address
from web3.exceptions import ContractCustomError, ContractLogicError

from .abi import OPERATOR_ABI, REGISTRY_ABI, SETTLEMENT_ABI, TOKEN_ABI

X402_VERSION = 2
USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
ESCROW = "0xf96815976523E00e65Be8f34cA5e64b4f41EB19c"
COLLECTOR = "0x8612dfdc421f80336cd14E8EF9cb1E765dB5ab88"
ZERO = "0x0000000000000000000000000000000000000000"
INPUT_COMMITMENT_FORMAT = "ezkl/poseidon/hashed-public/v1"
PROOF_TERMS_TYPEHASH = keccak(text="ProofGatedTerms(bytes32 verifierId,bytes32 inputCommitment)")
SALT_BINDING_TYPEHASH = keccak(text="x402AuthCaptureSaltBinding(address receiverAuthorizer,address policy,uint256 saltNonce)")

# Contract errors and the errorReason each becomes. The first two are the distinct pair, named as the
# specification names them (specs/schemes/proof-gated/auth_capture_policy_evm.md, "Status words").
ERROR_REASONS = {
    "ProofInvalid()": "invalid_auth_capture_evm_proof_invalid",
    "VerifierUnavailable(bytes32)": "invalid_auth_capture_evm_verifier_unavailable",
    "Expired()": "invalid_proof_gated_evm_expired",
    "AlreadyOpened(bytes32)": "invalid_proof_gated_evm_payment_already_used",
    "NotOpen(bytes32)": "invalid_proof_gated_evm_not_open",
    "TermsMismatch()": "invalid_proof_gated_evm_terms_mismatch",
    "TransferFailed()": "invalid_proof_gated_evm_transfer_failed",
    "InsufficientGasForVerifier(uint256,uint256)": "invalid_proof_gated_evm_insufficient_gas",
    "PartialAuthorization(uint256,uint256)": "invalid_auth_capture_evm_partial_authorization",
    "WrongOperator()": "invalid_auth_capture_evm_wrong_operator",
}
SELECTORS = {keccak(text=sig)[:4]: reason for sig, reason in ERROR_REASONS.items()}


def b64(obj):
    return base64.b64encode(json.dumps(obj, separators=(",", ":")).encode()).decode()


def unb64(value):
    return json.loads(base64.b64decode(value, validate=True))


def hexb(value):
    return bytes.fromhex(value[2:] if value.startswith("0x") else value)


def hex0x(b):
    return "0x" + bytes(b).hex()


def terms_authorizer(verifier_id, commitment):
    h = keccak(abi_encode(["bytes32", "bytes32", "bytes32"], [PROOF_TERMS_TYPEHASH, verifier_id, commitment]))
    return to_checksum_address(h[-20:])


def bound_salt(receiver_authorizer, salt_nonce):
    words = abi_encode(["bytes32", "address", "address", "uint256"], [SALT_BINDING_TYPEHASH, receiver_authorizer, ZERO, salt_nonce])
    return int.from_bytes(keccak(words), "big")


class Refused(Exception):
    """A payment this server will not take; the argument is the errorReason."""


class ProofGatedMiddleware:
    def __init__(self, *, w3, sender, deployment, verifier_id, price, pay_to, prove, network="eip155:84532",
                 prove_window=600, max_timeout=600, capture_window=3600, refund_window=86_400,
                 description="One proof-gated inference", token_domain=None):
        c = deployment["contracts"]
        self.w3, self.sender, self.prove = w3, sender, prove
        self.network, self.price, self.pay_to = network, int(price), to_checksum_address(pay_to)
        self.verifier_id = hexb(verifier_id) if isinstance(verifier_id, str) else verifier_id
        self.prove_window, self.max_timeout = prove_window, max_timeout
        self.capture_window, self.refund_window, self.description = capture_window, refund_window, description
        self.settlement = w3.eth.contract(address=to_checksum_address(c["SoloSettlement"]), abi=SETTLEMENT_ABI)
        self.operator = w3.eth.contract(address=to_checksum_address(c["AuthCaptureProofOperator"]), abi=OPERATOR_ABI)
        registry = w3.eth.contract(address=to_checksum_address(c["VerifierRegistry"]), abi=REGISTRY_ABI)
        e = registry.functions.entry(self.verifier_id).call()
        if int(e[0], 16) == 0:
            raise ValueError("verifier is not registered")
        self.entry = tuple(e)
        if token_domain is None:  # the token's ERC-712 domain, read from the token unless given
            token = w3.eth.contract(address=to_checksum_address(USDC), abi=TOKEN_ABI)
            token_domain = {"name": token.functions.name().call(), "version": token.functions.version().call()}
        self.token_domain = dict(token_domain)

    # ── Offers ──────────────────────────────────────────────────────────────────────────────────

    def entry_for(self, body):
        """The verifier entry presented with the proof; a test server may override it."""
        return self.entry

    def accepts(self, commitment_hex=None):
        now = int(time.time())
        base = {"network": self.network, "asset": USDC, "amount": str(self.price), "payTo": self.pay_to, "maxTimeoutSeconds": self.max_timeout}
        pg = {**self.token_domain, "settlement": self.settlement.address, "verifierId": hex0x(self.verifier_id),
              "inputCommitmentFormat": INPUT_COMMITMENT_FORMAT, "proveWindowSeconds": self.prove_window}
        offers = [
            {"scheme": "proof-gated", **base, "extra": {**pg, "paymentFlow": "authorization"}},
            {"scheme": "proof-gated", **base, "extra": {**pg, "paymentFlow": "escrow"}},
        ]
        if commitment_hex:
            offers.append({"scheme": "auth-capture", **base, "extra": {
                **self.token_domain, "authCaptureEscrow": ESCROW, "captureAuthorizer": self.operator.address,
                "operatorType": "custom", "receiverAuthorizer": self.receiver_authorizer(hexb(commitment_hex)),
                "policy": ZERO, "paymentFlow": "escrow", "captureMode": "deferred",
                "captureDeadline": now + self.capture_window, "refundDeadline": now + self.refund_window,
                "minFeeBps": 0, "maxFeeBps": 0, "feeRecipient": ZERO, "assetTransferMethod": "eip3009",
                "verifierId": hex0x(self.verifier_id), "inputCommitment": commitment_hex,
                "inputCommitmentFormat": INPUT_COMMITMENT_FORMAT,
            }})
        return offers

    def receiver_authorizer(self, commitment):
        return terms_authorizer(self.verifier_id, commitment)

    def payment_required(self, url, commitment_hex=None, error=None):
        pr = {"x402Version": X402_VERSION, "resource": {"url": url, "description": self.description, "mimeType": "application/json"},
              "accepts": self.accepts(commitment_hex), "extensions": {}}
        if error:
            pr["error"] = error
        return pr

    # ── Requests ────────────────────────────────────────────────────────────────────────────────

    def handle(self, url, body, headers):
        """Answer one request: returns (status, JSON body, headers)."""
        commitment_hex = body.get("inputCommitment")
        header = {k.lower(): v for k, v in headers.items()}.get("payment-signature")
        if not header:
            pr = self.payment_required(url, commitment_hex)
            return 402, pr, {"PAYMENT-REQUIRED": b64(pr)}
        try:
            payload = unb64(header)
        except Exception:
            return 400, {"error": "PAYMENT-SIGNATURE is not base64 JSON"}, {}
        acc = payload.get("accepted", {})
        try:
            if payload.get("x402Version") != X402_VERSION or acc.get("network") != self.network:
                raise Refused("invalid_x402_version_or_network")
            if acc.get("scheme") == "proof-gated":
                return self.proof_gated(payload, body)
            if acc.get("scheme") == "auth-capture":
                return self.auth_capture(payload, body, commitment_hex)
            raise Refused("unsupported_scheme")
        except Refused as r:
            return self.settled(False, "", self.payer_of(payload), str(r))

    def settled(self, ok, tx, payer, reason=None, extra=None, output=None):
        resp = {"success": ok, "transaction": tx or "", "network": self.network}
        if payer:
            resp["payer"] = payer
        if ok:
            resp["amount"] = str(self.price)
        if reason:
            resp["errorReason"] = reason
        if extra:
            resp["extra"] = extra
        body = {"output": hex0x(output)} if ok else {"error": reason}
        return (200 if ok else 402), body, {"PAYMENT-RESPONSE": b64(resp)}

    @staticmethod
    def payer_of(payload):
        p = payload.get("payload", {})
        return p.get("terms", {}).get("payer") or p.get("authorization", {}).get("from")

    def proven(self, body, commitment):
        """Run the prover; refuse a proof of another input than the payer committed to."""
        got_commitment, output, proof = self.prove(body)
        if bytes(got_commitment) != bytes(commitment):
            raise Refused("invalid_proof_gated_evm_prover_commitment_mismatch")
        return output, proof

    def send(self, fn):
        """Simulate, then send. A revert becomes an errorReason without a transaction."""
        frm = self.sender if isinstance(self.sender, str) else self.sender.address
        try:
            fn.call({"from": frm})
        except (ContractCustomError, ContractLogicError) as exc:
            data = getattr(exc, "data", None) or (exc.args[1] if len(exc.args) > 1 else None)
            raw = hexb(data) if isinstance(data, str) and data.startswith("0x") else b""
            raise Refused(SELECTORS.get(raw[:4], "invalid_proof_gated_evm_simulation_failed"))
        if isinstance(self.sender, str):  # an account the node signs for
            tx_hash = fn.transact({"from": self.sender})
        else:  # a local key
            tx = fn.build_transaction({"from": frm, "nonce": self.w3.eth.get_transaction_count(frm, "pending")})
            tx_hash = self.w3.eth.send_raw_transaction(self.sender.sign_transaction(tx).raw_transaction)
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)
        if receipt.status != 1:
            raise Refused("invalid_proof_gated_evm_transaction_reverted")
        return receipt.transactionHash.to_0x_hex()

    def proof_gated(self, payload, body):
        acc, p = payload["accepted"], payload["payload"]
        t, auth = p["terms"], p["authorization"]
        flow = acc.get("extra", {}).get("paymentFlow")
        if flow not in ("authorization", "escrow"):
            raise Refused("invalid_proof_gated_evm_unsupported_payment_flow")
        if (int(t["amount"]) != self.price or t["asset"].lower() != USDC.lower() or t["payTo"].lower() != self.pay_to.lower()
                or hexb(t["verifierId"]) != self.verifier_id or not body.get("inputCommitment")
                or hexb(t["inputCommitment"]) != hexb(body["inputCommitment"])):
            raise Refused("invalid_proof_gated_evm_terms_mismatch")
        now = int(time.time())
        if not now < int(t["proveBy"]) <= now + self.prove_window + self.max_timeout:
            raise Refused("invalid_proof_gated_evm_prove_by")
        terms = (to_checksum_address(t["payer"]), self.pay_to, to_checksum_address(USDC), self.price, self.verifier_id,
                 hexb(t["inputCommitment"]), int(t["proveBy"]), hexb(t["salt"]))
        fn_id = self.settlement.functions.paymentRequestId if flow == "authorization" else self.settlement.functions.escrowRequestId
        if fn_id(terms).call() != hexb(auth["nonce"]):
            raise Refused("invalid_proof_gated_evm_nonce_mismatch")
        if to_checksum_address(auth["to"]) != self.settlement.address or int(auth["value"]) != self.price:
            raise Refused("invalid_proof_gated_evm_authorization_mismatch")
        sig, valid_before, payer = hexb(p["signature"]), int(auth["validBefore"]), t["payer"]
        if flow == "authorization":  # check, prove, then pay against the proof in one transaction
            output, proof = self.proven(body, terms[5])
            tx = self.send(self.settlement.functions.settle(terms, self.entry_for(body), valid_before, sig, output, proof))
            return self.settled(True, tx, payer, output=output)
        opened = self.send(self.settlement.functions.open(terms, valid_before, sig))  # lock before proving
        try:
            output, proof = self.proven(body, terms[5])
            tx = self.send(self.settlement.functions.release(terms, self.entry_for(body), output, proof))
        except Refused as r:
            return self.settled(False, "", payer, str(r), {"open": opened, "refundAfter": int(t["proveBy"])})
        return self.settled(True, tx, payer, extra={"open": opened}, output=output)

    def auth_capture(self, payload, body, commitment_hex):
        acc, p = payload["accepted"], payload["payload"]
        ex, auth = acc.get("extra", {}), p.get("authorization", {})
        if not commitment_hex:
            raise Refused("invalid_auth_capture_evm_no_input_commitment")
        commitment = hexb(commitment_hex)
        if (ex.get("operatorType") != "custom" or to_checksum_address(ex.get("captureAuthorizer", ZERO)) != self.operator.address
                or to_checksum_address(ex.get("receiverAuthorizer", ZERO)) != self.receiver_authorizer(commitment)
                or int(acc.get("amount", -1)) != self.price or to_checksum_address(acc.get("payTo", ZERO)) != self.pay_to):
            raise Refused("invalid_auth_capture_evm_extra")
        if "saltNonce" not in p:
            raise Refused("invalid_auth_capture_evm_payload_format")
        salt_nonce = int(p["saltNonce"], 16)
        if bound_salt(self.receiver_authorizer(commitment), salt_nonce) != int(p["salt"], 16):
            raise Refused("invalid_auth_capture_evm_salt_binding_mismatch")
        info = (self.operator.address, to_checksum_address(auth["from"]), self.pay_to, to_checksum_address(USDC), self.price,
                int(auth["validBefore"]), int(ex["captureDeadline"]), int(ex["refundDeadline"]), int(ex["minFeeBps"]),
                int(ex["maxFeeBps"]), to_checksum_address(ex["feeRecipient"]), int(p["salt"], 16))
        held = self.send(self.operator.functions.authorize(info, self.price, to_checksum_address(COLLECTOR), hexb(p["signature"])))
        extra = {"authorize": held, "paymentInfo": dict(zip(
            ["operator", "payer", "receiver", "token", "maxAmount", "preApprovalExpiry", "authorizationExpiry",
             "refundExpiry", "minFeeBps", "maxFeeBps", "feeReceiver", "salt"], [str(v) for v in info]))}
        try:
            output, proof = self.proven(body, commitment)
            tx = self.send(self.operator.functions.captureWithProof(info, (self.verifier_id, commitment, salt_nonce), self.entry_for(body), output, proof))
        except Refused as r:
            return self.settled(False, "", auth.get("from"), str(r), {**extra, "reclaimFrom": int(ex["captureDeadline"])})
        return self.settled(True, tx, auth.get("from"), extra=extra, output=output)
