#!/usr/bin/env python3
"""The middleware on the local chain of script/X402LocalChain.s.sol, for clients/e2e/run.sh.

A request body may ask this test server to misbehave, to show what the client and the contracts do:
"serve": "tampered" (a proof with one byte changed), "wrong-entry" (an entry that is not the
registered one), "unbound-authorizer" (an auth-capture offer whose receiverAuthorizer is not derived
from the terms), "switch-verifier" (an offer that names another verifier once the commitment is known), "lie-output"
(an answer whose body claims another output than the chain recorded), "other-commitment" (a prover
that returns a proof about another input).
"""
import json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "clients", "python"))

from web3 import Web3  # noqa: E402

from exactzk_x402 import ProofGatedMiddleware, published_prover, serve, terms_authorizer  # noqa: E402

OTHER_VERIFIER = "0x" + "ab" * 32


class TestServer(ProofGatedMiddleware):
    mode = None

    def handle(self, url, body, headers):
        self.mode = body.get("serve")
        return super().handle(url, body, headers)

    def receiver_authorizer(self, commitment):
        if self.mode == "unbound-authorizer":
            return Web3.to_checksum_address("0x" + "11" * 20)
        return super().receiver_authorizer(commitment)

    def accepts(self, commitment_hex=None):
        offers = super().accepts(commitment_hex)
        if self.mode == "switch-verifier" and commitment_hex:
            for o in offers:  # consistent with itself, so that only the change of verifier is wrong
                o["extra"]["verifierId"] = OTHER_VERIFIER
                if o["scheme"] == "auth-capture":
                    o["extra"]["receiverAuthorizer"] = terms_authorizer(bytes.fromhex(OTHER_VERIFIER[2:]), bytes.fromhex(commitment_hex[2:]))
        return offers

    def settled(self, ok, tx, payer, reason=None, extra=None, output=None):
        status, body, headers = super().settled(ok, tx, payer, reason, extra, output)
        if ok and self.mode == "lie-output":  # the body claims another output than the chain recorded
            body = {"output": "0x" + "00" * len(output)}
        return status, body, headers

    def entry_for(self, body):
        e = self.entry
        return e[:3] + (e[3] + 1,) + e[4:] if body.get("serve") == "wrong-entry" else e


def main():
    d = json.load(open(os.path.join(ROOT, "x402", ".state", "deployment.json")))
    w3 = Web3(Web3.HTTPProvider(os.environ.get("RPC_URL", "http://127.0.0.1:8545")))
    deployment = {"contracts": {"SoloSettlement": d["settlement"], "AuthCaptureProofOperator": d["operator"], "VerifierRegistry": d["registry"]}}
    stored = published_prover(os.path.join(ROOT, "clients", "ts", "published", "solo-proof.json"))

    def prove(body):
        commitment, output, proof = stored(body)
        if body.get("serve") == "tampered":
            proof = proof[:100] + bytes([proof[100] ^ 1]) + proof[101:]
        if body.get("serve") == "other-commitment":  # a proof about another input than the payer's
            commitment = commitment[:31] + bytes([commitment[31] ^ 1])
        return commitment, output, proof

    mw = TestServer(w3=w3, sender=w3.eth.accounts[0], deployment=deployment, verifier_id=d["verifierId"],
                    price=1_000_000, pay_to=d["payTo"], prove=prove,
                    token_domain={"name": "USD Coin", "version": "2"})  # the test token has no name()
    print("server: listening on 127.0.0.1:8402", flush=True)
    serve(mw, port=8402)


if __name__ == "__main__":
    main()
