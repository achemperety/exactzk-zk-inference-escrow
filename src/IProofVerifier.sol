// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IProofVerifier
/// @notice A proof-system adapter. One deployment serves every verifying key of its proof system.
/// @dev An adapter holds no state and reads none: what it answers must depend on its code, its
/// arguments and the code of `target` only. Consumers identify an adapter by its code hash.
///
/// The statement checked is the same for every proof system. For each lane `i`:
/// "the circuit behind `target` maps the input committed to by `commitments[i]` to
/// `outputs[i * outputSize .. (i + 1) * outputSize]`". Nothing else is part of the statement.
interface IProofVerifier {
    /// @param target      System-specific verifier contract (for EZKL: the generated Halo2 verifier).
    ///                    `address(0)` if the adapter needs none.
    /// @param outputSize  Bytes of output per lane.
    /// @param commitments One input commitment per lane, in lane order.
    /// @param outputs     `commitments.length * outputSize` bytes, lane after lane.
    /// @param proof       Opaque proof bytes.
    /// @return ok         True if and only if the proof establishes every lane's statement.
    /// @dev MUST return false, not revert, for a definite rejection: a bad proof, a malformed
    /// argument, a public input outside the proof system's field. SHOULD revert, not return false,
    /// when it cannot tell a rejection from a failure of `target`, for example because `target`
    /// ran out of gas. `ProofCheck` reads a single 32-byte `1` as Valid, a `0` returned with gas to
    /// spare as Invalid, and anything else (a revert, running out of gas, any other answer, a `0`
    /// after nearly the whole allowance was used) as Unverifiable.
    function verify(
        address target,
        uint32 outputSize,
        bytes32[] calldata commitments,
        bytes calldata outputs,
        bytes calldata proof
    ) external view returns (bool ok);

    /// @notice Tag of the proof system, for example `keccak256("halo2-kzg-bn254/ezkl")`.
    function proofSystem() external view returns (bytes32);
}
