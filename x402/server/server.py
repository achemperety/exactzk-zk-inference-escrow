#!/usr/bin/env python3
"""A minimal x402 v2 resource server for one proof-gated inference, in published-proof mode.

    python server.py <state dir> [--port 8402] [--rpc http://127.0.0.1:8545]
    python server.py <state dir> --emit-402 <inputCommitment>    # print one PAYMENT-REQUIRED header

The resource is `POST /infer` with a JSON body `{"inputCommitment": "0x…"}`. Published-proof mode: the
server serves the stored proof (x402/.state/deployment.json), so it can only sell the inference whose
input commitment that proof carries; no proving happens here.

Without a `PAYMENT-SIGNATURE` header the answer is 402 with a `PAYMENT-REQUIRED` header (base64 JSON
of x402's `PaymentRequired`, `x402Version: 2`) offering three ways to pay:

  1. scheme "proof-gated", paymentFlow "authorization": `SoloSettlement.settle` checks the proof,
     pulls the payment and pays `payTo` in one transaction, after the resource is produced.
  2. scheme "proof-gated", paymentFlow "escrow": `SoloSettlement.open` locks the payment before the
     resource, `release` pays it against the proof after.
  3. scheme "auth-capture" (x402's own), operatorType "custom", paymentFlow "escrow": the payment is
     held in x402's escrow through `AuthCaptureProofOperator.authorize`, and captured with
     `captureWithProof` after the resource. The terms are bound through `extra.receiverAuthorizer`,
     so x402's unmodified client pays it.

The answer to a paid request is 200 with a `PAYMENT-RESPONSE` header (base64 JSON of x402's
`SettleResponse`), or 402 with a failing one. A proof that does not verify and a verifier that cannot
be run map to two distinct `errorReason` values (docs/spec-notes.md, rule 2).

Transactions are sent from the local node's first unlocked default account; the server holds no key.
With X402_FAULTS=1 a request may ask the server to present a tampered proof (`"serve": "tampered"`) or
an entry that is not the registered one (`"serve": "wrong-entry"`), to show the two failures.
"""
import base64, json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from eth_abi import decode as abi_decode, encode as abi_encode
from eth_utils import keccak, to_checksum_address
from web3 import Web3
from web3.exceptions import ContractCustomError, ContractLogicError

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
X402_VERSION = 2
NETWORK = "eip155:84532"
AMOUNT = "1000000"  # 1 USDC
MAX_TIMEOUT = 600  # seconds a client may take to sign and send
PROVE_WINDOW = 600  # seconds a proof-gated payment stays open
CAPTURE_WINDOW = 3600  # seconds an auth-capture hold may wait for a proof
REFUND_WINDOW = 86_400
INPUT_COMMITMENT_FORMAT = "ezkl/poseidon/hashed-public/v1"
ZERO = "0x0000000000000000000000000000000000000000"

SALT_BINDING_TYPEHASH = keccak(text="x402AuthCaptureSaltBinding(address receiverAuthorizer,address policy,uint256 saltNonce)")
PROOF_TERMS_TYPEHASH = keccak(text="ProofGatedTerms(bytes32 verifierId,bytes32 inputCommitment)")

# Contract errors and the x402 `errorReason` each becomes. The first two are the distinct pair the
# x402 discussion agreed on: the proof was checked and rejected, or it could not be checked. Their
# names are the specification's (specs/schemes/proof-gated/auth_capture_policy_evm.md, "Status words").
ERROR_REASONS = {
    "ProofInvalid()": "invalid_auth_capture_evm_proof_invalid",
    "VerifierUnavailable(bytes32)": "invalid_auth_capture_evm_verifier_unavailable",
    "Expired()": "invalid_proof_gated_evm_expired",
    "AlreadyOpened(bytes32)": "invalid_proof_gated_evm_payment_already_used",
    "NotOpen(bytes32)": "invalid_proof_gated_evm_not_open",
    "TermsMismatch()": "invalid_proof_gated_evm_terms_mismatch",
    "TransferFailed()": "invalid_proof_gated_evm_transfer_failed",
    "InsufficientGasForVerifier(uint256,uint256)": "invalid_proof_gated_evm_insufficient_gas",
}
SELECTORS = {keccak(text=sig)[:4]: reason for sig, reason in ERROR_REASONS.items()}


