// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProofVerifier} from "./IProofVerifier.sol";
import {IVerifierRegistry, VerifierEntry} from "./IVerifierRegistry.sol";

/// @notice Result of running one proof against one statement. Never stored.
/// @dev The zero value is `Invalid` on purpose: an unset status must never read as acceptance.
enum ProofStatus {
    Invalid, // the verifier ran and did not accept, or the arguments do not fit the entry
    Valid, // the verifier ran and accepted
    Unverifiable // the check could not be run: unknown entry, or code that is not the registered code
}

/// @title ProofCheck
/// @notice The one place a proof is checked. Settlement, evaluators and validators all call this
/// and never see a proof system's own interface.
/// @dev Rules a consumer can rely on:
/// - `Valid` is returned only if the registered adapter, running the registered code against the
///   registered target code, returned exactly one 32-byte word equal to 1.
/// - A reverting adapter, an adapter that runs out of gas and an adapter that returns anything
///   else all give `Invalid`. None of them can make this function revert.
/// - The adapter is always given the full `verifyGas` of the entry. If the caller cannot spare
///   that much, the call reverts with `InsufficientGasForVerifier` instead of running the check
///   short of gas, so whoever submits the transaction cannot turn a valid proof into `Invalid`
///   by under-funding it.
library ProofCheck {
    /// @notice The transaction did not carry enough gas to give the verifier its full allowance.
    error InsufficientGasForVerifier(uint256 required, uint256 available);

    /// @dev Gas kept back on top of the 64/63 forwarding rule: the call itself and the few
    /// operations between the check and the call.
    uint256 internal constant CALL_MARGIN = 5_000;

    /// @notice Check a proof against a registered verifier, with the entry supplied by the caller.
    /// @dev The cheap path: one storage read in the registry authenticates `e`. An entry that does
    /// not hash to the registered one is treated like an unknown verifier.
    /// @return `Unverifiable` if `verifierId` is unknown, `e` is not its entry, or the adapter or
    /// target no longer has the registered code; otherwise `Valid` or `Invalid`.
    function check(
        IVerifierRegistry registry,
        bytes32 verifierId,
        VerifierEntry calldata e,
        bytes32[] calldata commitments,
        bytes calldata outputs,
        bytes calldata proof
    ) internal view returns (ProofStatus) {
        bytes32 registered = registry.entryHash(verifierId);
        if (registered == bytes32(0) || registered != keccak256(abi.encode(e))) return ProofStatus.Unverifiable;
        return _run(e, commitments, outputs, proof);
    }

    /// @notice Check a proof against a registered verifier, loading the entry from the registry.
    /// @dev Same result as the other overload; costs six more storage reads.
    function check(
        IVerifierRegistry registry,
        bytes32 verifierId,
        bytes32[] calldata commitments,
        bytes calldata outputs,
        bytes calldata proof
    ) internal view returns (ProofStatus) {
        VerifierEntry memory e = registry.entry(verifierId);
        if (e.adapter == address(0)) return ProofStatus.Unverifiable;
        return _run(e, commitments, outputs, proof);
    }

    /// @notice One-lane form of the cheap path, for a caller that holds its single commitment as a
    /// value rather than an array (solo settlement takes it from the payer's terms).
    /// @dev Same rules and result as `check` with a one-element `commitments`; an entry with more
    /// than one lane gives `Invalid`.
    function checkOne(
        IVerifierRegistry registry,
        bytes32 verifierId,
        VerifierEntry calldata e,
        bytes32 commitment,
        bytes calldata output,
        bytes calldata proof
    ) internal view returns (ProofStatus) {
        bytes32 registered = registry.entryHash(verifierId);
        if (registered == bytes32(0) || registered != keccak256(abi.encode(e))) return ProofStatus.Unverifiable;
        if (!_codeMatches(e)) return ProofStatus.Unverifiable;
        if (e.lanes != 1 || output.length != e.outputSize) return ProofStatus.Invalid;
        bytes32[] memory commitments = new bytes32[](1);
        commitments[0] = commitment;
        return _call(e, abi.encodeCall(IProofVerifier.verify, (e.target, e.outputSize, commitments, output, proof)));
    }

    /// @notice `checkOne` for arguments held in memory: a caller that receives the entry, output and
    /// proof ABI-encoded inside one `bytes` argument (an `auth-capture` policy's `policyData`) decodes
    /// them into memory.
    /// @dev Same rules and result as `checkOne`.
    function checkOneInMemory(
        IVerifierRegistry registry,
        bytes32 verifierId,
        VerifierEntry memory e,
        bytes32 commitment,
        bytes memory output,
        bytes memory proof
    ) internal view returns (ProofStatus) {
        bytes32 registered = registry.entryHash(verifierId);
        if (registered == bytes32(0) || registered != keccak256(abi.encode(e))) return ProofStatus.Unverifiable;
        if (!_codeMatches(e)) return ProofStatus.Unverifiable;
        if (e.lanes != 1 || output.length != e.outputSize) return ProofStatus.Invalid;
        bytes32[] memory commitments = new bytes32[](1);
        commitments[0] = commitment;
        return _call(e, abi.encodeCall(IProofVerifier.verify, (e.target, e.outputSize, commitments, output, proof)));
    }

    function _run(VerifierEntry memory e, bytes32[] calldata commitments, bytes calldata outputs, bytes calldata proof)
        private
        view
        returns (ProofStatus)
    {
        if (!_codeMatches(e)) return ProofStatus.Unverifiable;

        if (commitments.length != e.lanes || outputs.length != uint256(e.lanes) * e.outputSize) {
            return ProofStatus.Invalid;
        }

        return _call(e, abi.encodeCall(IProofVerifier.verify, (e.target, e.outputSize, commitments, outputs, proof)));
    }

    /// @dev The code that will run must be the code that was registered. Reading the hashes also
    /// warms both accounts for the calls that follow.
    function _codeMatches(VerifierEntry memory e) private view returns (bool) {
        if (e.adapter.codehash != e.adapterCodeHash) return false;
        return e.target == address(0) || e.target.codehash == e.targetCodeHash;
    }

    /// @dev Call the adapter with exactly its allowance and read its answer.
    function _call(VerifierEntry memory e, bytes memory callData) private view returns (ProofStatus) {
        // A call can pass on at most 63/64 of the gas that is left. Require enough that the
        // adapter receives `verifyGas` in full.
        uint256 allowance = e.verifyGas;
        uint256 required = allowance + allowance / 63 + CALL_MARGIN;
        uint256 available = gasleft();
        if (available < required) revert InsufficientGasForVerifier(required, available);

        address adapter = e.adapter;
        bool accepted;
        assembly ("memory-safe") {
            // Defensive: a result is accepted only if exactly 32 bytes came back, which
            // overwrites this word in full.
            mstore(0x00, 0)
            let success := staticcall(allowance, adapter, add(callData, 0x20), mload(callData), 0x00, 0x20)
            accepted := and(success, and(eq(returndatasize(), 0x20), eq(mload(0x00), 1)))
        }
        return accepted ? ProofStatus.Valid : ProofStatus.Invalid;
    }
}
