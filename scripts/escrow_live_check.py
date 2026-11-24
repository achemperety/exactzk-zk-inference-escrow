#!/usr/bin/env python3
"""Compare x402's auth-capture escrow and ERC-3009 collector at their canonical addresses with the pinned
source in lib/commerce-payments (base/commerce-payments v1.1.0).

    python3 scripts/escrow_live_check.py <rpc-url> <path to solc 0.8.28>

Read-only. At one block it reads the runtime code at the two canonical v1.1 addresses, compiles both
contracts from the pinned source with the repository's deploy profile (solc 0.8.28, Cancun, via-IR,
100,000 optimiser runs; OpenZeppelin v5.0.2 and solady as its remappings.txt names them), and compares
the code with the CBOR metadata removed and every immutable zeroed. It also prints the code hash the
deployment script pins (script/DeployBaseSepolia.s.sol). Needs `cast` (Foundry).
"""
import json, os, re, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CP = os.path.join(ROOT, "lib/commerce-payments")
CAST = shutil.which("cast") or os.path.expanduser("~/.foundry/bin/cast")
MAP = (
    ("@openzeppelin/contracts/", os.path.join(CP, "lib/spend-permissions/lib/openzeppelin-contracts/contracts/")),
    ("solady/", os.path.join(CP, "lib/solady/src/")),
)
TARGETS = (
    ("src/AuthCaptureEscrow.sol", "AuthCaptureEscrow", "0xf96815976523E00e65Be8f34cA5e64b4f41EB19c"),
    ("src/collectors/ERC3009PaymentCollector.sol", "ERC3009PaymentCollector", "0x8612dfdc421f80336cd14E8EF9cb1E765dB5ab88"),
)


def cast(*args):
    return subprocess.run([CAST, *args], capture_output=True, text=True, check=True).stdout.strip()


def resolve(unit):
    for prefix, base in MAP:
        if unit.startswith(prefix):
            return os.path.join(base, unit[len(prefix):])
    return os.path.join(CP, unit)


def sources_for(root):
    sources, todo = {}, [root]
    while todo:
        unit = todo.pop()
        if unit in sources:
            continue
        text = open(resolve(unit)).read()
        sources[unit] = {"content": text}
        for imp in re.findall(r'import\s+(?:[^"\']*?from\s+)?["\']([^"\']+)["\']', text):
            if imp.startswith("."):
                parts = unit.split("/")[:-1]
                for p in imp.split("/"):
                    parts.pop() if p == ".." else (parts.append(p) if p != "." else None)
                imp = "/".join(parts)
            todo.append(imp)
    return sources


def comparable(code, refs):
    """Metadata removed (its length is the last two bytes), immutables zeroed."""
    b = bytearray(code[: len(code) - int.from_bytes(code[-2:], "big") - 2])
    for start, length in refs:
        b[start : start + length] = bytes(length)
    return bytes(b)


def main():
    rpc, solc = sys.argv[1:3]
    head = cast("block-number", "--rpc-url", rpc)
    print(f"chain id {cast('chain-id', '--rpc-url', rpc)}, block {head}")
    verdict = True
    for path, name, address in TARGETS:
        std = {
            "language": "Solidity",
            "sources": sources_for(path),
            "settings": {
                "evmVersion": "cancun",
                "optimizer": {"enabled": True, "runs": 100000},
                "viaIR": True,
                "outputSelection": {"*": {"*": ["evm.deployedBytecode.object", "evm.deployedBytecode.immutableReferences"]}},
            },
        }
        out = json.loads(subprocess.run([solc, "--standard-json"], input=json.dumps(std), capture_output=True, text=True).stdout)
        errors = [e["formattedMessage"] for e in out.get("errors", []) if e["severity"] == "error"]
        if errors:
            sys.exit("\n".join(errors))
        c = out["contracts"][path][name]["evm"]["deployedBytecode"]
        refs = [(r["start"], r["length"]) for rs in c["immutableReferences"].values() for r in rs]
        built = bytes.fromhex(c["object"])
        live_hex = cast("code", address, "--rpc-url", rpc, "--block", head)
        live = bytes.fromhex(live_hex[2:])
        a, b = comparable(built, refs), comparable(live, refs)
        same = len(live) > 0 and a == b and len(built) == len(live)
        verdict &= same
        print(f"{name} at {address}: {len(live)} bytes live, {len(built)} built; code hash {cast('keccak', live_hex)}")
        print(f"  compared ({len(refs)} immutable references zeroed): live  {cast('keccak', '0x' + b.hex())}")
        print(f"  {'':42}built {cast('keccak', '0x' + a.hex())}  {'MATCH' if same else 'DIFFER'}")
    print("verdict:", "both match base/commerce-payments v1.1.0" if verdict else "DIFFERENT CODE")
    sys.exit(0 if verdict else 1)


if __name__ == "__main__":
    main()
