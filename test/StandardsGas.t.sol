// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GasMeter} from "./GasMeter.sol";
import {StandardsBase} from "./StandardsBase.sol";
import {AgenticCommerce} from "./external/erc8183/AgenticCommerce.sol";
import {ProofEvaluator8183} from "../src/ProofEvaluator8183.sol";
import {ProofValidator8004} from "../src/ProofValidator8004.sol";

/// Gas of the ERC-8183 evaluator and the ERC-8004 validator with the real solo proof, under the
/// Osaka schedule, against the reference job contract and the reference registries built here
/// (test/external/README.md; their gas depends on how they are compiled, see the measurement
/// notes). `GasMeter` explains how a transaction's gas is rebuilt.
///
/// Each measured call is the first thing its test does; jobs, requests and balances are made in
/// `setUp`. "Steady": the job contract holds other jobs' budgets and the provider has been paid
/// before. "First": the job is the only one held and the provider has never been paid.
abstract contract StandardsGasBase is StandardsBase, GasMeter {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Read here, in `setUp`: reading a proxy's slot in the test body would leave the proxy's account
    // warm for the measured call, which `vm.cool` does not undo (2,500 gas low).
    address internal acpImpl;
    address internal validationImpl;

    function setUp() public virtual override {
        super.setUp();
        acpImpl = address(uint160(uint256(vm.load(address(acp), IMPLEMENTATION_SLOT))));
        validationImpl = address(uint160(uint256(vm.load(address(validation), IMPLEMENTATION_SLOT))));
    }

    function _cold8183() internal view returns (address[] memory a) {
        a = new address[](10);
        (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9]) =
        (
            address(evaluator),
            address(acp),
            acpImpl,
            address(token),
            address(registry),
            address(adapter),
            SOLO,
            provider,
            client,
            treasury
        );
    }

    function _cold8004() internal view returns (address[] memory a) {
        a = new address[](6);
        (a[0], a[1], a[2], a[3], a[4], a[5]) =
        (address(validator), address(validation), validationImpl, address(registry), address(adapter), SOLO);
    }

    function _evaluateTx(uint256 jobId) internal returns (TxGas memory) {
        bytes memory data = abi.encodeCall(ProofEvaluator8183.evaluate, (address(acp), jobId, soloEntry, output, proof));
        return _measure(relayer, address(evaluator), data, _cold8183());
    }
}

/// Terms, forfeit and a completion while the job contract holds other jobs and the provider has
/// been paid before.
contract EvaluatorGasSteadyTest is StandardsGasBase {
    uint256 internal openJob;
    uint256 internal submittedJob;

    function setUp() public override {
        super.setUp();
        _submittedJob(); // another job's budget stays in the job contract
        token.mint(provider, 1);
        openJob = _openJob(acp);
        submittedJob = _submittedJob();
    }

    function test_gas_setTerms() public {
        bytes memory data = abi.encodeCall(ProofEvaluator8183.setTerms, (address(acp), openJob, _terms()));
        TxGas memory g = _measure(client, address(evaluator), data, _cold8183());
        _log("setTerms", g);
        assertEq(evaluator.terms(address(acp), openJob).verifierId, soloId, "the measured call set the terms");
        assertLe(g.total, 97_600, "pin: measured 97,317");
    }

    function test_gas_evaluate_completes_with_the_evaluator_fee_steady() public {
        TxGas memory g = _evaluateTx(submittedJob);
        _log("evaluate, evaluator fee forwarded, steady", g);
        assertEq(token.balanceOf(provider), BUDGET + 1, "the measured call paid");
        assertLe(g.total, 769_400, "pin: measured 769,085");
    }

    function test_gas_forfeit_steady() public {
        bytes memory data = abi.encodeCall(ProofEvaluator8183.forfeit, (address(acp), submittedJob));
        TxGas memory g = _measure(provider, address(evaluator), data, _cold8183());
        _log("forfeit, steady", g);
        assertEq(uint8(_status(submittedJob)), uint8(AgenticCommerce.JobStatus.Rejected), "the measured call rejected");
        assertLe(g.total, 79_100, "pin: measured 78,840");
    }
}

