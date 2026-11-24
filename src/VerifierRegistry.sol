// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProofVerifier} from "./IProofVerifier.sol";
import {IVerifierRegistry, VerifierEntry} from "./IVerifierRegistry.sol";

/// @title VerifierRegistry
/// @notice Append-only list of verifiers. No owner, no update, no removal.
/// @dev Trust does not come from who registered an entry. It comes from a payer choosing an
/// identifier, and the identifier commits to the code that will run: the hashes of the adapter
/// and of the verifier it drives, the declared verifying-key hash, the shape of the statement
/// and the gas the check is given.
///
/// What an identifier does and does not pin:
/// - It pins code, not addresses. Whoever registers first chooses which deployed copies of that
///   code the entry points at. For code that reads no storage, as an adapter must not and a
///   generated verifier does not, every copy behaves the same, so this choice is harmless.
///   An identifier for code whose answer depends on storage is not safe to rely on.
/// - It does not prove that the verifier code embeds the declared verifying key. That is
///   established off-chain, by regenerating the verifier from the key and comparing bytecode.
contract VerifierRegistry is IVerifierRegistry {
    mapping(bytes32 verifierId => VerifierEntry) private _entries;
    mapping(bytes32 verifierId => bytes32) private _entryHash;

    /// @inheritdoc IVerifierRegistry
    function register(VerifierEntry calldata e) external returns (bytes32 verifierId) {
        if (e.lanes == 0) revert ZeroLanes();
        if (e.verifyGas == 0) revert ZeroVerifyGas();
        _requireCode(e.adapter, e.adapterCodeHash);
        if (e.target == address(0)) {
            if (e.targetCodeHash != bytes32(0)) revert TargetHashWithoutTarget();
        } else {
            _requireCode(e.target, e.targetCodeHash);
        }

        bytes32 system = IProofVerifier(e.adapter).proofSystem();
        verifierId = computeId(system, e);
        if (_entryHash[verifierId] != bytes32(0)) revert AlreadyRegistered(verifierId);

        _entries[verifierId] = e;
        _entryHash[verifierId] = keccak256(abi.encode(e));

        emit VerifierRegistered(
            verifierId,
            e.vkHash,
            e.target,
            e.adapter,
            e.adapterCodeHash,
            e.targetCodeHash,
            system,
            e.lanes,
            e.outputSize,
            e.verifyGas,
            e.emptyLane
        );
    }

    /// @inheritdoc IVerifierRegistry
    function computeId(bytes32 proofSystem, VerifierEntry calldata e) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                proofSystem,
                e.vkHash,
                e.targetCodeHash,
                e.adapterCodeHash,
                e.lanes,
                e.outputSize,
                e.verifyGas,
                e.emptyLane
            )
        );
    }

    /// @inheritdoc IVerifierRegistry
    function entry(bytes32 verifierId) external view returns (VerifierEntry memory) {
        return _entries[verifierId];
    }

    /// @inheritdoc IVerifierRegistry
    function entryHash(bytes32 verifierId) external view returns (bytes32) {
        return _entryHash[verifierId];
    }

    /// @inheritdoc IVerifierRegistry
    function exists(bytes32 verifierId) external view returns (bool) {
        return _entryHash[verifierId] != bytes32(0);
    }

    /// @dev `account` must hold exactly the declared code, and that code must be its own: an
    /// account that delegates its code (EIP-7702 designator, `0xef0100 ‖ address`) has a stable
    /// code hash while the code that actually runs lives elsewhere.
    function _requireCode(address account, bytes32 expected) private view {
        if (account.code.length == 0) revert NoCode(account);
        bytes32 actual = account.codehash;
        if (actual != expected) revert CodeHashMismatch(account, expected, actual);
        bool delegated;
        assembly ("memory-safe") {
            mstore(0x00, 0)
            extcodecopy(account, 0x00, 0, 3)
            delegated := eq(shr(232, mload(0x00)), 0xef0100)
        }
        if (delegated) revert DelegatedAccount(account);
    }
}
