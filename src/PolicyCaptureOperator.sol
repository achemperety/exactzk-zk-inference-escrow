// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAuthCaptureEscrow} from "./IAuthCaptureEscrow.sol";
import {ICapturePolicyStatus, PolicyStatus} from "./ICapturePolicyStatus.sol";

/// @title PolicyCaptureOperator
/// @notice A `"custom"` operator for x402's `auth-capture` scheme on EVM that pays held funds out only
/// when one fixed, read-only policy answers `PolicyStatus.AUTHORIZED`. It is the route a
/// reason-returning policy can take today, before the reserved `"policy"` type exists: the policy is
/// fixed at deployment, and the payer's signature commits to it through `PaymentInfo.operator`.
///
/// - `authorize`: the escrow's own collect call, open to anyone. It collects the full maximum.
/// - `charge`: always reverts; the escrow's `charge` must not be reachable without the policy.
/// - `captureWithPolicy`, `chargeWithPolicy`: anyone may call them with the policy's data. The whole
///   held (or authorized) amount goes to the receiver, less the payer's minimum fee.
/// - `voidByReceiver`: the receiver may give the hold back before the capture deadline.
///
/// Any answer other than `AUTHORIZED` reverts with `PolicyRefused(status)` and changes nothing: the
/// hold stays capturable until its capture deadline, and the payer reclaims it from the escrow after.
/// The operator does not interpret the word; the scheme text maps it to an `errorReason`.
/// No owner, no fee of its own, no storage.
contract PolicyCaptureOperator {
    uint256 internal constant MAX_FEE_BPS = 10_000;

    IAuthCaptureEscrow public immutable escrow;
    ICapturePolicyStatus public immutable policy;

    event CapturedWithPolicy(bytes32 indexed paymentInfoHash, uint256 amount, bytes32 policyDataHash);
    event ChargedWithPolicy(bytes32 indexed paymentInfoHash, uint256 amount, bytes32 policyDataHash);
    event VoidedByReceiver(bytes32 indexed paymentInfoHash);

    /// @notice The policy answered `status`, which is not `AUTHORIZED`.
    error PolicyRefused(bytes32 status);
    error NotReceiver();
    /// @notice `authorize` must collect the full maximum: the payer's authorization is single-use.
    error PartialAuthorization(uint256 amount, uint256 maxAmount);
    /// @notice The escrow's `charge` is not available here; use `chargeWithPolicy`.
    error PolicyRequired();

    constructor(IAuthCaptureEscrow escrow_, ICapturePolicyStatus policy_) {
        escrow = escrow_;
        policy = policy_;
    }

    // ── Collect, with the escrow's ABI ──────────────────────────────────────────────────────────

    /// @notice Place the hold the payer authorized. Anyone may call this.
    function authorize(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        uint256 amount,
        address tokenCollector,
        bytes calldata collectorData
    ) external {
        if (amount != paymentInfo.maxAmount) {
            revert PartialAuthorization(amount, paymentInfo.maxAmount);
        }
        escrow.authorize(paymentInfo, amount, tokenCollector, collectorData);
    }

    /// @notice Not available: paying out needs the policy. Reverts.
    function charge(IAuthCaptureEscrow.PaymentInfo calldata, uint256, address, bytes calldata, uint256, address)
        external
        pure
    {
        revert PolicyRequired();
    }

    // ── Pay out when the policy authorizes ──────────────────────────────────────────────────────

    /// @notice Capture the whole hold for the receiver if the policy authorizes it. Anyone may call this.
    function captureWithPolicy(IAuthCaptureEscrow.PaymentInfo calldata paymentInfo, bytes calldata policyData)
        external
    {
        bytes32 paymentInfoHash = escrow.getHash(paymentInfo);
        (, uint120 capturable,) = escrow.paymentState(paymentInfoHash);
        uint256 fee = _minFee(paymentInfo, capturable);
        _require(policy.captureStatus(paymentInfo, capturable, fee, paymentInfo.feeReceiver, policyData));
        escrow.capture(paymentInfo, capturable, fee, paymentInfo.feeReceiver);
        emit CapturedWithPolicy(paymentInfoHash, capturable, keccak256(policyData));
    }

    /// @notice Collect and pay out in one step if the policy authorizes it. Anyone may call this.
    function chargeWithPolicy(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        address tokenCollector,
        bytes calldata collectorData,
        bytes calldata policyData
    ) external {
        uint256 amount = paymentInfo.maxAmount;
        uint256 fee = _minFee(paymentInfo, amount);
        _require(policy.chargeStatus(paymentInfo, amount, fee, paymentInfo.feeReceiver, policyData));
        escrow.charge(paymentInfo, amount, tokenCollector, collectorData, fee, paymentInfo.feeReceiver);
        emit ChargedWithPolicy(escrow.getHash(paymentInfo), amount, keccak256(policyData));
    }

    /// @notice The receiver gives the hold back to the payer, before the capture deadline.
    function voidByReceiver(IAuthCaptureEscrow.PaymentInfo calldata paymentInfo) external {
        if (msg.sender != paymentInfo.receiver) revert NotReceiver();
        escrow.void(paymentInfo);
        emit VoidedByReceiver(escrow.getHash(paymentInfo));
    }

    // ── Internals ───────────────────────────────────────────────────────────────────────────────

    function _require(bytes32 status) private pure {
        if (status != PolicyStatus.AUTHORIZED) revert PolicyRefused(status);
    }

    /// @dev The lowest fee the escrow accepts: the payer's minimum. A caller cannot choose more.
    function _minFee(IAuthCaptureEscrow.PaymentInfo calldata paymentInfo, uint256 amount)
        private
        pure
        returns (uint256)
    {
        return amount * paymentInfo.minFeeBps / MAX_FEE_BPS;
    }
}
