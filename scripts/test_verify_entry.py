#!/usr/bin/env python3
"""Unit tests for scripts/verify_entry.py. No EZKL, no network: the comparison is fed the pinned
files and entries built here. Run: python3 scripts/test_verify_entry.py"""

import json
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_entry as v  # noqa: E402

SOLO_ID = bytes.fromhex("c302c6867eddfdcd201bbe7fb653191da6ee4c1a178e7df821e9ebca01b6ff9b")
K8_ID = bytes.fromhex("ff34bcad7f2abcb126327e61b648bae1d6a446ad3bd15924ec2218c742d51107")

with open(os.path.join(v.REPO, "deployments", "base-sepolia.json")) as _f:
    DEPLOYED = {k: a.lower() for k, a in json.load(_f)["contracts"].items()}

# The two entries as registered on the testnet, read with entry().
SOLO_ENTRY = {
    "adapter": DEPLOYED["Halo2EzklAdapter"], "lanes": 1, "outputSize": 320, "verifyGas": 600000,
    "target": DEPLOYED["soloVerifier"],
    "adapterCodeHash": "0xbfc219d647efafebb7db189aa5b4f35703e4fbb226ff9ba9b9b907c56b1f84cf",
    "targetCodeHash": "0x8cd0b80f6b67e187a9ee98478fdd1278b8e1b666d666d442920aaf911f485f49",
    "vkHash": "0x13cff0426abe00c941934bdd6bb7757f2e703fb9f6862bf08a783eeca08b4ff2",
    "emptyLane": "0x" + "00" * 32,
}
K8_ENTRY = {
    **SOLO_ENTRY, "lanes": 8, "verifyGas": 660000, "target": DEPLOYED["k8Verifier"],
    "targetCodeHash": "0x471c8109f1a03375b17ae6afd421f5857346edf92bf37fce1c7b90a3e02d7ef1",
    "vkHash": "0xdd03fb0c69e96cc02cbcc6bed8ef51665f934c01cddaf2a855bd1c7fce94675f",
}
# Values from circuits/spike-mlp/MANIFEST.md.
SOLO_CODE_HASH_STRIPPED = "0xf60aad67ed7bf1b55cc6cb097b1997036617c161fbaa7f0fd80661c3bfc7b17c"
K8_CODE_HASH_STRIPPED = "0xd0cab4041caaf77ea95fe45a29d14950be503ce26eb982af11026634112d8c67"
PROOF_SYSTEM = v.keccak256(v.PROOF_SYSTEM_TAG)


def read(rel):
    with open(os.path.join(v.REPO, rel), "rb") as f:
        return f.read()


def fixture_runtime(name):
    s = read(f"test/fixtures/{name}").decode()
    return bytes.fromhex(re.search(r'function verifierBytecode\(\)[^h]*hex"([0-9a-f]+)"', s).group(1))


def encode_entry(e):
    """abi.encode(VerifierEntry): nine static words, in struct order."""
    out = b""
    for f in v.ENTRY_FIELDS:
        x = e[f]
        out += x.to_bytes(32, "big") if isinstance(x, int) else bytes.fromhex(x[2:]).rjust(32, b"\x00")
    return out


SOLO_VK = read("circuits/spike-mlp/run_t3_k5_nonces/vk.key")
SOLO_RUNTIME = fixture_runtime("Fixtures.sol")
K8_RUNTIME = fixture_runtime("FixturesK8.sol")


