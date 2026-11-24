// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SoloSettlementBase} from "./SoloSettlementBase.sol";
import {SoloSettlement, Terms} from "../src/SoloSettlement.sol";
import {ProofCheck} from "../src/ProofCheck.sol";
import {MockERC3009, FalseReturningERC3009} from "./mocks/MockERC3009.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";

/// One-transaction flow: `settle` checks the proof, pulls the payment and pays, storing nothing.
/// Tests named `test_v1_NN_…` are ports of case NN of the V1 solo suite (`test/PORTED.md`).
contract SoloSettlementOneTransactionTest is SoloSettlementBase {
    // ── Ported V1 cases ─────────────────────────────────────────────────────────────────────────

    function test_v1_01_valid_proof_pays_the_provider_in_one_transaction() public {
        Terms memory t = _terms("v1-01");
        bytes memory sig = _signPayment(t);
        bytes32 id = _paymentId(t);
        assertEq(settlement.paymentRequestId(t), id, "client and contract agree on the request id");

        vm.expectEmit(address(settlement));
        emit SoloSettlement.Settled(id, soloId, provider, output);
        vm.prank(relayer);
        _settle(t, sig);

        assertEq(token.balanceOf(payer), 9 * AMOUNT, "payer charged once");
        assertEq(token.balanceOf(provider), AMOUNT, "provider paid");
        assertEq(token.balanceOf(address(settlement)), 0, "nothing rests in the contract");
        assertTrue(token.authorizationState(payer, id), "authorization consumed");
        _assertState(_escrowId(t), SoloSettlement.EscrowState.None);
    }

    function test_v1_02_terms_with_another_input_commitment_are_proof_invalid() public {
        Terms memory t = _terms("v1-02");
        t.inputCommitment = bytes32(uint256(commitment) + 1);
        bytes memory sig = _signPayment(t);
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        _settle(t, sig);
        assertEq(token.balanceOf(payer), 10 * AMOUNT, "payer not charged");
    }

    function test_v1_03_changed_output_is_proof_invalid() public {
        Terms memory t = _terms("v1-03");
        bytes memory sig = _signPayment(t);
        bytes memory changed = _changedOutput(4);
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        settlement.settle(t, soloEntry, VALID_BEFORE, sig, changed, proof);
    }

    function test_v1_04_changed_proof_is_proof_invalid() public {
        Terms memory t = _terms("v1-04");
        bytes memory sig = _signPayment(t);
        bytes memory changed = _changedProof();
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        settlement.settle(t, soloEntry, VALID_BEFORE, sig, output, changed);
    }

    // V1 cases 05, 06 and 10 test the refund of a lock. This flow locks nothing.

    function test_v1_07_refund_cannot_reach_a_one_transaction_payment() public {
        Terms memory t = _terms("v1-07");
        _settle(t, _signPayment(t));
        vm.warp(PROVE_BY + 1);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.NotOpen.selector, _escrowId(t)));
        settlement.refund(t);
        assertEq(token.balanceOf(provider), AMOUNT, "payment stands");
    }

    function test_v1_08_the_same_authorization_cannot_settle_twice() public {
        Terms memory t = _terms("v1-08");
        bytes memory sig = _signPayment(t);
        _settle(t, sig);
        vm.expectRevert(bytes("authorization is used or canceled"));
        _settle(t, sig);
        assertEq(token.balanceOf(provider), AMOUNT, "paid once");
        assertEq(token.balanceOf(payer), 9 * AMOUNT, "charged once");
    }

    function test_v1_09_a_one_transaction_authorization_cannot_open_an_escrow() public {
        Terms memory t = _terms("v1-09");
        bytes memory sig = _signPayment(t);
        vm.expectRevert(bytes("invalid signature"));
        settlement.open(t, VALID_BEFORE, sig);
    }

    function test_v1_11_settle_after_prove_by_reverts_and_charges_nothing() public {
        Terms memory t = _terms("v1-11");
        bytes memory sig = _signPayment(t);
        vm.warp(PROVE_BY + 1);
        vm.expectRevert(SoloSettlement.Expired.selector);
        _settle(t, sig);
        assertEq(token.balanceOf(payer), 10 * AMOUNT, "payer keeps the funds");

        vm.warp(PROVE_BY); // the last second is still in time
        _settle(t, sig);
        assertEq(token.balanceOf(provider), AMOUNT);
    }

    function test_v1_12_output_of_the_wrong_length_is_proof_invalid() public {
        Terms memory t = _terms("v1-12");
        bytes memory sig = _signPayment(t);
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        settlement.settle(t, soloEntry, VALID_BEFORE, sig, new bytes(288), proof);
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        settlement.settle(t, soloEntry, VALID_BEFORE, sig, bytes.concat(output, bytes32(0)), proof);
    }

    function test_v1_13_terms_that_expired_before_submission_revert() public {
        Terms memory t = _terms("v1-13");
        t.proveBy = uint64(block.timestamp - 1);
        bytes memory sig = _signPayment(t);
        vm.expectRevert(SoloSettlement.Expired.selector);
        _settle(t, sig);
    }

    // ── Payer signatures ────────────────────────────────────────────────────────────────────────

    function test_smart_wallet_payer_settles_with_an_erc1271_signature() public {
        Terms memory t = _terms("1271");
        t.payer = address(wallet);
        bytes memory sig = _authorize(walletOwnerKey, address(wallet), address(settlement), AMOUNT, _paymentId(t));
        _settle(t, sig);
        assertEq(token.balanceOf(address(wallet)), 9 * AMOUNT, "wallet charged");
        assertEq(token.balanceOf(provider), AMOUNT, "provider paid");
    }

    function test_smart_wallet_that_rejects_the_signature_is_not_charged() public {
        Terms memory t = _terms("1271-reject");
        t.payer = address(wallet);
        bytes memory sig = _authorize(walletOwnerKey, address(wallet), address(settlement), AMOUNT, _paymentId(t));
        wallet.setAccepting(false);
        vm.expectRevert(bytes("invalid signature"));
        _settle(t, sig);
    }

    function test_signature_by_someone_else_is_rejected() public {
        Terms memory t = _terms("not-the-payer");
        (, uint256 otherKey) = makeAddrAndKey("someone else");
        bytes memory sig = _authorize(otherKey, payer, address(settlement), AMOUNT, _paymentId(t));
        vm.expectRevert(bytes("invalid signature"));
        _settle(t, sig);
    }

    /// Every field of the terms is covered by the signature: changing any one after signing makes
    /// the authorization invalid. The terms name the always-true verifier, so the proof passes
    /// whatever the commitment and only the signature can stop a changed field.
    function test_every_field_of_the_terms_is_signed() public {
        MockERC3009 otherToken = new MockERC3009();
        otherToken.mint(payer, 10 * AMOUNT);
        Terms memory t = _terms("fields");
        t.verifierId = trueId;
        bytes memory sig = _signPayment(t);
        for (uint256 i = 0; i < 8; i++) {
            Terms memory u = _terms("fields");
            u.verifierId = trueId;
            if (i == 0) u.payer = stranger;
            if (i == 1) u.payTo = stranger;
            if (i == 2) u.asset = address(otherToken);
            if (i == 3) u.amount = AMOUNT - 1;
            if (i == 4) u.verifierId = soloId;
            if (i == 5) u.inputCommitment = bytes32(uint256(commitment) ^ 1);
            if (i == 6) u.proveBy = PROVE_BY + 1;
            if (i == 7) u.salt = "other";
            vm.expectRevert(bytes("invalid signature"));
            settlement.settle(u, i == 4 ? soloEntry : trueEntry, VALID_BEFORE, sig, output, proof);
        }
        settlement.settle(t, trueEntry, VALID_BEFORE, sig, output, proof);
        assertEq(token.balanceOf(provider), AMOUNT, "the unchanged terms still settle");
    }

    // ── Proof layer ─────────────────────────────────────────────────────────────────────────────

    function test_entry_that_is_not_the_registered_one_is_unavailable() public {
        Terms memory t = _terms("entry");
        bytes memory sig = _signPayment(t);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.VerifierUnavailable.selector, soloId));
        settlement.settle(t, trueEntry, VALID_BEFORE, sig, output, proof);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.VerifierUnavailable.selector, soloId));
        settlement.settle(t, k8Entry, VALID_BEFORE, sig, output, proof);
    }

    /// The shape check belongs to the proof layer, not only to the EZKL adapter: with an adapter
    /// that accepts anything, an output of the wrong size must still be refused.
    function test_output_of_the_wrong_size_is_invalid_even_if_the_adapter_accepts_anything() public {
        Terms memory t = _terms("shape");
        t.verifierId = trueId;
        bytes memory sig = _signPayment(t);
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        settlement.settle(t, trueEntry, VALID_BEFORE, sig, new bytes(288), proof);
        settlement.settle(t, trueEntry, VALID_BEFORE, sig, output, proof);
        assertEq(token.balanceOf(provider), AMOUNT, "the right size settles");
    }

    /// A solo request has one input commitment. An entry for a batch circuit (more than one lane)
    /// cannot settle it, whatever its adapter would say.
    function test_entry_with_more_than_one_lane_cannot_settle_a_solo_request() public {
        VerifierEntry memory twoLanes =
            _entry(trueEntry.adapter, address(0), 2, OUTPUT_SIZE, SOLO_VERIFY_GAS, SOLO_VK_HASH);
        bytes32 twoLanesId = registry.register(twoLanes);
        Terms memory t = _terms("lanes");
        t.verifierId = twoLanesId;
        bytes memory sig = _signPayment(t);
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        settlement.settle(t, twoLanes, VALID_BEFORE, sig, output, proof);
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        settlement.settle(t, twoLanes, VALID_BEFORE, sig, bytes.concat(output, output), proof);
    }

    function test_unknown_verifier_is_unavailable() public {
        Terms memory t = _terms("unknown");
        t.verifierId = keccak256("no such verifier");
        bytes memory sig = _signPayment(t);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.VerifierUnavailable.selector, t.verifierId));
        _settle(t, sig);
    }

    // ── Paying out ──────────────────────────────────────────────────────────────────────────────

    function test_a_token_whose_transfer_returns_false_cannot_settle() public {
        FalseReturningERC3009 ft = new FalseReturningERC3009();
        ft.mint(payer, 10 * AMOUNT);
        tokenDomain = ft.DOMAIN_SEPARATOR();
        Terms memory t = _terms("false");
        t.asset = address(ft);
        bytes memory sig = _signPayment(t);
        vm.expectRevert(SoloSettlement.TransferFailed.selector);
        _settle(t, sig);
        assertEq(ft.balanceOf(payer), 10 * AMOUNT, "payer not charged");
    }

    function test_too_little_gas_reverts_with_a_typed_error_not_proof_invalid() public {
        Terms memory t = _terms("gas");
        bytes memory sig = _signPayment(t);
        vm.expectPartialRevert(ProofCheck.InsufficientGasForVerifier.selector);
        settlement.settle{gas: 600_000}(t, soloEntry, VALID_BEFORE, sig, output, proof);
        _settle(t, sig);
        assertEq(token.balanceOf(provider), AMOUNT, "the same call with enough gas settles");
    }
}
