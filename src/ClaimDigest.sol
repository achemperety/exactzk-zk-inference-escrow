// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ClaimDigest
/// @notice One identifier for one proven claim: "on this chain, the circuit of `verifierId` maps the
/// input committed to by `inputCommitment` to the output whose keccak256 is `outputHash`". The
/// ERC-8183 evaluator records it as the reason of a completed job and the ERC-8004 validator as the
/// response hash, so the same claim carries the same digest wherever it is recorded.
library ClaimDigest {
    function compute(bytes32 verifierId, bytes32 inputCommitment, bytes32 outputHash) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, verifierId, inputCommitment, outputHash));
    }
}
