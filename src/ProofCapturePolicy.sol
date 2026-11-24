// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAuthCaptureEscrow} from "./IAuthCaptureEscrow.sol";
import {ICapturePolicyStatus, PolicyStatus} from "./ICapturePolicyStatus.sol";
import {IVerifierRegistry, VerifierEntry} from "./IVerifierRegistry.sol";
import {ProofCheck, ProofStatus} from "./ProofCheck.sol";

/// @title ProofCapturePolicy
/// @notice A read-only `auth-capture` policy whose condition is a proof: a capture or charge may
/// proceed only with a valid proof that the circuit of the payment's verifier maps the payment's
/// input commitment to some output.
///
/// The payment's terms reach the payer's signature through the client's contribution to the bound
/// salt: `saltNonce = uint256(keccak256(abi.encode(PROOF_TERMS_TYPEHASH, verifierId,
/// inputCommitment)))`, inside `salt = keccak256(abi.encode(SALT_BINDING_TYPEHASH, receiverAuthorizer,
/// policy, saltNonce))` as the scheme derives it. The receiver authorizer stays free to be a real
/// signer, which the reserved `"policy"` type requires. The input commitment carries the client's
/// fresh randomness, so the salt nonce is unique per payment without a further random value.
///
/// Answers, never reverts, for every outcome it can name:
/// - `DENIED`: `policyData` does not open the payment's salt to these terms.
/// - `VERIFIER_UNAVAILABLE`: unknown verifier, an entry that is not its registered entry, or code that
///   is not the registered code. Never reported as `PROOF_INVALID`.
/// - `PROOF_INVALID`: the verifier ran and did not accept, or the output does not fit the entry.
/// - `AUTHORIZED`: the verifier ran and accepted.
/// It reverts only when `policyData` is not an encoding of `ProofData`, and with
/// `InsufficientGasForVerifier` when the call cannot give the verifier its full allowance.
///
/// No owner, no storage. Usable today by a `"custom"` operator that consults it
/// (`PolicyCaptureOperator`); shaped for the reserved `"policy"` type.
contract ProofCapturePolicy is ICapturePolicyStatus {
    /// @notice The scheme's salt-binding tag (x402 `auth-capture` EVM binding, "Payment identity").
    bytes32 public constant SALT_BINDING_TYPEHASH =
        keccak256("x402AuthCaptureSaltBinding(address receiverAuthorizer,address policy,uint256 saltNonce)");

    /// @notice Tag of the terms a salt nonce is derived from.
    bytes32 public constant PROOF_TERMS_TYPEHASH =
        keccak256("ProofGatedTerms(bytes32 verifierId,bytes32 inputCommitment)");

    IVerifierRegistry public immutable registry;

    /// @notice What `policyData` carries: the two addresses the salt was bound with, the terms, and
    /// the proof.
    struct ProofData {
        address receiverAuthorizer; // `extra.receiverAuthorizer` of the payment
        address policy; // `extra.policy` of the payment: this contract (`"policy"`) or zero (`"custom"`)
        bytes32 verifierId;
        bytes32 inputCommitment;
        VerifierEntry entry; // the registered entry of `verifierId`
        bytes output; // the circuit's public output, `entry.outputSize` bytes
        bytes proof;
    }

    constructor(IVerifierRegistry registry_) {
        registry = registry_;
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

    // ── The reserved type's boolean hooks, for an operator that reads only those ────────────────

    function authorizeCapture(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        uint256,
        uint256,
        address,
        bytes calldata policyData
    ) external view returns (bool) {
        return _status(paymentInfo, policyData) == PolicyStatus.AUTHORIZED;
    }

    function authorizeCharge(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        uint256,
        uint256,
        address,
        bytes calldata policyData
    ) external view returns (bool) {
        return _status(paymentInfo, policyData) == PolicyStatus.AUTHORIZED;
    }

    /// @notice ERC-165: this interface and ERC-165 itself.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICapturePolicyStatus).interfaceId || interfaceId == 0x01ffc9a7;
    }

    // ── Terms ───────────────────────────────────────────────────────────────────────────────────

    /// @notice The `saltNonce` a client contributes for these terms.
    function saltNonce(bytes32 verifierId, bytes32 inputCommitment) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(PROOF_TERMS_TYPEHASH, verifierId, inputCommitment)));
    }

    /// @notice The bound salt of a payment with these terms.
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

    // ── Internals ───────────────────────────────────────────────────────────────────────────────

    function _status(IAuthCaptureEscrow.PaymentInfo calldata paymentInfo, bytes calldata policyData)
        private
        view
        returns (bytes32)
    {
        ProofData memory d = abi.decode(policyData, (ProofData));
        if (d.policy != address(0) && d.policy != address(this)) return PolicyStatus.DENIED;
        if (paymentInfo.salt != boundSalt(d.receiverAuthorizer, d.policy, d.verifierId, d.inputCommitment)) {
            return PolicyStatus.DENIED;
        }
        ProofStatus s =
            ProofCheck.checkOneInMemory(registry, d.verifierId, d.entry, d.inputCommitment, d.output, d.proof);
        if (s == ProofStatus.Valid) return PolicyStatus.AUTHORIZED;
        if (s == ProofStatus.Unverifiable) return PolicyStatus.VERIFIER_UNAVAILABLE;
        return PolicyStatus.PROOF_INVALID;
    }
}
