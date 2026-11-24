// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The part of ERC-3009 that settlement uses: a transfer the payer authorised by
/// signature, which only the recipient may submit.
/// @dev This is the overload that takes the signature as bytes. USDC (FiatToken v2.2) checks it
/// with ECDSA when the payer has no code and with ERC-1271 when the payer is a contract, so a
/// smart-account payer needs nothing from the settlement contract.
interface IERC3009 {
    /// @dev Reverts unless `msg.sender == to`, `validAfter < block.timestamp < validBefore`,
    /// `nonce` has not been used by `from`, and `signature` is `from`'s signature over the
    /// ERC-712 `ReceiveWithAuthorization` message in the token's domain. Marks `nonce` used.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}
