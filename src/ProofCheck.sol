// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProofVerifier} from "./IProofVerifier.sol";
import {IVerifierRegistry, VerifierEntry} from "./IVerifierRegistry.sol";

/// @notice Result of running one proof against one statement. Never stored.
/// @dev The zero value is `Unverifiable` on purpose: a status nobody set reads as "nothing was
/// decided", never as acceptance and never as a rejection. `Valid` is 1, the adapter's success word.
enum ProofStatus {
    Unverifiable, // 0: the check could not be run, or ran without a definite answer; nothing was decided
    Valid, // 1: the verifier ran on the registered code and accepted
    Invalid // 2: the verifier ran on the registered code and rejected with gas to spare, or the arguments do not fit the entry
}

/// @title ProofCheck
/// @notice The one place a proof is checked. Settlement, evaluators and validators all call this
/// and never see a proof system's own interface.
/// @dev Rules a consumer can rely on:
/// - `Valid` is returned only if the registered adapter, running the registered code against the
///   registered target code, returned exactly one 32-byte word equal to 1.
/// - `Invalid` is returned only for arguments that do not fit the entry, or if the adapter returned
///   exactly one 32-byte word equal to 0 and left more than `verifyGas / 16` of its allowance unspent.
/// - Everything else gives `Unverifiable`: an adapter that reverts, that runs out of gas, that
///   returns anything else, or that returns 0 with `verifyGas / 16` or less unspent. A verifier
///   may reject by reverting with no data, which looks the same as running out of gas. Exhaustion
///   below `d` nested calls that each forward all their gas leaves about
///   `verifyGas * (1 - (63/64)^d)` unspent (EIP-150): 1.1% at d = 1, 3.0% at 2, 4.5% at 3, 6.0% at
///   4, all under 1/16 (6.25%). A precompile given bad input also consumes all the gas it is given.
///   An entry whose verifier nests calls deeper than 4 below the adapter must therefore not be
///   registered. None of these can make this function revert. A gas repricing can therefore never turn a valid proof into
///   `Invalid`; an entry whose allowance has become too small answers `Unverifiable`.
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
    /// target no longer has the registered code; otherwise as `_call` classifies the answer.
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

    /// @dev Call the adapter with exactly its allowance and classify its answer.
    function _call(VerifierEntry memory e, bytes memory callData) private view returns (ProofStatus) {
        // A call can pass on at most 63/64 of the gas that is left. Require enough that the
        // adapter receives `verifyGas` in full.
        uint256 allowance = e.verifyGas;
        uint256 required = allowance + allowance / 63 + CALL_MARGIN;
        uint256 available = gasleft();
        if (available < required) revert InsufficientGasForVerifier(required, available);

        address adapter = e.adapter;
        bool answered;
        uint256 word;
        uint256 used;
        assembly ("memory-safe") {
            // Defensive: a result is read only if exactly 32 bytes came back, which overwrites
            // this word in full.
            mstore(0x00, 0)
            let before := gas()
            let success := staticcall(allowance, adapter, add(callData, 0x20), mload(callData), 0x00, 0x20)
            used := sub(before, gas())
            answered := and(success, eq(returndatasize(), 0x20))
            word := mload(0x00)
        }
        if (!answered) return ProofStatus.Unverifiable;
        if (word == 1) return ProofStatus.Valid;
        // `used` also counts the few gas units of the call instruction itself, which errs towards
        // Unverifiable, never towards Invalid.
        if (word == 0 && used < allowance - allowance / 16) return ProofStatus.Invalid;
        return ProofStatus.Unverifiable;
    }
}
