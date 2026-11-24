"""Run the middleware in published-proof mode:

    python -m exactzk_x402 --rpc URL --deployment deployments/base-sepolia.json \\
        --proof clients/ts/published/solo-proof.json --price 10000 --pay-to 0x... \\
        (--key-env NAME | --unlocked 0x...) [--port 8402]

--key-env names an environment variable that holds the sending account's key (the server pays gas);
--unlocked names an account the node signs for (a local development node). The server binds to
127.0.0.1. A real prover replaces `published_prover` with a callback that proves the request's input.
"""
import argparse, json, os

from web3 import Web3

from . import ProofGatedMiddleware, published_prover, serve


def main():
    a = argparse.ArgumentParser(prog="python -m exactzk_x402")
    a.add_argument("--rpc", required=True)
    a.add_argument("--deployment", required=True)
    a.add_argument("--proof", required=True)
    a.add_argument("--price", type=int, required=True)
    a.add_argument("--pay-to", required=True)
    a.add_argument("--verifier", default="solo")
    a.add_argument("--key-env")
    a.add_argument("--unlocked")
    a.add_argument("--port", type=int, default=8402)
    o = a.parse_args()
    if bool(o.key_env) == bool(o.unlocked):
        a.error("give exactly one of --key-env and --unlocked")
    w3 = Web3(Web3.HTTPProvider(o.rpc))
    sender = Web3.to_checksum_address(o.unlocked) if o.unlocked else w3.eth.account.from_key(os.environ[o.key_env])
    d = json.load(open(o.deployment))
    mw = ProofGatedMiddleware(w3=w3, sender=sender, deployment=d, verifier_id=d["verifierIds"][o.verifier],
                              price=o.price, pay_to=o.pay_to, prove=published_prover(o.proof))
    print(f"listening on 127.0.0.1:{o.port}", flush=True)
    serve(mw, port=o.port)


if __name__ == "__main__":
    main()