def b64(obj):
    return base64.b64encode(json.dumps(obj, separators=(",", ":")).encode()).decode()


def unb64(value):
    return json.loads(base64.b64decode(value, validate=True))


def artifact(name):
    return json.load(open(os.path.join(ROOT, "out", f"{name}.sol", f"{name}.json")))["abi"]


def terms_authorizer(verifier_id, commitment):
    h = keccak(abi_encode(["bytes32", "bytes32", "bytes32"], [PROOF_TERMS_TYPEHASH, verifier_id, commitment]))
    return to_checksum_address(h[-20:])


def bound_salt(verifier_id, commitment, salt_nonce):
    words = abi_encode(
        ["bytes32", "address", "address", "uint256"],
        [SALT_BINDING_TYPEHASH, terms_authorizer(verifier_id, commitment), ZERO, salt_nonce],
    )
    return int.from_bytes(keccak(words), "big")


def hexb(value):
    return bytes.fromhex(value[2:] if value.startswith("0x") else value)


class Chain:
    """The deployment of script/X402LocalChain.s.sol, and the calls the server makes."""

    def __init__(self, state_dir, rpc):
        d = json.load(open(os.path.join(state_dir, "deployment.json")))
        self.d = d
        self.w3 = Web3(Web3.HTTPProvider(rpc)) if rpc else None
        self.verifier_id = hexb(d["verifierId"])
        self.commitment = hexb(d["inputCommitment"])
        self.output = hexb(d["output"])
        self.proof = hexb(d["proof"])
        e = abi_decode(["(address,uint32,uint32,uint32,address,bytes32,bytes32,bytes32,bytes32)"], hexb(d["entry"]))[0]
        self.entry = (to_checksum_address(e[0]), e[1], e[2], e[3], to_checksum_address(e[4])) + tuple(e[5:])
        if self.w3:
            self.sender = self.w3.eth.accounts[0]
            self.settlement = self.w3.eth.contract(address=to_checksum_address(d["settlement"]), abi=artifact("SoloSettlement"))
            self.operator = self.w3.eth.contract(
                address=to_checksum_address(d["operator"]), abi=artifact("AuthCaptureProofOperator")
            )

    # ── What the server offers ──────────────────────────────────────────────────────────────────

    def accepts(self, commitment_hex, serve=None):
        d, now = self.d, int(time.time())
        token_domain = {"name": "USD Coin", "version": "2"}
        base = {"network": NETWORK, "asset": d["token"], "amount": AMOUNT, "payTo": d["payTo"], "maxTimeoutSeconds": MAX_TIMEOUT}
        proof_gated = {
            **token_domain,
            "settlement": d["settlement"],
            "verifierId": d["verifierId"],
            "inputCommitmentFormat": INPUT_COMMITMENT_FORMAT,
            "proveWindowSeconds": PROVE_WINDOW,
        }
        return [
            {"scheme": "proof-gated", **base, "extra": {**proof_gated, "paymentFlow": "authorization"}},
            {"scheme": "proof-gated", **base, "extra": {**proof_gated, "paymentFlow": "escrow"}},
            {
                "scheme": "auth-capture",
                **base,
                "extra": {
                    **token_domain,
                    "authCaptureEscrow": d["escrow"],
                    "captureAuthorizer": d["operator"],
                    "operatorType": "custom",
                    "receiverAuthorizer": (
                        terms_authorizer(self.verifier_id, hexb(commitment_hex))
                        if not (serve == "unbound-authorizer" and os.environ.get("X402_FAULTS") == "1")
                        else to_checksum_address("0x" + "11" * 20)
                    ),
                    "policy": ZERO,
                    "paymentFlow": "escrow",
                    "captureMode": "deferred",
                    "captureDeadline": now + CAPTURE_WINDOW,
                    "refundDeadline": now + REFUND_WINDOW,
                    "minFeeBps": 0,
                    "maxFeeBps": 0,
                    "feeRecipient": ZERO,
                    "assetTransferMethod": "eip3009",
                    # Not read by an auth-capture client; a proof-aware client checks that
                    # receiverAuthorizer is derived from them before it signs.
                    "verifierId": d["verifierId"],
                    "inputCommitment": commitment_hex,
                    "inputCommitmentFormat": INPUT_COMMITMENT_FORMAT,
                },
            },
        ]

    def payment_required(self, url, commitment_hex, error=None, serve=None):
        pr = {
            "x402Version": X402_VERSION,
            "resource": {"url": url, "description": "One inference of the pinned solo circuit, paid against its proof", "mimeType": "application/json"},
            "accepts": self.accepts(commitment_hex, serve),
            "extensions": {},
        }
        if error:
            pr["error"] = error
        return pr

    # ── Contract calls ──────────────────────────────────────────────────────────────────────────

    def send(self, fn):
        """Simulate, then send; a revert is mapped to an x402 errorReason without a transaction."""
        try:
            fn.call({"from": self.sender})
        except (ContractCustomError, ContractLogicError) as exc:
            data = getattr(exc, "data", None) or (exc.args[1] if len(exc.args) > 1 else None)
            raw = hexb(data) if isinstance(data, str) and data.startswith("0x") else b""
            return None, SELECTORS.get(raw[:4], "invalid_proof_gated_evm_simulation_failed")
        tx = fn.transact({"from": self.sender, "gas": 2_000_000})
        receipt = self.w3.eth.wait_for_transaction_receipt(tx)
        if receipt.status != 1:
            return None, "invalid_proof_gated_evm_transaction_reverted"
        return receipt, None

    def presented(self, serve):
        """The proof and entry the server presents; faults only when allowed."""
        proof, entry = self.proof, self.entry
        if serve and os.environ.get("X402_FAULTS") == "1":
            if serve == "tampered":
                proof = proof[:100] + bytes([proof[100] ^ 1]) + proof[101:]
            elif serve == "wrong-entry":
                entry = entry[:3] + (entry[3] + 1,) + entry[4:]
        return proof, entry


