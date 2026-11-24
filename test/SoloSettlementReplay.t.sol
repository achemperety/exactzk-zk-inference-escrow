// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SoloSettlementBase} from "./SoloSettlementBase.sol";
import {SoloSettlement, Terms} from "../src/SoloSettlement.sol";

/// The replay matrix. Every attempt here must fail, in both flows where the flow allows it.
///
/// | Row | Attempt |
/// |---|---|
/// | 1 | the same authorization used twice, within a flow and across flows |
/// | 2 | the same proof presented for a second request with a different input commitment |
/// | 3 | an authorization whose terms name another chain or another settlement contract |
/// | 4 | a proof for one verifier entry presented against terms naming another |
/// | 5 | release after refund, and refund after release |
contract SoloSettlementReplayTest is SoloSettlementBase {
    // ── Row 1: the same authorization twice ─────────────────────────────────────────────────────

    function test_row1_one_transaction_authorization_used_twice() public {
        Terms memory t = _terms("r1");
        bytes memory sig = _signPayment(t);
        _settle(t, sig);
        vm.expectRevert(bytes("authorization is used or canceled"));
        _settle(t, sig);
    }

    function test_row1_escrow_authorization_used_twice() public {
        Terms memory t = _terms("r1");
        bytes memory sig = _signEscrow(t);
        bytes32 id = settlement.open(t, VALID_BEFORE, sig);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.AlreadyOpened.selector, id));
        settlement.open(t, VALID_BEFORE, sig);
    }

    function test_row1_escrow_authorization_used_again_after_release() public {
        Terms memory t = _terms("r1");
        bytes memory sig = _signEscrow(t);
        bytes32 id = settlement.open(t, VALID_BEFORE, sig);
        _release(t);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.AlreadyOpened.selector, id));
        settlement.open(t, VALID_BEFORE, sig);
    }

    function test_row1_authorization_used_in_the_other_flow() public {
        Terms memory t = _terms("r1");
        bytes memory paymentSig = _signPayment(t);
        bytes memory escrowSig = _signEscrow(t);
        vm.expectRevert(bytes("invalid signature"));
        settlement.open(t, VALID_BEFORE, paymentSig);
        vm.expectRevert(bytes("invalid signature"));
        _settle(t, escrowSig);
    }

    // ── Row 2: the same proof for another request with a different commitment ───────────────────

    function test_row2_same_proof_second_request_other_commitment_one_transaction() public {
        Terms memory first = _terms("r2-first");
        _settle(first, _signPayment(first));

        Terms memory second = _terms("r2-second");
        second.inputCommitment = keccak256("another input");
        bytes memory sig = _signPayment(second);
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        _settle(second, sig);
        assertEq(token.balanceOf(provider), AMOUNT, "only the first request was paid");
    }

    function test_row2_same_proof_second_request_other_commitment_escrow() public {
        Terms memory first = _terms("r2-first");
        _open(first);
        _release(first);

        Terms memory second = _terms("r2-second");
        second.inputCommitment = keccak256("another input");
        _open(second);
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        _release(second);
        assertEq(token.balanceOf(provider), AMOUNT, "only the first request was paid");
    }

    /// Not a failure case, recorded so the boundary is explicit: the proof is not bound to the
    /// request, by design, so a second request with the same commitment is settled by the same
    /// proof. The statement is true for both; clients avoid it by putting fresh nonce values in
    /// the committed input.
    function test_row2_contrast_same_commitment_is_settled_by_the_same_proof() public {
        Terms memory first = _terms("r2-first");
        Terms memory second = _terms("r2-second");
        _settle(first, _signPayment(first));
        _settle(second, _signPayment(second));
        assertEq(token.balanceOf(provider), 2 * AMOUNT);
    }

    // ── Row 3: another chain or another contract in the terms ───────────────────────────────────

    function test_row3_terms_signed_for_another_chain() public {
        Terms memory t = _terms("r3");
        bytes memory paySig = _authorize(
            payerKey,
            payer,
            address(settlement),
            AMOUNT,
            _id(PAYMENT_TYPEHASH, block.chainid + 1, address(settlement), t)
        );
        bytes memory escrowSig = _authorize(
            payerKey,
            payer,
            address(settlement),
            AMOUNT,
            _id(ESCROW_TYPEHASH, block.chainid + 1, address(settlement), t)
        );
        vm.expectRevert(bytes("invalid signature"));
        _settle(t, paySig);
        vm.expectRevert(bytes("invalid signature"));
        settlement.open(t, VALID_BEFORE, escrowSig);
    }

    /// Signed on this chain, submitted on another. The test token's domain separator is fixed at
    /// deployment, so only the request id carries the chain id here: this isolates the settlement
    /// contract's own binding.
    function test_row3_authorization_submitted_on_another_chain() public {
        Terms memory t = _terms("r3");
        bytes memory paySig = _signPayment(t);
        bytes memory escrowSig = _signEscrow(t);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(bytes("invalid signature"));
        _settle(t, paySig);
        vm.expectRevert(bytes("invalid signature"));
        settlement.open(t, VALID_BEFORE, escrowSig);
    }

    function test_row3_terms_signed_for_another_settlement_contract() public {
        SoloSettlement other = new SoloSettlement(registry);
        Terms memory t = _terms("r3");
        // Signed for `other` (request id and payee), submitted here.
        bytes memory paySig = _authorize(
            payerKey, payer, address(other), AMOUNT, _id(PAYMENT_TYPEHASH, block.chainid, address(other), t)
        );
        bytes memory escrowSig =
            _authorize(payerKey, payer, address(other), AMOUNT, _id(ESCROW_TYPEHASH, block.chainid, address(other), t));
        vm.expectRevert(bytes("invalid signature"));
        _settle(t, paySig);
        vm.expectRevert(bytes("invalid signature"));
        settlement.open(t, VALID_BEFORE, escrowSig);

        // Signed for this contract, submitted to `other`.
        paySig = _signPayment(t);
        escrowSig = _signEscrow(t);
        vm.expectRevert(bytes("invalid signature"));
        other.settle(t, soloEntry, VALID_BEFORE, paySig, output, proof);
        vm.expectRevert(bytes("invalid signature"));
        other.open(t, VALID_BEFORE, escrowSig);
    }

    // ── Row 4: a proof for one verifier entry against terms naming another ─────────────────────

    /// The terms name the solo circuit; the submitter supplies the always-true entry, which
    /// declares the same verifying-key hash and would accept anything.
    function test_row4_always_true_entry_against_terms_naming_the_solo_circuit() public {
        Terms memory t = _terms("r4");
        bytes memory sig = _signPayment(t);
        bytes memory forged = _changedOutput(0);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.VerifierUnavailable.selector, soloId));
        settlement.settle(t, trueEntry, VALID_BEFORE, sig, forged, proof);

        Terms memory e = _terms("r4-escrow");
        _open(e);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.VerifierUnavailable.selector, soloId));
        settlement.release(e, trueEntry, forged, proof);
    }

    /// The terms name the always-true entry; the submitter supplies the solo entry and a real proof.
    function test_row4_real_proof_with_the_solo_entry_against_terms_naming_another_entry() public {
        Terms memory t = _terms("r4");
        t.verifierId = trueId;
        bytes memory sig = _signPayment(t);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.VerifierUnavailable.selector, trueId));
        _settle(t, sig);

        Terms memory e = _terms("r4-escrow");
        e.verifierId = trueId;
        _open(e);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.VerifierUnavailable.selector, trueId));
        _release(e);
    }

    /// The terms name the K=8 circuit and the submitter supplies its real entry with the solo proof.
    function test_row4_solo_proof_against_terms_naming_the_k8_circuit() public {
        Terms memory t = _terms("r4");
        t.verifierId = k8Id;
        bytes memory sig = _signPayment(t);
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        settlement.settle(t, k8Entry, VALID_BEFORE, sig, output, proof);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.VerifierUnavailable.selector, k8Id));
        settlement.settle(t, soloEntry, VALID_BEFORE, sig, output, proof);

        Terms memory e = _terms("r4-escrow");
        e.verifierId = k8Id;
        _open(e);
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        settlement.release(e, k8Entry, output, proof);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.VerifierUnavailable.selector, k8Id));
        settlement.release(e, soloEntry, output, proof);
    }

    // ── Row 5: release after refund, refund after release ───────────────────────────────────────

    function test_row5_release_after_refund() public {
        Terms memory t = _terms("r5");
        bytes32 id = _open(t);
        vm.warp(PROVE_BY + 1);
        settlement.refund(t);
        vm.warp(PROVE_BY); // even back inside the window
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.NotOpen.selector, id));
        _release(t);
    }

    function test_row5_refund_after_release() public {
        Terms memory t = _terms("r5");
        bytes32 id = _open(t);
        _release(t);
        vm.warp(PROVE_BY + 1);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.NotOpen.selector, id));
        settlement.refund(t);
    }
}
