#!/usr/bin/env python3
"""Compare the ERC-8004 registries running on a chain with the pinned source in lib/erc-8004-contracts.

    python3 scripts/erc8004_live_check.py <testnet|mainnet> <rpc-url> <path to solc 0.8.24>

Read-only. It reads the Validation Registry proxy address from the pinned
lib/erc-8004-contracts/scripts/addresses.ts (TESTNET_ADDRESSES or MAINNET_ADDRESSES), and at one block:
the proxy's ERC-1967 implementation, the Identity Registry the proxy points to, and that proxy's
implementation. It compiles both registries from the pinned source with the settings of the authors'
hardhat.config.ts (solc 0.8.24, Shanghai, 200 optimiser runs, via-IR, OpenZeppelin v5.4.0) and compares
runtime code with the CBOR metadata removed and every immutable zeroed, in both the built and the live
code. Needs `cast` (Foundry) on PATH or in ~/.foundry/bin, and solc 0.8.24 from binaries.soliditylang.org
(check its SHA-256 against that site's list.json).
"""
import json, os, re, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ERC = os.path.join(ROOT, "lib/erc-8004-contracts")
OZU = os.path.join(ROOT, "lib/openzeppelin-contracts-upgradeable/contracts")
OZ = os.path.join(ROOT, "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts")
SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
CAST = shutil.which("cast") or os.path.expanduser("~/.foundry/bin/cast")


def cast(*args):
    return subprocess.run([CAST, *args], capture_output=True, text=True, check=True).stdout.strip()


def resolve(unit):
    for prefix, base in (("@openzeppelin/contracts-upgradeable/", OZU), ("@openzeppelin/contracts/", OZ)):
        if unit.startswith(prefix):
            return os.path.join(base, unit[len(prefix):])
    return os.path.join(ERC, unit)


def build(solc, name):
    """Runtime code of contracts/<name>.sol, and its immutable references."""
    sources, todo = {}, [f"contracts/{name}.sol"]
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
    std = {
        "language": "Solidity",
        "sources": sources,
        "settings": {
            "evmVersion": "shanghai",
            "optimizer": {"enabled": True, "runs": 200},
            "viaIR": True,
            "outputSelection": {"*": {"*": ["evm.deployedBytecode.object", "evm.deployedBytecode.immutableReferences"]}},
        },
    }
    out = json.loads(subprocess.run([solc, "--standard-json"], input=json.dumps(std), capture_output=True, text=True).stdout)
    errors = [e["formattedMessage"] for e in out.get("errors", []) if e["severity"] == "error"]
    if errors:
        sys.exit("\n".join(errors))
    c = out["contracts"][f"contracts/{name}.sol"][name]["evm"]["deployedBytecode"]
    refs = [(r["start"], r["length"]) for rs in c["immutableReferences"].values() for r in rs]
    return bytes.fromhex(c["object"]), refs


def comparable(code, refs):
    """Metadata removed (its length is the last two bytes), immutables zeroed."""
    b = bytearray(code[: len(code) - int.from_bytes(code[-2:], "big") - 2])
    for start, length in refs:
        b[start : start + length] = bytes(length)
    return bytes(b)


def main():
    network, rpc, solc = sys.argv[1:4]
    table = "TESTNET_ADDRESSES" if network == "testnet" else "MAINNET_ADDRESSES"
    ts = open(os.path.join(ERC, "scripts/addresses.ts")).read()
    block = re.search(table + r"\s*=\s*\{(.*?)\}", ts, re.S).group(1)
    validation_proxy = re.search(r'validationRegistry:\s*"(0x[0-9a-fA-F]{40})"', block).group(1)
    head = cast("block-number", "--rpc-url", rpc)
    print(f"chain id {cast('chain-id', '--rpc-url', rpc)}, block {head}")
    identity_proxy = cast("call", validation_proxy, "getIdentityRegistry()(address)", "--rpc-url", rpc, "--block", head)
    verdict = True
    for name, proxy in (("ValidationRegistryUpgradeable", validation_proxy), ("IdentityRegistryUpgradeable", identity_proxy)):
        impl = "0x" + cast("storage", proxy, SLOT, "--rpc-url", rpc, "--block", head)[-40:]
        live = bytes.fromhex(cast("code", impl, "--rpc-url", rpc, "--block", head)[2:])
        built, refs = build(solc, name)
        a, b = comparable(built, refs), comparable(live, refs)
        same = a == b and len(built) == len(live)
        verdict &= same
        print(f"{name}: proxy {proxy}, implementation {impl}, {len(live)} bytes live, {len(built)} built")
        print(f"  compared (metadata removed, {len(refs)} immutables zeroed): live {cast('keccak', '0x' + b.hex())}")
        print(f"  {'':52}built {cast('keccak', '0x' + a.hex())}  {'MATCH' if same else 'DIFFER'}")
    print("verdict:", "both registries match the pinned source" if verdict else "DIFFERENT CODE")
    sys.exit(0 if verdict else 1)


if __name__ == "__main__":
    main()
