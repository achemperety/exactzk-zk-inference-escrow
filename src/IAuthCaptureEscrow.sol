// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAuthCaptureEscrow
/// @notice The part of the `AuthCaptureEscrow` of base/commerce-payments (v1.1.0) that
/// `AuthCaptureProofOperator` calls: the escrow behind x402's `auth-capture` scheme on EVM.
/// @dev `PaymentInfo` must keep the escrow's field order and types: its EIP-712 hash is the payment's
/// identity, and the payer's token authorization commits to it.
interface IAuthCaptureEscrow {
    struct PaymentInfo {
        address operator;
        address payer;
        address receiver;
        address token;
        uint120 maxAmount;
        uint48 preApprovalExpiry;
        uint48 authorizationExpiry;
        uint48 refundExpiry;
        uint16 minFeeBps;
        uint16 maxFeeBps;
        address feeReceiver;
        uint256 salt;
    }

    function authorize(
        PaymentInfo calldata paymentInfo,
        uint256 amount,
        address tokenCollector,
        bytes calldata collectorData
    ) external;

    function charge(
        PaymentInfo calldata paymentInfo,
        uint256 amount,
        address tokenCollector,
        bytes calldata collectorData,
        uint256 feeAmount,
        address feeReceiver
    ) external;

    function capture(PaymentInfo calldata paymentInfo, uint256 amount, uint256 feeAmount, address feeReceiver) external;

    function void(PaymentInfo calldata paymentInfo) external;

    function getHash(PaymentInfo calldata paymentInfo) external view returns (bytes32);

    function paymentState(bytes32 paymentInfoHash)
        external
        view
        returns (bool hasCollectedPayment, uint120 capturableAmount, uint120 refundableAmount);
}
