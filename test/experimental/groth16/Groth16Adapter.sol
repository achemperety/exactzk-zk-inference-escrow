// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProofVerifier} from "../../../src/IProofVerifier.sol";

/// @title Groth16Adapter (EXPERIMENTAL)
/// @notice Adapter for Groth16 (BN254) verifiers exported by gnark (v0.16), for the second-backend
/// prototype (measurements/experimental/groth16/). Measurement only: never registered or deployed on any
/// network. The prototype's setup is single-party (insecure), and its circuit commits to the input with
/// Poseidon2, not the canonical EZKL commitment, so it does not prove the same statement.
/// @dev The statement is the one every adapter checks (IProofVerifier): for each lane, the circuit maps
/// the input committed to by `commitments[i]` to the lane's outputs. Public inputs, in order: each
/// lane's commitment, then its outputs, one field element per 32 bytes, lane after lane. The proof is
/// gnark's 256-byte uncompressed encoding. The verifier's `verifyProof(bytes, uint256[N])` reverts on a
/// bad proof and returns nothing otherwise; its selector depends on N, so the call is encoded here.
contract Groth16Adapter is IProofVerifier {
    /// @dev keccak256("groth16-bn254/gnark")
    bytes32 public constant PROOF_SYSTEM = keccak256("groth16-bn254/gnark");

    uint256 private constant R = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

    function proofSystem() external pure returns (bytes32) {
        return PROOF_SYSTEM;
    }

    function verify(
        address target,
        uint32 outputSize,
        bytes32[] calldata commitments,
        bytes calldata outputs,
        bytes calldata proof
    ) external view returns (bool) {
        uint256 lanes = commitments.length;
        if (lanes == 0 || outputSize % 32 != 0 || outputs.length != lanes * uint256(outputSize)) return false;
        if (proof.length != 256 || target.code.length == 0) return false;
        uint256 perLane = outputSize / 32;
        uint256 n = lanes * (1 + perLane);

        // verifyProof(bytes proof, uint256[n] input): head = [offset of proof][input, inline], then
        // the proof's length and its 256 bytes.
        bytes memory data = new bytes(4 + 32 + 32 * n + 32 + 256);
        bytes4 selector = bytes4(keccak256(abi.encodePacked("verifyProof(bytes,uint256[", _decimal(n), "])")));
        uint256 tail = 32 + 32 * n;
        assembly ("memory-safe") {
            let p := add(data, 0x20)
            mstore(p, selector)
            mstore(add(p, 4), tail)
            mstore(add(add(p, 4), tail), 256)
            calldatacopy(add(add(p, 36), tail), proof.offset, 256)
        }
        uint256 k;
        for (uint256 i = 0; i < lanes; ++i) {
            uint256 c = uint256(commitments[i]);
            if (c >= R) return false;
            _put(data, k++, c);
            for (uint256 j = 0; j < perLane; ++j) {
                uint256 o = uint256(bytes32(outputs[(i * perLane + j) * 32:(i * perLane + j + 1) * 32]));
                if (o >= R) return false;
                _put(data, k++, o);
            }
        }
        (bool ok,) = target.staticcall(data);
        return ok;
    }

    /// Input `index` sits after the selector and the proof's offset word.
    function _put(bytes memory data, uint256 index, uint256 value) private pure {
        assembly ("memory-safe") {
            mstore(add(add(data, 0x44), mul(index, 0x20)), value)
        }
    }

    function _decimal(uint256 v) private pure returns (bytes memory s) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) {
            ++len;
        }
        s = new bytes(len);
        for (; v != 0; v /= 10) {
            s[--len] = bytes1(uint8(48 + v % 10));
        }
    }
}
