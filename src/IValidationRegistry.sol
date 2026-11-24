// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IValidationRegistry
/// @notice The part of an ERC-8004 Validation Registry that `ProofValidator8004` calls. Both
/// functions are in the ERC's text with these signatures.
interface IValidationRegistry {
    /// @dev The ERC: "MUST be called by the validatorAddress specified in the original request."
    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external;

    function getValidationStatus(bytes32 requestHash)
        external
        view
        returns (
            address validatorAddress,
            uint256 agentId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        );
}
