"""x402 version 2 middleware for selling proof-gated inference (clients/python/README.md)."""
import json

from .http import serve, wsgi_app
from .middleware import ERROR_REASONS, ProofGatedMiddleware, Refused, hexb, terms_authorizer


def published_prover(path):
    """A `prove` callback that serves one stored proof (clients/ts/published/solo-proof.json):
    published-proof mode. It can only sell the inference whose input commitment that proof carries."""
    p = json.load(open(path))
    stored = (hexb(p["inputCommitment"]), hexb(p["output"]), hexb(p["proof"]))

    def prove(body):
        return stored

    return prove


__all__ = ["ERROR_REASONS", "ProofGatedMiddleware", "Refused", "published_prover", "serve", "terms_authorizer", "wsgi_app"]
