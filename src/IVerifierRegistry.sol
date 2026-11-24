// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice One verifier: an adapter, the system-specific contract it drives, and the shape of
/// the statements it checks. Immutable once registered.
struct VerifierEntry {
    address adapter; // IProofVerifier
    uint32 lanes; // statements per proof; 1 for a solo circuit
    uint32 outputSize; // bytes of output per lane
    uint32 verifyGas; // gas handed to the adapter; a caller must have at least this to spare
    address target; // system-specific verifier contract; address(0) if the adapter needs none
    bytes32 adapterCodeHash; // EXTCODEHASH of `adapter`, checked at registration and on every use
    bytes32 targetCodeHash; // EXTCODEHASH of `target`, checked the same way; 0 if there is no target
    bytes32 vkHash; // keccak256 of the canonical verifying-key bytes. Declared, not enforced.
    bytes32 emptyLane; // commitment that marks a padding lane; 0 if the circuit has none
}

/// @title IVerifierRegistry
/// @notice Append-only, permissionless list of verifiers, each identified by its content.
interface IVerifierRegistry {
    /// @notice Emitted once per verifier. The log carries the whole entry.
    event VerifierRegistered(
        bytes32 indexed verifierId,
        bytes32 indexed vkHash,
        address indexed target,
        address adapter,
        bytes32 adapterCodeHash,
        bytes32 targetCodeHash,
        bytes32 proofSystem,
        uint32 lanes,
        uint32 outputSize,
        uint32 verifyGas,
        bytes32 emptyLane
    );

    error AlreadyRegistered(bytes32 verifierId);
    error NoCode(address account);
    error CodeHashMismatch(address account, bytes32 expected, bytes32 actual);
    error DelegatedAccount(address account);
    error TargetHashWithoutTarget();
    error ZeroLanes();
    error ZeroVerifyGas();

    /// @notice Register a verifier. Anyone may call this; nobody can change or remove an entry.
    /// @dev Reverts with `AlreadyRegistered` if the id exists, `NoCode`, `CodeHashMismatch` or
    /// `DelegatedAccount` if `adapter` or `target` is not the code the entry declares,
    /// `TargetHashWithoutTarget`, `ZeroLanes` or `ZeroVerifyGas` if the entry is malformed, and
    /// with whatever `adapter.proofSystem()` reverts with.
    /// @return verifierId `computeId(adapter.proofSystem(), e)`.
    function register(VerifierEntry calldata e) external returns (bytes32 verifierId);

    /// @notice The identifier of an entry. It commits to everything except the two addresses:
    /// `keccak256(abi.encode(proofSystem, vkHash, targetCodeHash, adapterCodeHash, lanes,
    /// outputSize, verifyGas, emptyLane))`.
    function computeId(bytes32 proofSystem, VerifierEntry calldata e) external pure returns (bytes32);

    /// @notice The stored entry, or an all-zero entry if `verifierId` is unknown.
    function entry(bytes32 verifierId) external view returns (VerifierEntry memory);

    /// @notice `keccak256(abi.encode(entry))`, or zero if `verifierId` is unknown. One storage
    /// read: a caller that already holds the entry can authenticate it with this.
    function entryHash(bytes32 verifierId) external view returns (bytes32);

    function exists(bytes32 verifierId) external view returns (bool);
}
