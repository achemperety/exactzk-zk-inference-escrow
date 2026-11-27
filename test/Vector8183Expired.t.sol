// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProofCoreBase} from "./ProofCoreBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {AgenticCommerce} from "./external/erc8183/AgenticCommerce.sol";
import {ProofEvaluator8183} from "../src/ProofEvaluator8183.sol";
import {Vector8183Expired} from "../script/Vector8183Expired.s.sol";

/// The vector script against local copies: test USDC at the testnet address, a local evaluator on
/// the local registry with the solo entry.
contract Vector8183ExpiredHarness is Vector8183Expired {
    Target internal target;

    function expect(Target memory t) external {
        target = t;
    }

    function _chain() internal view override returns (Target memory) {
        return target;
    }
}

contract Vector8183ExpiredTest is ProofCoreBase {
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    uint256 internal constant FUNDER_KEY = uint256(keccak256("vector funder"));
    uint256 internal constant CLIENT_KEY = uint256(keccak256("vector client"));
    uint256 internal constant PROVIDER_KEY = uint256(keccak256("vector provider"));

    Vector8183ExpiredHarness internal script;
    ProofEvaluator8183 internal evaluator;
    address internal funder = vm.addr(FUNDER_KEY);
    address internal client = vm.addr(CLIENT_KEY);
    address internal provider = vm.addr(PROVIDER_KEY);

    function setUp() public override {
        super.setUp();
        vm.chainId(84532);
        deployCodeTo("MockERC20.sol:MockERC20", USDC);
        evaluator = new ProofEvaluator8183(registry);
        script = new Vector8183ExpiredHarness();
        script.expect(Vector8183Expired.Target(84532, USDC, evaluator, soloId));
        vm.setEnv("VECTOR_FUNDER_KEY", vm.toString(bytes32(FUNDER_KEY)));
        vm.setEnv("VECTOR_CLIENT_KEY", vm.toString(bytes32(CLIENT_KEY)));
        vm.setEnv("VECTOR_PROVIDER_KEY", vm.toString(bytes32(PROVIDER_KEY)));
        vm.deal(funder, 1 ether);
        MockERC20(USDC).mint(funder, 10_000);
    }

    function test_the_job_expires_after_a_delivery_with_no_verdict() public {
        script.fundRoles();
        assertEq(MockERC20(USDC).balanceOf(client), 10_000, "client holds the budget");
        assertGt(client.balance, 0, "client gas");
        assertGt(provider.balance, 0, "provider gas");

        AgenticCommerce acp = script.deployJobContract();
        assertFalse(acp.hasRole(acp.DEFAULT_ADMIN_ROLE(), funder), "no admin left");

        uint256 jobId = script.openAndSubmit(acp);
        AgenticCommerce.Job memory job = acp.getJob(jobId);
        assertEq(uint8(job.status), uint8(AgenticCommerce.JobStatus.Submitted), "Submitted");
        assertEq(MockERC20(USDC).balanceOf(address(acp)), 10_000, "escrowed");
        assertEq(evaluator.terms(address(acp), jobId).verifierId, soloId, "terms");

        vm.expectRevert(bytes("preflight: not expired yet"));
        script.refund(acp, jobId);

        vm.warp(job.expiredAt);
        script.refund(acp, jobId);
        assertEq(uint8(acp.getJob(jobId).status), uint8(AgenticCommerce.JobStatus.Expired), "Expired");
        assertEq(MockERC20(USDC).balanceOf(client), 10_000, "refunded");
        assertEq(MockERC20(USDC).balanceOf(address(acp)), 0, "nothing left in the job contract");
    }

    /// Before expiry the stored proof would complete the job: the vector's job lapses only because
    /// nobody presented it.
    function test_before_expiry_the_stored_proof_would_have_completed_it() public {
        script.fundRoles();
        AgenticCommerce acp = script.deployJobContract();
        uint256 jobId = script.openAndSubmit(acp);
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        assertEq(evaluator.terms(address(acp), jobId).inputCommitment, c[0], "the stored proof's commitment");
        evaluator.evaluate(address(acp), jobId, registry.entry(soloId), o, p);
        assertEq(uint8(acp.getJob(jobId).status), uint8(AgenticCommerce.JobStatus.Completed), "Completed");
    }
}
