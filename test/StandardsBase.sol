// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProofCoreBase} from "./ProofCoreBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReferenceDeploy} from "./external/ReferenceDeploy.sol";
import {AgenticCommerce} from "./external/erc8183/AgenticCommerce.sol";
import {IdentityRegistryUpgradeable} from "lib/erc-8004-contracts/contracts/IdentityRegistryUpgradeable.sol";
import {ValidationRegistryUpgradeable} from "lib/erc-8004-contracts/contracts/ValidationRegistryUpgradeable.sol";
import {ProofEvaluator8183} from "../src/ProofEvaluator8183.sol";
import {ProofValidator8004} from "../src/ProofValidator8004.sol";
import {IValidationRegistry} from "../src/IValidationRegistry.sol";

/// Shared setup for the ERC-8183 evaluator and the ERC-8004 validator: the proof-system core from
/// `ProofCoreBase` (the real solo proof), the third-party reference contracts deployed from source
/// (test/external/README.md), our two contracts, and the people involved.
abstract contract StandardsBase is ProofCoreBase {
    uint256 internal constant T0 = 1_750_000_000;
    uint256 internal constant BUDGET = 1_000_000; // 1 USDC
    uint256 internal constant EXPIRED_AT = T0 + 1 days;
    uint256 internal constant EVALUATOR_FEE_BP = 500; // 5 %, paid by the job contract to its evaluator

    MockERC20 internal token;
    AgenticCommerce internal acp;
    ProofEvaluator8183 internal evaluator;

    IdentityRegistryUpgradeable internal identity;
    ValidationRegistryUpgradeable internal validation;
    ProofValidator8004 internal validator;

    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal treasury = makeAddr("treasury");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");
    address internal agentOwner = makeAddr("agent owner");
    address internal otherOwner = makeAddr("other agent owner");

    bytes32 internal commitment; // the solo proof's input commitment
    bytes internal output; // the solo proof's 320-byte output
    bytes internal proof;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(T0);

        token = new MockERC20();
        acp = ReferenceDeploy.agenticCommerce(address(token), treasury);
        acp.setEvaluatorFee(EVALUATOR_FEE_BP);
        evaluator = new ProofEvaluator8183(registry);

        (identity, validation) = ReferenceDeploy.erc8004();
        validator = new ProofValidator8004(registry, IValidationRegistry(address(validation)));

        token.mint(client, 10 * BUDGET);
        vm.prank(client);
        token.approve(address(acp), type(uint256).max);

        bytes32[] memory c;
        (c, output, proof) = _solo();
        commitment = c[0];
    }

    // ── ERC-8183 ────────────────────────────────────────────────────────────────────────────────

    function _terms() internal view returns (ProofEvaluator8183.JobTerms memory) {
        return ProofEvaluator8183.JobTerms({verifierId: soloId, inputCommitment: commitment});
    }

    /// A job evaluated by `evaluator`, with its budget set by the provider (the reference contract
    /// lets only the provider set it), still Open.
    function _openJob(AgenticCommerce jobs) internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = jobs.createJob(provider, address(evaluator), EXPIRED_AT, "classify one image", address(0));
        vm.prank(provider);
        jobs.setBudget(jobId, BUDGET, "");
    }

    /// Open, terms set by the client, funded.
    function _fundedJob() internal returns (uint256 jobId) {
        jobId = _openJob(acp);
        vm.prank(client);
        evaluator.setTerms(address(acp), jobId, _terms());
        vm.prank(client);
        acp.fund(jobId, "");
    }

    /// Funded and submitted by the provider, with the hash of the output as the deliverable.
    function _submittedJob() internal returns (uint256 jobId) {
        jobId = _fundedJob();
        vm.prank(provider);
        acp.submit(jobId, keccak256(output), "");
    }

    function _status(uint256 jobId) internal view returns (AgenticCommerce.JobStatus) {
        return acp.getJob(jobId).status;
    }

    function _assertJob(uint256 jobId, AgenticCommerce.JobStatus expected) internal view {
        assertEq(uint8(_status(jobId)), uint8(expected), "job status");
    }

    /// keccak256(abi.encode(chainid, verifierId, inputCommitment, keccak256(output))), written out.
    function _digest(bytes32 verifierId, bytes32 inputCommitment, bytes memory out) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, verifierId, inputCommitment, keccak256(out)));
    }

    // ── ERC-8004 ────────────────────────────────────────────────────────────────────────────────

    /// Register an agent in the Identity Registry; the caller becomes its owner.
    function _agent(address owner) internal returns (uint256 agentId) {
        vm.prank(owner);
        agentId = identity.register("https://agent.example/registration.json");
    }

    /// Open a validation request with `validator`, as the agent's owner, and return its hash.
    function _request(address owner, uint256 agentId, bytes32 claimedOutputHash, bytes32 salt)
        internal
        returns (bytes32 requestHash)
    {
        requestHash = validator.requestHashOf(agentId, soloId, commitment, claimedOutputHash, salt);
        vm.prank(owner);
        validation.validationRequest(address(validator), agentId, "ipfs://request", requestHash);
    }

    function _respond(uint256 agentId, bytes32 claimedOutputHash, bytes32 salt) internal {
        validator.respond(agentId, soloId, commitment, claimedOutputHash, salt, soloEntry, output, proof);
    }
}
