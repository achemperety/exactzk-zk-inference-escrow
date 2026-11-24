// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgenticCommerce
/// @notice The part of an ERC-8183 job contract that `ProofEvaluator8183` calls, with the ABI of the
/// ERC's reference implementation (`AgenticCommerce`, given in the ERC's text).
/// @dev The ERC specifies `complete` and `reject` but no way to read a job. `getJob`, `paymentToken`
/// and the layout of `Job` are the reference implementation's; a job contract with a different
/// getter needs a different evaluator.
interface IAgenticCommerce {
    enum JobStatus {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    struct Job {
        uint256 id;
        address client;
        address provider;
        address evaluator;
        string description;
        uint256 budget;
        uint256 expiredAt;
        JobStatus status;
        address hook;
    }

    function getJob(uint256 jobId) external view returns (Job memory);

    /// @dev The reference implementation declares it as `IERC20 public paymentToken`.
    function paymentToken() external view returns (address);

    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) external;

    function reject(uint256 jobId, bytes32 reason, bytes calldata optParams) external;
}