def terms_tuple(t):
    return (
        to_checksum_address(t["payer"]), to_checksum_address(t["payTo"]), to_checksum_address(t["asset"]),
        int(t["amount"]), hexb(t["verifierId"]), hexb(t["inputCommitment"]), int(t["proveBy"]), hexb(t["salt"]),
    )


def payment_info(p):
    return (
        to_checksum_address(p["operator"]), to_checksum_address(p["payer"]), to_checksum_address(p["receiver"]),
        to_checksum_address(p["token"]), int(p["maxAmount"]), int(p["preApprovalExpiry"]),
        int(p["authorizationExpiry"]), int(p["refundExpiry"]), int(p["minFeeBps"]), int(p["maxFeeBps"]),
        to_checksum_address(p["feeReceiver"]), int(p["salt"], 16) if isinstance(p["salt"], str) else int(p["salt"]),
    )


class Handler(BaseHTTPRequestHandler):
    chain: Chain = None

    def log_message(self, fmt, *args):
        sys.stderr.write("server: " + (fmt % args) + "\n")

    def reply(self, status, body, headers=None):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Expose-Headers", "PAYMENT-REQUIRED, PAYMENT-RESPONSE")
        self.send_header("Cache-Control", "no-store")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def settle_reply(self, ok, tx, payer, reason=None, extra=None, body=None):
        resp = {"success": ok, "transaction": tx or "", "network": NETWORK, "payer": payer}
        if ok:
            resp["amount"] = AMOUNT
        if reason:
            resp["errorReason"] = reason
        if extra:
            resp["extra"] = extra
        self.reply(200 if ok else 402, body or {"error": reason}, {"PAYMENT-RESPONSE": b64(resp)})

    def do_POST(self):
        try:
            self.handle_post()
        except Exception as exc:  # an answer, not a dropped connection
            self.log_message("error: %r", exc)
            self.reply(500, {"error": "server error"})

    def handle_post(self):
        c = self.chain
        if self.path != "/infer":
            return self.reply(404, {"error": "not found"})
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0) or b"{}")
        commitment_hex = req.get("inputCommitment", "")
        url = f"http://{self.headers.get('Host')}/infer"
        if commitment_hex.lower() != c.d["inputCommitment"].lower():
            return self.reply(422, {"error": "published-proof mode: only the stored proof's input commitment can be served"})
        header = self.headers.get("PAYMENT-SIGNATURE")
        if not header:
            pr = c.payment_required(url, commitment_hex, serve=req.get("serve"))
            return self.reply(402, pr, {"PAYMENT-REQUIRED": b64(pr)})
        try:
            payload = unb64(header)
        except Exception:
            return self.reply(400, {"error": "PAYMENT-SIGNATURE is not base64 JSON"})
        acc = payload.get("accepted", {})
        if payload.get("x402Version") != X402_VERSION or acc.get("network") != NETWORK:
            return self.settle_reply(False, "", None, "invalid_x402_version_or_network")
        if acc.get("scheme") == "proof-gated":
            return self.proof_gated(payload, req.get("serve"))
        if acc.get("scheme") == "auth-capture":
            return self.auth_capture(payload, commitment_hex, req.get("serve"))
        return self.settle_reply(False, "", None, "unsupported_scheme")

    # ── proof-gated ─────────────────────────────────────────────────────────────────────────────

    def proof_gated(self, payload, serve):
        c, acc, p = self.chain, payload["accepted"], payload["payload"]
        t, auth = p["terms"], p["authorization"]
        offered = {a["extra"]["paymentFlow"]: a for a in c.accepts(c.d["inputCommitment"]) if a["scheme"] == "proof-gated"}
        flow = acc.get("extra", {}).get("paymentFlow")
        mine = offered.get(flow)
        payer = t.get("payer")
        if mine is None:
            return self.settle_reply(False, "", payer, "invalid_proof_gated_evm_unsupported_payment_flow")
        for field in ("asset", "amount", "payTo"):
            if str(t[field]).lower() != str(mine[field]).lower():
                return self.settle_reply(False, "", payer, "invalid_proof_gated_evm_terms_mismatch")
        if t["verifierId"].lower() != c.d["verifierId"].lower() or t["inputCommitment"].lower() != c.d["inputCommitment"].lower():
            return self.settle_reply(False, "", payer, "invalid_proof_gated_evm_terms_mismatch")
        now = int(time.time())
        if not now < int(t["proveBy"]) <= now + PROVE_WINDOW + MAX_TIMEOUT:
            return self.settle_reply(False, "", payer, "invalid_proof_gated_evm_prove_by")
        terms = terms_tuple(t)
        fn_id = c.settlement.functions.paymentRequestId if flow == "authorization" else c.settlement.functions.escrowRequestId
        if fn_id(terms).call().hex() != auth["nonce"].lower().removeprefix("0x"):
            return self.settle_reply(False, "", payer, "invalid_proof_gated_evm_nonce_mismatch")
        if to_checksum_address(auth["to"]) != c.settlement.address or int(auth["value"]) != int(t["amount"]):
            return self.settle_reply(False, "", payer, "invalid_proof_gated_evm_authorization_mismatch")
        sig, valid_before = hexb(p["signature"]), int(auth["validBefore"])
        proof, entry = c.presented(serve)
        if flow == "authorization":
            # verify -> resource -> settle: the output exists before the payment moves, and the
            # payment moves only with its proof.
            receipt, reason = c.send(c.settlement.functions.settle(terms, entry, valid_before, sig, c.output, proof))
            if reason:
                return self.settle_reply(False, "", payer, reason)
            return self.settle_reply(True, receipt.transactionHash.to_0x_hex(), payer, body={"output": "0x" + c.output.hex()})
        # escrow: open before the resource, release after it.
        opened, reason = c.send(c.settlement.functions.open(terms, valid_before, sig))
        if reason:
            return self.settle_reply(False, "", payer, reason)
        released, reason = c.send(c.settlement.functions.release(terms, entry, c.output, proof))
        if reason:
            extra = {"open": opened.transactionHash.to_0x_hex(), "refundAfter": int(t["proveBy"])}
            return self.settle_reply(False, "", payer, reason, extra)
        return self.settle_reply(
            True, released.transactionHash.to_0x_hex(), payer, extra={"open": opened.transactionHash.to_0x_hex()},
            body={"output": "0x" + c.output.hex()},
        )

    # ── auth-capture with the proof operator ────────────────────────────────────────────────────

    def auth_capture(self, payload, commitment_hex, serve):
        c, acc, p = self.chain, payload["accepted"], payload["payload"]
        ex = acc.get("extra", {})
        auth = p.get("authorization", {})
        payer = auth.get("from")
        expected = terms_authorizer(c.verifier_id, hexb(commitment_hex))
        if (
            ex.get("operatorType") != "custom"
            or to_checksum_address(ex.get("captureAuthorizer", ZERO)) != c.operator.address
            or to_checksum_address(ex.get("receiverAuthorizer", ZERO)) != expected
            or acc.get("amount") != AMOUNT
            or to_checksum_address(acc.get("payTo")) != to_checksum_address(c.d["payTo"])
        ):
            return self.settle_reply(False, "", payer, "invalid_auth_capture_evm_extra")
        if "saltNonce" not in p:
            return self.settle_reply(False, "", payer, "invalid_auth_capture_evm_payload_format")
        salt_nonce = int(p["saltNonce"], 16)
        if bound_salt(c.verifier_id, hexb(commitment_hex), salt_nonce) != int(p["salt"], 16):
            return self.settle_reply(False, "", payer, "invalid_auth_capture_evm_salt_binding_mismatch")
        info = payment_info({
            "operator": ex["captureAuthorizer"], "payer": payer, "receiver": acc["payTo"], "token": acc["asset"],
            "maxAmount": acc["amount"], "preApprovalExpiry": auth["validBefore"],
            "authorizationExpiry": ex["captureDeadline"], "refundExpiry": ex["refundDeadline"],
            "minFeeBps": ex["minFeeBps"], "maxFeeBps": ex["maxFeeBps"], "feeReceiver": ex["feeRecipient"],
            "salt": p["salt"],
        })
        # Collect: the hold, before the resource.
        held, reason = c.send(c.operator.functions.authorize(info, int(acc["amount"]), to_checksum_address(c.d["collector"]), hexb(p["signature"])))
        if reason:
            return self.settle_reply(False, "", payer, reason)
        # Lifecycle, out of band for a custom operator: capture against the proof.
        proof, entry = c.presented(serve)
        terms = (c.verifier_id, hexb(commitment_hex), salt_nonce)
        captured, reason = c.send(c.operator.functions.captureWithProof(info, terms, entry, c.output, proof))
        # The settle result is the capture's; the hold's transaction and the PaymentInfo (which the
        # payer needs to reclaim an uncaptured hold) go in `extra`.
        extra = {
            "authorize": held.transactionHash.to_0x_hex(),
            "paymentInfo": dict(zip(
                ["operator", "payer", "receiver", "token", "maxAmount", "preApprovalExpiry", "authorizationExpiry",
                 "refundExpiry", "minFeeBps", "maxFeeBps", "feeReceiver", "salt"], [str(v) for v in info])),
        }
        if captured:
            return self.settle_reply(True, captured.transactionHash.to_0x_hex(), payer, extra=extra, body={"output": "0x" + c.output.hex()})
        extra["reclaimFrom"] = int(ex["captureDeadline"])
        return self.settle_reply(False, "", payer, reason, extra)


def main():
    args = sys.argv[1:]
    state_dir = args[0]
    if "--emit-402" in args:
        chain = Chain(state_dir, None)
        commitment = args[args.index("--emit-402") + 1]
        print(b64(chain.payment_required("http://127.0.0.1:8402/infer", commitment)))
        return
    port = int(args[args.index("--port") + 1]) if "--port" in args else 8402
    rpc = args[args.index("--rpc") + 1] if "--rpc" in args else "http://127.0.0.1:8545"
    Handler.chain = Chain(state_dir, rpc)
    print(f"server: listening on 127.0.0.1:{port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
