// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAuthCaptureEscrow} from "../../../src/IAuthCaptureEscrow.sol";
import {ICapturePolicyStatus, PolicyStatus} from "../../../src/ICapturePolicyStatus.sol";
import {IVerifierRegistry, VerifierEntry} from "../../../src/IVerifierRegistry.sol";
import {ProofCheck, ProofStatus} from "../../../src/ProofCheck.sol";

/// @title RecordedProofPolicy (PROTOTYPE, not for deployment)
/// @notice The proof policy of the `auth-capture` profile with hash-only `policyData`: the proof is
/// checked once, in a transaction of its own, and the policy hook reads the recorded result by hash.
///
/// - `recordCheck(verifierId, inputCommitment, output, proof)`, open to anyone, runs the proof check
///   and stores `Valid` or `Invalid` under `recordKey(verifierId, inputCommitment, keccak256(abi.encode(
///   output, proof)))`. A check that cannot run (`Unverifiable`) stores nothing, so the same proof can
///   be presented again once it can be checked. A stored result never changes: the check is
///   deterministic for a registered entry, whose code cannot change.
/// - The hooks take `policyData = abi.encode(HashData)`: the salt's two addresses, the terms and the
///   hash of the output and proof. Terms that do not open the payment's salt are `Denied`; no record
///   is `VerifierUnavailable`, never `ProofInvalid`; a recorded `Invalid` is `ProofInvalid`; a recorded
///   `Valid` is `Authorized`.
///
/// The input commitment is in the key in the clear, beside the verifier id: the policy can tie a record
/// to the payment only through terms the payer's salt binds. A key that hid the commitment inside the
/// proof's hash would let a presenter pair a payment with another commitment's valid record.
///
/// The salt binding is `ProofCapturePolicy`'s, unchanged.
contract RecordedProofPolicy is ICapturePolicyStatus {
    bytes32 public constant SALT_BINDING_TYPEHASH =
        keccak256("x402AuthCaptureSaltBinding(address receiverAuthorizer,address policy,uint256 saltNonce)");
    bytes32 public constant PROOF_TERMS_TYPEHASH =
        keccak256("ProofGatedTerms(bytes32 verifierId,bytes32 inputCommitment)");

    uint8 internal constant NONE = 0;
    uint8 internal constant VALID = 1;
    uint8 internal constant INVALID = 2;

    IVerifierRegistry public immutable registry;

    /// @notice A recorded result by key: 0 none, 1 Valid, 2 Invalid.
    mapping(bytes32 key => uint8) public recorded;

    /// @notice What `policyData` carries: no proof, only the hash of what was checked.
    struct HashData {
        address receiverAuthorizer;
        address policy;
        bytes32 verifierId;
        bytes32 inputCommitment;
        bytes32 proofHash; // keccak256(abi.encode(output, proof))
    }

    /// @notice A result was recorded. The output travels here, not in the capture.
    event CheckRecorded(
        bytes32 indexed key, bytes32 indexed verifierId, bytes32 indexed inputCommitment, bool valid, bytes output
    );

    constructor(IVerifierRegistry registry_) {
        registry = registry_;
    }

    // ── Recording ───────────────────────────────────────────────────────────────────────────────

    /// @notice Check a proof and record whether it is valid. Anyone may call this. A check that cannot
    /// run records nothing and returns `Unverifiable`.
    function recordCheck(bytes32 verifierId, bytes32 inputCommitment, bytes calldata output, bytes calldata proof)
        external
        returns (ProofStatus)
    {
        bytes32 key = recordKey(verifierId, inputCommitment, keccak256(abi.encode(output, proof)));
        uint8 r = recorded[key];
        if (r == VALID) return ProofStatus.Valid;
        if (r == INVALID) return ProofStatus.Invalid;
        VerifierEntry memory e = registry.entry(verifierId);
        if (e.adapter == address(0)) return ProofStatus.Unverifiable;
        ProofStatus s = ProofCheck.checkOneInMemory(registry, verifierId, e, inputCommitment, output, proof);
        if (s == ProofStatus.Unverifiable) return s;
        bool valid = s == ProofStatus.Valid;
        recorded[key] = valid ? VALID : INVALID;
        emit CheckRecorded(key, verifierId, inputCommitment, valid, output);
        return s;
    }

    function recordKey(bytes32 verifierId, bytes32 inputCommitment, bytes32 proofHash) public pure returns (bytes32) {
        return keccak256(abi.encode(verifierId, inputCommitment, proofHash));
    }

    // ── Reason-returning checks ─────────────────────────────────────────────────────────────────

    function captureStatus(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        uint256,
        uint256,
        address,
        bytes calldata policyData
    ) external view returns (bytes32) {
        return _status(paymentInfo, policyData);
    }

    function chargeStatus(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        uint256,
        uint256,
        address,
        bytes calldata policyData
    ) external view returns (bytes32) {
        return _status(paymentInfo, policyData);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICapturePolicyStatus).interfaceId || interfaceId == 0x01ffc9a7;
    }

    // ── Terms, as ProofCapturePolicy binds them ─────────────────────────────────────────────────

    function saltNonce(bytes32 verifierId, bytes32 inputCommitment) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(PROOF_TERMS_TYPEHASH, verifierId, inputCommitment)));
    }

    function boundSalt(address receiverAuthorizer, address policy, bytes32 verifierId, bytes32 inputCommitment)
        public
        pure
        returns (uint256)
    {
        return uint256(
            keccak256(
                abi.encode(SALT_BINDING_TYPEHASH, receiverAuthorizer, policy, saltNonce(verifierId, inputCommitment))
            )
        );
    }

    function _status(IAuthCaptureEscrow.PaymentInfo calldata paymentInfo, bytes calldata policyData)
        private
        view
        returns (bytes32)
    {
        HashData memory d = abi.decode(policyData, (HashData));
        if (d.policy != address(0) && d.policy != address(this)) return PolicyStatus.DENIED;
        if (paymentInfo.salt != boundSalt(d.receiverAuthorizer, d.policy, d.verifierId, d.inputCommitment)) {
            return PolicyStatus.DENIED;
        }
        uint8 r = recorded[recordKey(d.verifierId, d.inputCommitment, d.proofHash)];
        if (r == VALID) return PolicyStatus.AUTHORIZED;
        if (r == INVALID) return PolicyStatus.PROOF_INVALID;
        return PolicyStatus.VERIFIER_UNAVAILABLE;
    }
}
