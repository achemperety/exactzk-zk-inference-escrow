// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAuthCaptureEscrow} from "./IAuthCaptureEscrow.sol";

/// @title PolicyStatus
/// @notice The words a reason-returning `auth-capture` policy answers with, defined once so that
/// policies do not invent their own vocabulary. Each is a short ASCII name, left-aligned in 32 bytes.
/// The zero word is none of them, so a contract that answers with zeros never reads as `AUTHORIZED`.
///
/// | Word                   | Meaning                                                    | `errorReason`                                    |
/// |------------------------|------------------------------------------------------------|--------------------------------------------------|
/// | `AUTHORIZED`           | The condition holds; the operation may proceed             | none                                             |
/// | `PROOF_INVALID`        | The proof was checked and rejected                         | `invalid_auth_capture_evm_proof_invalid`         |
/// | `VERIFIER_UNAVAILABLE` | The proof could not be checked; nothing was decided        | `invalid_auth_capture_evm_verifier_unavailable`  |
/// | `DENIED`, or any other | The policy refuses for a reason that is not about a proof  | `invalid_auth_capture_evm_policy_denied`         |
library PolicyStatus {
    bytes32 internal constant AUTHORIZED = "Authorized";
    bytes32 internal constant PROOF_INVALID = "ProofInvalid";
    bytes32 internal constant VERIFIER_UNAVAILABLE = "VerifierUnavailable";
    bytes32 internal constant DENIED = "Denied";
}

/// @title ICapturePolicyStatus
/// @notice Read-only checks an `auth-capture` operator consults before it captures or charges. They
/// have the parameters of the reserved `"policy"` type's `ICaptureAuthorizer` hooks and answer with a
/// `PolicyStatus` word instead of a boolean, so that "the proof is invalid" and "the proof could not be
/// checked" stay two outcomes.
/// @dev A refusal refuses this attempt only. It never ends the authorization: a hold stays capturable
/// until its capture deadline and reclaimable by the payer from then on, as the escrow defines.
interface ICapturePolicyStatus {
    /// @param policyData What the policy needs to decide, ABI-encoded; for a proof policy, the terms
    /// and the proof.
    function captureStatus(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        uint256 amount,
        uint256 feeAmount,
        address feeReceiver,
        bytes calldata policyData
    ) external view returns (bytes32 status);

    function chargeStatus(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        uint256 amount,
        uint256 feeAmount,
        address feeReceiver,
        bytes calldata policyData
    ) external view returns (bytes32 status);
}