class Keccak(unittest.TestCase):
    def test_vectors(self):
        self.assertEqual(v.keccak256(b"").hex(), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        self.assertEqual(v.keccak256(b"abc").hex(), "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        # 200 bytes: two blocks of the 136-byte rate (checked with `cast keccak`)
        self.assertEqual(v.keccak256(b"a" * 200).hex(), "96ea54061def936c4be90b518992fdc6f12f535068a256229aca54267b4d084d")
        self.assertEqual(v.selector("entry(bytes32)").hex(), "80820b31")

    def test_pinned_values(self):
        self.assertEqual(v.hx(v.keccak256(SOLO_VK)), SOLO_ENTRY["vkHash"])
        self.assertEqual(v.hx(v.keccak256(SOLO_RUNTIME)), SOLO_ENTRY["targetCodeHash"])
        self.assertEqual(v.hx(v.keccak256(K8_RUNTIME)), K8_ENTRY["targetCodeHash"])
        self.assertEqual(v.hx(v.keccak256(v.split_trailer(SOLO_RUNTIME)[0])), SOLO_CODE_HASH_STRIPPED)
        self.assertEqual(v.hx(v.keccak256(v.split_trailer(K8_RUNTIME)[0])), K8_CODE_HASH_STRIPPED)


class Trailer(unittest.TestCase):
    def test_splits_the_pinned_verifier(self):
        code, trailer = v.split_trailer(SOLO_RUNTIME)
        self.assertEqual((len(code), len(trailer)), (17992 - 53, 53))

    def test_rejects_other_forms(self):
        bad = {
            "length field": SOLO_RUNTIME[:-1] + b"\x34",
            "compiler version": SOLO_RUNTIME[:-3] + b"\x15" + SOLO_RUNTIME[-2:],
            "not an ipfs hash": SOLO_RUNTIME[:-52] + b"\x65" + SOLO_RUNTIME[-51:],
            "too short": SOLO_RUNTIME[-52:],
        }
        for label, code in bad.items():
            with self.subTest(label), self.assertRaises(ValueError):
                v.split_trailer(code)


class Ids(unittest.TestCase):
    def test_registered_ids(self):
        self.assertEqual(v.compute_id(PROOF_SYSTEM, SOLO_ENTRY), SOLO_ID)
        self.assertEqual(v.compute_id(PROOF_SYSTEM, K8_ENTRY), K8_ID)

    def test_every_field_but_the_addresses_is_in_the_id(self):
        changes = {"lanes": 2, "outputSize": 352, "verifyGas": 600001, "vkHash": "0x" + "11" * 32,
                   "targetCodeHash": "0x" + "22" * 32, "adapterCodeHash": "0x" + "33" * 32, "emptyLane": "0x" + "44" * 32}
        for field, value in changes.items():
            with self.subTest(field):
                self.assertNotEqual(v.compute_id(PROOF_SYSTEM, {**SOLO_ENTRY, field: value}), SOLO_ID)
        moved = {**SOLO_ENTRY, "adapter": "0x" + "55" * 20, "target": "0x" + "66" * 20}
        self.assertEqual(v.compute_id(PROOF_SYSTEM, moved), SOLO_ID)
        self.assertNotEqual(v.compute_id(v.keccak256(b"another system"), SOLO_ENTRY), SOLO_ID)

    def test_decode_entry(self):
        self.assertEqual(v.decode_entry(encode_entry(SOLO_ENTRY)), SOLO_ENTRY)


ADAPTER_CODE = b"\x60\x80adapter"


def view_for(entry, target_code, adapter_code=ADAPTER_CODE, proof_system=PROOF_SYSTEM, entry_hash=None):
    raw = encode_entry(entry)
    return {"entry": v.decode_entry(raw), "entryRaw": raw,
            "entryHash": entry_hash if entry_hash is not None else v.keccak256(raw),
            "registryCode": b"\x60\x80registry", "targetCode": target_code, "adapterCode": adapter_code,
            "proofSystem": proof_system}


class Compare(unittest.TestCase):
    """compare() against an entry that is consistent with the pinned solo files, then broken one way at a time."""

    def setUp(self):
        self.entry = {**SOLO_ENTRY, "adapterCodeHash": v.hx(v.keccak256(ADAPTER_CODE))}
        self.id = v.compute_id(PROOF_SYSTEM, self.entry)
        self.view = view_for(self.entry, SOLO_RUNTIME)

    def failing(self, view=None, vk=SOLO_VK, runtime=SOLO_RUNTIME, lanes=1, verifier_id=None):
        rows = v.compare(verifier_id or self.id, view or self.view, vk, runtime, lanes)
        self.assertEqual(v.verdict(rows), "MATCH" if all(ok for _, ok, _ in rows) else "MISMATCH")
        return {name for name, ok, _ in rows if not ok}

    def test_all_match(self):
        rows = v.compare(self.id, self.view, SOLO_VK, SOLO_RUNTIME, 1)
        self.assertEqual(len(rows), 12)
        self.assertEqual(self.failing(), set())
        self.assertEqual(v.verdict(rows), "MATCH")

    def test_a_different_metadata_hash_still_matches(self):
        local = bytearray(SOLO_RUNTIME)
        local[-40] ^= 0xFF  # inside the ipfs hash: what compiling from another path changes
        self.assertEqual(self.failing(runtime=bytes(local)), set())

    def test_code_byte_changed(self):
        local = bytearray(SOLO_RUNTIME)
        local[100] ^= 0x01
        self.assertEqual(self.failing(runtime=bytes(local)),
                         {"regenerated verifier = on-chain verifier, metadata trailer removed"})

    def test_code_appended_before_the_trailer(self):
        code, trailer = v.split_trailer(SOLO_RUNTIME)
        self.assertEqual(self.failing(runtime=code + b"\x00" + trailer),
                         {"regenerated verifier = on-chain verifier, metadata trailer removed"})

    def test_vk_changed(self):
        vk = bytearray(SOLO_VK)
        vk[1000] ^= 0x01
        self.assertEqual(self.failing(vk=bytes(vk)), {"keccak256(regenerated verifying key) = entry.vkHash"})

    def test_not_registered(self):
        zero = {**self.entry, "adapter": "0x" + "00" * 20}
        view = view_for(zero, b"", entry_hash=b"\x00" * 32)
        self.assertEqual(self.failing(view=view), {"entry is registered"})

    def test_entry_not_the_registered_one(self):
        view = view_for({**self.entry, "verifyGas": 1}, SOLO_RUNTIME, entry_hash=v.keccak256(encode_entry(self.entry)))
        self.assertEqual(self.failing(view=view), {
            "entry() is the registered entry (keccak256 of its encoding = entryHash)",
            "verifier id = computeId(proof system, entry)"})

    def test_other_id(self):
        self.assertEqual(self.failing(verifier_id=SOLO_ID), {"verifier id = computeId(proof system, entry)"})

    def test_shape(self):
        self.assertEqual(self.failing(lanes=8), {"entry shape: lanes"})
        view = view_for({**self.entry, "outputSize": 32}, SOLO_RUNTIME)
        self.assertEqual(self.failing(view=view, verifier_id=v.compute_id(PROOF_SYSTEM, view["entry"])),
                         {"entry shape: outputSize"})

    def test_adapter(self):
        self.assertEqual(self.failing(view=view_for(self.entry, SOLO_RUNTIME, adapter_code=b"\x60\x80other")),
                         {"adapter's code hash = entry.adapterCodeHash"})
        other = v.keccak256(b"groth16")
        self.assertEqual(self.failing(view=view_for(self.entry, SOLO_RUNTIME, proof_system=other)),
                         {"adapter reports the EZKL proof system", "verifier id = computeId(proof system, entry)"})

    def test_code_at_the_address_is_not_the_registered_code(self):
        self.assertEqual(self.failing(view=view_for(self.entry, K8_RUNTIME)), {
            "verifier's code hash = entry.targetCodeHash",
            "regenerated verifier = on-chain verifier, metadata trailer removed"})

    def test_delegated_verifier(self):
        delegated = b"\xef\x01\x00" + b"\x77" * 20
        entry = {**self.entry, "targetCodeHash": v.hx(v.keccak256(delegated))}
        self.assertEqual(self.failing(view=view_for(entry, delegated), verifier_id=v.compute_id(PROOF_SYSTEM, entry)), {
            "verifier is not a delegated account (EIP-7702)",
            "regenerated verifier = on-chain verifier, metadata trailer removed"})


if __name__ == "__main__":
    unittest.main(verbosity=1)
