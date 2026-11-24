// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ClaimDigest} from "./ClaimDigest.sol";
import {IAgenticCommerce} from "./IAgenticCommerce.sol";
import {IVerifierRegistry, VerifierEntry} from "./IVerifierRegistry.sol";
import {ProofCheck, ProofStatus} from "./ProofCheck.sol";

/// @title ProofEvaluator8183
/// @notice An ERC-8183 evaluator that completes a job when a valid proof is presented, and never
/// rejects one. The job's client names the terms first: the registry entry whose circuit must
/// produce the proof and the commitment to the input. Once the provider has submitted, anyone may
/// present a proof that this circuit maps that input to some output; if it verifies before the job
/// expires, the job is completed with the claim's digest as its reason and the output is published
/// in `Evaluated`.
/// @dev Works with the ERC's reference job contract as published (no hook):
/// - The evaluator cannot see what the provider submitted (the reference contract does not store
///   the deliverable), so "completed" means "a valid proof for the agreed circuit and input", not
///   "the proven output equals the deliverable". A job can therefore never fail through this
///   evaluator; it ends completed, forfeited by the provider, or expired.
/// - A proof that does not verify, or a verifier that cannot be run, reverts and changes nothing.
///   Anyone can submit a bad proof, so a bad proof must not be able to end a job.
/// - A proof is refused at and after `expiredAt`, when the job contract starts accepting
///   `claimRefund`, so completion and refund can never both be available.
/// - The reference job contract may pay its evaluator a fee on completion. Whatever this contract
///   receives during `complete` goes to the job's provider in the same call: the contract keeps no
///   job's funds, has no owner and charges nothing.
/// - Terms are kept per job contract and job id. A provider should read `terms` before working.
contract ProofEvaluator8183 {
    using SafeERC20 for IERC20;

    struct JobTerms {
        bytes32 verifierId; // the registry entry whose circuit must produce the proof
        bytes32 inputCommitment; // the proof's public commitment to the client's input
    }

    /// @notice The reason given to the job contract when a provider forfeits a job.
    bytes32 public constant FORFEITED = keccak256("ProofEvaluator8183.forfeited");

    IVerifierRegistry public immutable registry;

    mapping(address acp => mapping(uint256 jobId => JobTerms)) internal _terms;

    event TermsSet(address indexed acp, uint256 indexed jobId, bytes32 indexed verifierId, bytes32 inputCommitment);
    /// @notice A valid proof completed the job. `claimDigest` is the reason recorded on the job.
    event Evaluated(address indexed acp, uint256 indexed jobId, bytes32 indexed claimDigest, bytes output);
    event Forfeited(address indexed acp, uint256 indexed jobId);

    /// @notice The verifier ran and did not accept, or the output does not fit the entry.
    error ProofInvalid();
    /// @notice The terms name an unknown verifier, the supplied entry is not its registered entry,
    /// or the adapter or verifier no longer has the registered code.
    error VerifierUnavailable(bytes32 verifierId);
    error EmptyTerms();
    error TermsAlreadySet(address acp, uint256 jobId);
    error NoTerms(address acp, uint256 jobId);
    error NotClient();
    error NotProvider();
    /// @notice The job does not name this contract as its evaluator.
    error NotEvaluator();
    error JobNotOpen(IAgenticCommerce.JobStatus status);
    error JobNotSubmitted(IAgenticCommerce.JobStatus status);
    error JobExpired(uint256 expiredAt);

    constructor(IVerifierRegistry registry_) {
        registry = registry_;
    }

    /// @notice Name the circuit and the input commitment a job's proof must match. Only the job's
    /// client, only while the job is Open, only once, and only for a job whose evaluator is this
    /// contract.
    function setTerms(address acp, uint256 jobId, JobTerms calldata t) external {
        if (t.verifierId == bytes32(0)) revert EmptyTerms();
        JobTerms storage s = _terms[acp][jobId];
        if (s.verifierId != bytes32(0)) revert TermsAlreadySet(acp, jobId);

        IAgenticCommerce.Job memory job = IAgenticCommerce(acp).getJob(jobId);
        if (msg.sender != job.client) revert NotClient();
        if (job.status != IAgenticCommerce.JobStatus.Open) revert JobNotOpen(job.status);
        if (job.evaluator != address(this)) revert NotEvaluator();

        s.verifierId = t.verifierId;
        s.inputCommitment = t.inputCommitment;
        emit TermsSet(acp, jobId, t.verifierId, t.inputCommitment);
    }

    /// @notice Complete a submitted job with a valid proof. Anyone may call this.
    /// @param e The registered entry of the terms' verifier, supplied to save reading it from
    /// storage; it is checked against the registry's hash of the entry.
    /// @param output The circuit's public output, `e.outputSize` bytes.
    function evaluate(address acp, uint256 jobId, VerifierEntry calldata e, bytes calldata output, bytes calldata proof)
        external
    {
        JobTerms memory t = _terms[acp][jobId];
        if (t.verifierId == bytes32(0)) revert NoTerms(acp, jobId);

        IAgenticCommerce.Job memory job = IAgenticCommerce(acp).getJob(jobId);
        if (job.status != IAgenticCommerce.JobStatus.Submitted) revert JobNotSubmitted(job.status);
        if (block.timestamp >= job.expiredAt) revert JobExpired(job.expiredAt);

        ProofStatus status = ProofCheck.checkOne(registry, t.verifierId, e, t.inputCommitment, output, proof);
        if (status == ProofStatus.Unverifiable) revert VerifierUnavailable(t.verifierId);
        if (status != ProofStatus.Valid) revert ProofInvalid();

        bytes32 digest = ClaimDigest.compute(t.verifierId, t.inputCommitment, keccak256(output));

        // The fee, if the job contract pays one, is what arrives during `complete`.
        IERC20 token = IERC20(IAgenticCommerce(acp).paymentToken());
        uint256 before = token.balanceOf(address(this));
        IAgenticCommerce(acp).complete(jobId, digest, "");
        uint256 fee = token.balanceOf(address(this)) - before;
        if (fee != 0) token.safeTransfer(job.provider, fee);

        emit Evaluated(acp, jobId, digest, output);
    }

    /// @notice The provider gives the job up: the job contract rejects it and refunds the client.
    /// Only the job's provider. The job contract accepts this while the job is Funded or Submitted.
    function forfeit(address acp, uint256 jobId) external {
        IAgenticCommerce.Job memory job = IAgenticCommerce(acp).getJob(jobId);
        if (msg.sender != job.provider) revert NotProvider();
        IAgenticCommerce(acp).reject(jobId, FORFEITED, "");
        emit Forfeited(acp, jobId);
    }

    /// @notice The terms of a job; both fields are zero if none were set.
    function terms(address acp, uint256 jobId) external view returns (JobTerms memory) {
        return _terms[acp][jobId];
    }
}
