// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StandardsBase} from "./StandardsBase.sol";
import {ReferenceDeploy} from "./external/ReferenceDeploy.sol";
import {AgenticCommerce} from "./external/erc8183/AgenticCommerce.sol";
import {FixturesK8} from "./fixtures/FixturesK8.sol";
import {ProofEvaluator8183} from "../src/ProofEvaluator8183.sol";
import {IAgenticCommerce} from "../src/IAgenticCommerce.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";

/// `ProofEvaluator8183` against the ERC's reference job contract (`AgenticCommerce`, built from the
/// ERC's text; test/external/README.md), with the real solo proof throughout.
contract ProofEvaluator8183Test is StandardsBase {
    uint256 internal constant FEE = BUDGET * EVALUATOR_FEE_BP / 10_000;

    function _evaluate(uint256 jobId, bytes memory out, bytes memory prf) internal {
        evaluator.evaluate(address(acp), jobId, soloEntry, out, prf);
    }

    function _flipByte(bytes memory data, uint256 index) internal pure returns (bytes memory copy) {
        copy = bytes.concat(data);
        copy[index] = bytes1(uint8(copy[index]) ^ 0x01);
    }

    function _assertUnchanged(uint256 jobId) internal view {
        _assertJob(jobId, AgenticCommerce.JobStatus.Submitted);
        assertEq(token.balanceOf(address(acp)), BUDGET, "escrow untouched");
        assertEq(token.balanceOf(provider), 0, "provider unpaid");
        assertEq(token.balanceOf(client), 9 * BUDGET, "client not refunded");
    }

    // ── Acceptance: a valid proof completes the job ─────────────────────────────────────────────

    function test_a_valid_proof_completes_the_job_and_pays_the_provider_with_the_fee() public {
        uint256 jobId = _submittedJob();
        bytes32 digest = _digest(soloId, commitment, output);

        vm.expectEmit(address(acp));
        emit AgenticCommerce.EvaluatorFeePaid(jobId, address(evaluator), FEE);
        vm.expectEmit(address(acp));
        emit AgenticCommerce.JobCompleted(jobId, address(evaluator), digest);
        vm.expectEmit(address(acp));
        emit AgenticCommerce.PaymentReleased(jobId, provider, BUDGET - FEE);
        vm.expectEmit(address(evaluator));
        emit ProofEvaluator8183.Evaluated(address(acp), jobId, digest, output);
        vm.prank(relayer);
        _evaluate(jobId, output, proof);

        _assertJob(jobId, AgenticCommerce.JobStatus.Completed);
        assertEq(token.balanceOf(provider), BUDGET, "provider: the budget, the evaluator fee included");
        assertEq(token.balanceOf(address(evaluator)), 0, "the evaluator keeps nothing");
        assertEq(token.balanceOf(address(acp)), 0, "escrow emptied");
        assertEq(token.balanceOf(client), 9 * BUDGET, "client paid once");
        assertEq(token.balanceOf(relayer), 0, "the caller gets nothing");
    }

    function test_with_a_platform_fee_the_provider_gets_the_budget_less_that_fee() public {
        acp.setPlatformFee(250, treasury);
        uint256 jobId = _submittedJob();
        _evaluate(jobId, output, proof);
        assertEq(token.balanceOf(treasury), 25_000, "platform fee");
        assertEq(token.balanceOf(provider), BUDGET - 25_000, "provider: budget less the platform fee");
        assertEq(token.balanceOf(address(evaluator)), 0, "the evaluator keeps nothing");
    }

    function test_without_an_evaluator_fee_the_provider_gets_the_budget() public {
        acp.setEvaluatorFee(0);
        uint256 jobId = _submittedJob();
        _evaluate(jobId, output, proof);
        assertEq(token.balanceOf(provider), BUDGET, "provider");
        assertEq(token.balanceOf(address(evaluator)), 0, "evaluator");
    }

    function test_only_the_fee_paid_during_the_call_is_forwarded() public {
        token.mint(address(evaluator), 7); // sent to the contract by mistake, outside any job
        uint256 jobId = _submittedJob();
        _evaluate(jobId, output, proof);
        assertEq(token.balanceOf(provider), BUDGET, "provider: exactly this job's budget");
        assertEq(token.balanceOf(address(evaluator)), 7, "unrelated tokens are not paid to a provider");
    }

    function test_the_reason_recorded_on_the_job_is_the_claim_digest() public {
        uint256 jobId = _submittedJob();
        bytes32 expected = keccak256(abi.encode(block.chainid, soloId, commitment, keccak256(output)));
        vm.expectEmit(address(acp));
        emit AgenticCommerce.JobCompleted(jobId, address(evaluator), expected);
        _evaluate(jobId, output, proof);

        uint256 jobId2 = _submittedJob();
        vm.chainId(8453);
        vm.expectEmit(address(acp));
        emit AgenticCommerce.JobCompleted(
            jobId2, address(evaluator), keccak256(abi.encode(8453, soloId, commitment, keccak256(output)))
        );
        _evaluate(jobId2, output, proof);
    }

    // ── Acceptance: an invalid proof reverts and the job is unchanged ───────────────────────────

    function test_a_tampered_proof_reverts_and_leaves_the_job_unchanged() public {
        uint256 jobId = _submittedJob();
        vm.prank(relayer);
        vm.expectRevert(ProofEvaluator8183.ProofInvalid.selector);
        _evaluate(jobId, output, _flipByte(proof, 100));
        _assertUnchanged(jobId);
    }

    function test_a_tampered_output_reverts_and_leaves_the_job_unchanged() public {
        uint256 jobId = _submittedJob();
        bytes memory other = bytes.concat(output);
        _setWord(other, 3, _word(other, 3) + 1);
        vm.expectRevert(ProofEvaluator8183.ProofInvalid.selector);
        _evaluate(jobId, other, proof);

        vm.expectRevert(ProofEvaluator8183.ProofInvalid.selector);
        _evaluate(jobId, bytes.concat(output, bytes32(0)), proof); // longer than the entry's output
        _assertUnchanged(jobId);
    }

    function test_terms_with_another_input_commitment_refuse_the_proof() public {
        uint256 jobId = _openJob(acp);
        vm.prank(client);
        evaluator.setTerms(
            address(acp),
            jobId,
            ProofEvaluator8183.JobTerms({verifierId: soloId, inputCommitment: bytes32(uint256(commitment) ^ 1)})
        );
        vm.prank(client);
        acp.fund(jobId, "");
        vm.prank(provider);
        acp.submit(jobId, keccak256(output), "");

        vm.expectRevert(ProofEvaluator8183.ProofInvalid.selector);
        _evaluate(jobId, output, proof);
        _assertJob(jobId, AgenticCommerce.JobStatus.Submitted);
    }

    function test_terms_naming_another_verifier_refuse_the_proof() public {
        // The K=8 entry is registered and runs, but the solo proof is not a proof for it.
        uint256 jobId = _openJob(acp);
        vm.prank(client);
        evaluator.setTerms(
            address(acp), jobId, ProofEvaluator8183.JobTerms({verifierId: k8Id, inputCommitment: commitment})
        );
        vm.prank(client);
        acp.fund(jobId, "");
        vm.prank(provider);
        acp.submit(jobId, keccak256(output), "");

        vm.expectRevert(ProofEvaluator8183.ProofInvalid.selector);
        evaluator.evaluate(address(acp), jobId, k8Entry, output, proof);
        _assertJob(jobId, AgenticCommerce.JobStatus.Submitted);
    }

    // ── A check that cannot run reverts too, with its own error ─────────────────────────────────

    function test_an_unknown_verifier_reverts_unavailable() public {
        bytes32 unknown = keccak256("no such verifier");
        uint256 jobId = _openJob(acp);
        vm.prank(client);
        evaluator.setTerms(
            address(acp), jobId, ProofEvaluator8183.JobTerms({verifierId: unknown, inputCommitment: commitment})
        );
        vm.prank(client);
        acp.fund(jobId, "");
        vm.prank(provider);
        acp.submit(jobId, keccak256(output), "");

        vm.expectRevert(abi.encodeWithSelector(ProofEvaluator8183.VerifierUnavailable.selector, unknown));
        _evaluate(jobId, output, proof);
        _assertUnchanged(jobId);
    }

    function test_an_entry_that_is_not_the_registered_one_reverts_unavailable() public {
        uint256 jobId = _submittedJob();
        VerifierEntry memory e = soloEntry;
        e.verifyGas += 1;
        vm.expectRevert(abi.encodeWithSelector(ProofEvaluator8183.VerifierUnavailable.selector, soloId));
        evaluator.evaluate(address(acp), jobId, e, output, proof);
        _assertUnchanged(jobId);
    }

    function test_a_verifier_whose_code_changed_reverts_unavailable() public {
        uint256 jobId = _submittedJob();
        vm.etch(SOLO, FixturesK8.verifierBytecode());
        vm.expectRevert(abi.encodeWithSelector(ProofEvaluator8183.VerifierUnavailable.selector, soloId));
        _evaluate(jobId, output, proof);
        _assertUnchanged(jobId);
    }

    // ── Acceptance: nobody can reject through the evaluator with a garbage proof ────────────────

    function test_nobody_can_reject_through_the_evaluator_with_a_garbage_proof() public {
        uint256 jobId = _submittedJob();
        bytes[4] memory garbage =
            [bytes(""), new bytes(proof.length), abi.encode(keccak256("garbage")), _truncate(proof, proof.length - 32)];
        for (uint256 i = 0; i < garbage.length; i++) {
            vm.prank(stranger);
            vm.expectRevert(ProofEvaluator8183.ProofInvalid.selector);
            _evaluate(jobId, output, garbage[i]);
        }
        vm.prank(stranger);
        vm.expectRevert(ProofEvaluator8183.ProofInvalid.selector);
        _evaluate(jobId, new bytes(output.length), proof);
        vm.prank(stranger);
        vm.expectRevert(ProofEvaluator8183.NotProvider.selector);
        evaluator.forfeit(address(acp), jobId);
        _assertUnchanged(jobId);

        // The job is still there to be completed by the real proof.
        _evaluate(jobId, output, proof);
        _assertJob(jobId, AgenticCommerce.JobStatus.Completed);
        assertEq(token.balanceOf(provider), BUDGET, "provider");
    }

    function _truncate(bytes memory data, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = data[i];
        }
    }

    // ── Acceptance: no completion at or after expiredAt ─────────────────────────────────────────

    function test_evaluate_one_second_before_expiry_completes() public {
        uint256 jobId = _submittedJob();
        vm.warp(EXPIRED_AT - 1);
        _evaluate(jobId, output, proof);
        _assertJob(jobId, AgenticCommerce.JobStatus.Completed);
    }

    function test_evaluate_at_expiry_reverts_and_the_refund_opens() public {
        uint256 jobId = _submittedJob();
        vm.warp(EXPIRED_AT);
        vm.expectRevert(abi.encodeWithSelector(ProofEvaluator8183.JobExpired.selector, EXPIRED_AT));
        _evaluate(jobId, output, proof);
        _assertUnchanged(jobId);

        vm.prank(stranger);
        acp.claimRefund(jobId);
        _assertJob(jobId, AgenticCommerce.JobStatus.Expired);
        assertEq(token.balanceOf(client), 10 * BUDGET, "client refunded");
    }

    function test_evaluate_after_expiry_reverts() public {
        uint256 jobId = _submittedJob();
        vm.warp(EXPIRED_AT + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(ProofEvaluator8183.JobExpired.selector, EXPIRED_AT));
        _evaluate(jobId, output, proof);
        _assertUnchanged(jobId);
    }

    // ── Acceptance: only the provider can forfeit ───────────────────────────────────────────────

    function test_only_the_provider_can_forfeit() public {
        uint256 jobId = _submittedJob();
        address[4] memory others = [client, stranger, relayer, address(this)];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(ProofEvaluator8183.NotProvider.selector);
            evaluator.forfeit(address(acp), jobId);
        }
        _assertUnchanged(jobId);

        vm.expectEmit(address(acp));
        emit AgenticCommerce.Refunded(jobId, client, BUDGET);
        vm.expectEmit(address(acp));
        emit AgenticCommerce.JobRejected(jobId, address(evaluator), evaluator.FORFEITED());
        vm.expectEmit(address(evaluator));
        emit ProofEvaluator8183.Forfeited(address(acp), jobId);
        vm.prank(provider);
        evaluator.forfeit(address(acp), jobId);

        _assertJob(jobId, AgenticCommerce.JobStatus.Rejected);
        assertEq(token.balanceOf(client), 10 * BUDGET, "client refunded");
        assertEq(token.balanceOf(provider), 0, "provider unpaid");
        assertEq(token.balanceOf(address(evaluator)), 0, "evaluator");
    }

    function test_a_provider_can_forfeit_before_submitting() public {
        uint256 jobId = _fundedJob();
        vm.prank(provider);
        evaluator.forfeit(address(acp), jobId);
        _assertJob(jobId, AgenticCommerce.JobStatus.Rejected);
        assertEq(token.balanceOf(client), 10 * BUDGET, "client refunded");
    }

    function test_forfeit_of_an_open_job_is_refused_by_the_job_contract() public {
        uint256 jobId = _openJob(acp);
        vm.prank(provider);
        vm.expectRevert(AgenticCommerce.Unauthorized.selector); // only the client may reject an Open job
        evaluator.forfeit(address(acp), jobId);
        _assertJob(jobId, AgenticCommerce.JobStatus.Open);
    }

    function test_a_forfeited_job_cannot_be_completed() public {
        uint256 jobId = _submittedJob();
        vm.prank(provider);
        evaluator.forfeit(address(acp), jobId);
        vm.expectRevert(
            abi.encodeWithSelector(ProofEvaluator8183.JobNotSubmitted.selector, IAgenticCommerce.JobStatus.Rejected)
        );
        _evaluate(jobId, output, proof);
    }

    // ── Acceptance: terms are set once, by the client, while the job is Open ────────────────────

    function test_terms_are_set_by_the_client_and_readable() public {
        uint256 jobId = _openJob(acp);
        vm.expectEmit(address(evaluator));
        emit ProofEvaluator8183.TermsSet(address(acp), jobId, soloId, commitment);
        vm.prank(client);
        evaluator.setTerms(address(acp), jobId, _terms());

        ProofEvaluator8183.JobTerms memory t = evaluator.terms(address(acp), jobId);
        assertEq(t.verifierId, soloId, "verifier");
        assertEq(t.inputCommitment, commitment, "commitment");
        assertEq(evaluator.terms(address(acp), jobId + 1).verifierId, bytes32(0), "no terms elsewhere");
    }

    function test_terms_set_twice_revert() public {
        uint256 jobId = _openJob(acp);
        vm.prank(client);
        evaluator.setTerms(address(acp), jobId, _terms());

        ProofEvaluator8183.JobTerms memory other = _terms();
        other.inputCommitment = bytes32(uint256(commitment) ^ 1);
        bytes memory err = abi.encodeWithSelector(ProofEvaluator8183.TermsAlreadySet.selector, address(acp), jobId);
        vm.prank(client);
        vm.expectRevert(err);
        evaluator.setTerms(address(acp), jobId, other);
        vm.prank(client);
        vm.expectRevert(err);
        evaluator.setTerms(address(acp), jobId, _terms());
        assertEq(evaluator.terms(address(acp), jobId).inputCommitment, commitment, "first terms kept");
    }

    function test_terms_set_by_anyone_but_the_client_revert() public {
        uint256 jobId = _openJob(acp);
        address[4] memory others = [provider, stranger, relayer, address(this)];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(ProofEvaluator8183.NotClient.selector);
            evaluator.setTerms(address(acp), jobId, _terms());
        }
        assertEq(evaluator.terms(address(acp), jobId).verifierId, bytes32(0), "nothing set");
    }

    function test_terms_after_the_job_left_Open_revert() public {
        uint256 jobId = _openJob(acp);
        vm.prank(client);
        acp.fund(jobId, "");
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(ProofEvaluator8183.JobNotOpen.selector, IAgenticCommerce.JobStatus.Funded)
        );
        evaluator.setTerms(address(acp), jobId, _terms());

        vm.prank(provider);
        acp.submit(jobId, keccak256(output), "");
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(ProofEvaluator8183.JobNotOpen.selector, IAgenticCommerce.JobStatus.Submitted)
        );
        evaluator.setTerms(address(acp), jobId, _terms());
    }

    function test_terms_for_a_job_with_another_evaluator_revert() public {
        vm.prank(client);
        uint256 jobId = acp.createJob(provider, stranger, EXPIRED_AT, "evaluated by someone else", address(0));
        vm.prank(client);
        vm.expectRevert(ProofEvaluator8183.NotEvaluator.selector);
        evaluator.setTerms(address(acp), jobId, _terms());
    }

    function test_terms_naming_no_verifier_revert() public {
        uint256 jobId = _openJob(acp);
        vm.prank(client);
        vm.expectRevert(ProofEvaluator8183.EmptyTerms.selector);
        evaluator.setTerms(
            address(acp), jobId, ProofEvaluator8183.JobTerms({verifierId: bytes32(0), inputCommitment: commitment})
        );
    }

    function test_terms_for_a_job_that_does_not_exist_revert() public {
        vm.prank(client);
        vm.expectRevert(ProofEvaluator8183.NotClient.selector);
        evaluator.setTerms(address(acp), 999, _terms());
    }

    function test_terms_are_kept_per_job_contract() public {
        AgenticCommerce acp2 = ReferenceDeploy.agenticCommerce(address(token), treasury);
        vm.prank(client);
        token.approve(address(acp2), type(uint256).max);
        uint256 jobId = _submittedJob(); // on `acp`, with terms
        uint256 jobId2 = _openJob(acp2); // same id on `acp2`, no terms
        assertEq(jobId2, jobId, "same job id");
        vm.prank(client);
        acp2.fund(jobId2, "");
        vm.prank(provider);
        acp2.submit(jobId2, keccak256(output), "");

        vm.expectRevert(abi.encodeWithSelector(ProofEvaluator8183.NoTerms.selector, address(acp2), jobId2));
        evaluator.evaluate(address(acp2), jobId2, soloEntry, output, proof);
        _evaluate(jobId, output, proof);
    }

    // ── Other states ────────────────────────────────────────────────────────────────────────────

    function test_without_terms_a_job_cannot_be_completed_and_can_only_expire() public {
        uint256 jobId = _openJob(acp);
        vm.prank(client);
        acp.fund(jobId, "");
        vm.prank(provider);
        acp.submit(jobId, keccak256(output), "");

        vm.expectRevert(abi.encodeWithSelector(ProofEvaluator8183.NoTerms.selector, address(acp), jobId));
        _evaluate(jobId, output, proof);

        vm.warp(EXPIRED_AT);
        acp.claimRefund(jobId);
        assertEq(token.balanceOf(client), 10 * BUDGET, "client refunded");
    }

    function test_evaluate_before_submission_reverts() public {
        uint256 jobId = _fundedJob();
        vm.expectRevert(
            abi.encodeWithSelector(ProofEvaluator8183.JobNotSubmitted.selector, IAgenticCommerce.JobStatus.Funded)
        );
        _evaluate(jobId, output, proof);
    }

    function test_a_job_is_completed_once() public {
        uint256 jobId = _submittedJob();
        _evaluate(jobId, output, proof);
        vm.expectRevert(
            abi.encodeWithSelector(ProofEvaluator8183.JobNotSubmitted.selector, IAgenticCommerce.JobStatus.Completed)
        );
        _evaluate(jobId, output, proof);
        assertEq(token.balanceOf(provider), BUDGET, "paid once");
    }

    /// The reference contract lets a provider submit a job with no budget while it is still Open,
    /// although the ERC's text allows `submit` only from Funded. The evaluator completes such a job
    /// like any other; nothing is paid.
    function test_a_zero_budget_job_submitted_while_Open_completes_with_nothing_paid() public {
        vm.prank(client);
        uint256 jobId = acp.createJob(provider, address(evaluator), EXPIRED_AT, "free job", address(0));
        vm.prank(client);
        evaluator.setTerms(address(acp), jobId, _terms());
        vm.prank(provider);
        acp.submit(jobId, keccak256(output), "");
        _assertJob(jobId, AgenticCommerce.JobStatus.Submitted);

        _evaluate(jobId, output, proof);
        _assertJob(jobId, AgenticCommerce.JobStatus.Completed);
        assertEq(token.balanceOf(provider), 0, "nothing paid");
    }
}