/// The same completion without an evaluator fee: nothing for the evaluator to forward.
contract EvaluatorGasNoFeeTest is StandardsGasBase {
    uint256 internal submittedJob;

    function setUp() public override {
        super.setUp();
        acp.setEvaluatorFee(0);
        _submittedJob();
        token.mint(provider, 1);
        submittedJob = _submittedJob();
    }

    function test_gas_evaluate_completes_without_a_fee_steady() public {
        TxGas memory g = _evaluateTx(submittedJob);
        _log("evaluate, no evaluator fee, steady", g);
        assertEq(token.balanceOf(provider), BUDGET + 1, "the measured call paid");
        assertLe(g.total, 760_800, "pin: measured 760,498");
    }
}

/// The only job held, and the provider's first payment.
contract EvaluatorGasFirstTest is StandardsGasBase {
    uint256 internal submittedJob;

    function setUp() public override {
        super.setUp();
        submittedJob = _submittedJob();
    }

    function test_gas_evaluate_completes_with_the_evaluator_fee_first_payment() public {
        TxGas memory g = _evaluateTx(submittedJob);
        _log("evaluate, evaluator fee forwarded, first payment, last job held", g);
        assertEq(token.balanceOf(provider), BUDGET, "the measured call paid");
        assertLe(g.total, 781_700, "pin: measured 781,385");
    }
}

/// Answers to requests opened in `setUp`: one whose claim the proof matches, one it contradicts,
/// one already answered once.
contract ValidatorGasTest is StandardsGasBase {
    uint256 internal agentId;
    bytes32 internal outputHash;
    bytes32 internal wrongHash = keccak256("another output");

    function setUp() public override {
        super.setUp();
        _agent(otherOwner);
        agentId = _agent(agentOwner);
        outputHash = keccak256(output);
        _request(agentOwner, agentId, outputHash, "passed");
        _request(agentOwner, agentId, wrongHash, "contradicted");
        _request(agentOwner, agentId, outputHash, "again");
        _respond(agentId, outputHash, "again");
        vm.warp(block.timestamp + 60);
    }

    function _respondTx(bytes32 claimed, bytes32 salt) internal returns (TxGas memory) {
        bytes memory data = abi.encodeCall(
            ProofValidator8004.respond, (agentId, soloId, commitment, claimed, salt, soloEntry, output, proof)
        );
        return _measure(relayer, address(validator), data, _cold8004());
    }

    function test_gas_respond_100() public {
        TxGas memory g = _respondTx(outputHash, "passed");
        _log("respond, 100, first answer", g);
        (,, uint8 r,,,) =
            validation.getValidationStatus(validator.requestHashOf(agentId, soloId, commitment, outputHash, "passed"));
        assertEq(r, 100, "the measured call answered");
        assertLe(g.total, 804_100, "pin: measured 803,767");
    }

    function test_gas_respond_0() public {
        TxGas memory g = _respondTx(wrongHash, "contradicted");
        _log("respond, 0, first answer", g);
        (,,, bytes32 rh,,) = validation.getValidationStatus(
            validator.requestHashOf(agentId, soloId, commitment, wrongHash, "contradicted")
        );
        assertTrue(rh != bytes32(0), "the measured call answered");
        assertLe(g.total, 784_200, "pin: measured 783,939");
    }

    function test_gas_respond_100_again() public {
        TxGas memory g = _respondTx(outputHash, "again");
        _log("respond, 100, answered before", g);
        (,, uint8 r,,, uint256 t) =
            validation.getValidationStatus(validator.requestHashOf(agentId, soloId, commitment, outputHash, "again"));
        assertEq(r, 100, "answered 100");
        assertEq(t, block.timestamp, "the measured call answered again");
        assertLe(g.total, 724_500, "pin: measured 724,184");
    }
}
