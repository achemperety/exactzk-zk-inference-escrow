"""Bytecode-hash helpers used by the verifier reproduction scripts in this folder.

The scripts import these two functions under this module name. Only the helpers
live here.
"""


def strip_cbor_metadata(code_hex: str) -> str:
    """Remove the trailing CBOR metadata that solc appends to runtime bytecode.

    Layout: [executable code][cbor metadata][2-byte big-endian metadata length].
    With solc's default settings the metadata contains a hash that depends on
    the path the source was compiled from, so two parties who compile the same
    verifier get different raw bytecode. Hashing the stripped code makes the
    comparison independent of that. If the length field is implausible the
    input is returned unchanged.
    """
    h = code_hex[2:] if code_hex.startswith("0x") else code_hex
    if len(h) < 4:
        return code_hex
    meta_len_hexchars = int(h[-4:], 16) * 2
    cut = len(h) - 4 - meta_len_hexchars
    if cut <= 0 or cut > len(h):
        return code_hex
    return "0x" + h[:cut]


def keccak256_from_code(w3, addr: str) -> bytes:
    """keccak256 of the metadata-stripped runtime code deployed at `addr`."""
    from web3 import Web3

    code = w3.eth.get_code(Web3.to_checksum_address(addr))
    stripped = strip_cbor_metadata("0x" + bytes(code).hex())
    return Web3.keccak(hexstr=stripped)
