// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SoloSettlementBase} from "./SoloSettlementBase.sol";
import {SoloSettlement, Terms} from "../src/SoloSettlement.sol";
import {ReentrantERC3009, FalseReturningERC3009} from "./mocks/MockERC3009.sol";

/// Escrow flow: `open` locks the payment, `release` pays on a valid proof, `refund` returns it
/// after `proveBy`. Tests named `test_v1_NN_…` are ports of case NN of the V1 solo suite
/// (`test/PORTED.md`).
contract SoloSettlementEscrowTest is SoloSettlementBase {
    // ── Ported V1 cases ─────────────────────────────────────────────────────────────────────────

    function test_v1_01_open_locks_and_a_valid_proof_releases_to_the_provider() public {
        Terms memory t = _terms("v1-01");
        bytes32 id = _escrowId(t);
        assertEq(settlement.escrowRequestId(t), id, "client and contract agree on the request id");
        bytes memory sig = _signEscrow(t);

        vm.expectEmit(address(settlement));
        emit SoloSettlement.Opened(id, payer, AMOUNT, PROVE_BY);
        vm.prank(relayer);
        assertEq(settlement.open(t, VALID_BEFORE, sig), id, "open returns the request id");
        assertEq(token.balanceOf(payer), 9 * AMOUNT, "payer charged");
        assertEq(token.balanceOf(address(settlement)), AMOUNT, "amount locked");
        _assertState(id, SoloSettlement.EscrowState.Open);

        vm.expectEmit(address(settlement));
        emit SoloSettlement.Settled(id, soloId, provider, output);
        vm.prank(stranger);
        _release(t);
        assertEq(token.balanceOf(provider), AMOUNT, "provider paid");
        assertEq(token.balanceOf(address(settlement)), 0, "lock emptied");
        _assertState(id, SoloSettlement.EscrowState.Released);
    }

    function test_v1_02_terms_with_another_input_commitment_are_proof_invalid() public {
        Terms memory t = _terms("v1-02");
        t.inputCommitment = bytes32(uint256(commitment) + 1);
        bytes32 id = _open(t);
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        _release(t);
        _assertState(id, SoloSettlement.EscrowState.Open);
        assertEq(token.balanceOf(address(settlement)), AMOUNT, "still locked");
    }

    function test_v1_03_changed_output_is_proof_invalid() public {
        Terms memory t = _terms("v1-03");
        _open(t);
        bytes memory changed = _changedOutput(4);
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        settlement.release(t, soloEntry, changed, proof);
    }

    function test_v1_04_changed_proof_is_proof_invalid() public {
        Terms memory t = _terms("v1-04");
        _open(t);
        bytes memory changed = _changedProof();
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        settlement.release(t, soloEntry, output, changed);
    }

    function test_v1_05_anyone_refunds_the_payer_after_prove_by() public {
        Terms memory t = _terms("v1-05");
        bytes32 id = _open(t);
        vm.warp(PROVE_BY + 1);
        vm.expectEmit(address(settlement));
        emit SoloSettlement.Refunded(id);
        vm.prank(stranger);
        settlement.refund(t);
        assertEq(token.balanceOf(payer), 10 * AMOUNT, "payer made whole");
        assertEq(token.balanceOf(stranger), 0, "the caller gets nothing");
        assertEq(token.balanceOf(address(settlement)), 0, "lock emptied");
        _assertState(id, SoloSettlement.EscrowState.Refunded);
    }

    function test_v1_06_release_after_refund_reverts() public {
        Terms memory t = _terms("v1-06");
        bytes32 id = _open(t);
        vm.warp(PROVE_BY + 1);
        settlement.refund(t);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.NotOpen.selector, id));
        _release(t);
        assertEq(token.balanceOf(provider), 0);
    }

    function test_v1_07_refund_after_release_reverts() public {
        Terms memory t = _terms("v1-07");
        bytes32 id = _open(t);
        _release(t);
        vm.warp(PROVE_BY + 1);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.NotOpen.selector, id));
        settlement.refund(t);
        assertEq(token.balanceOf(payer), 9 * AMOUNT);
    }

    function test_v1_08_second_release_reverts() public {
        Terms memory t = _terms("v1-08");
        bytes32 id = _open(t);
        _release(t);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.NotOpen.selector, id));
        _release(t);
        assertEq(token.balanceOf(provider), AMOUNT, "paid once");
    }

    function test_v1_09_second_open_with_the_same_terms_reverts() public {
        Terms memory t = _terms("v1-09");
        bytes memory sig = _signEscrow(t);
        bytes32 id = settlement.open(t, VALID_BEFORE, sig);
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.AlreadyOpened.selector, id));
        settlement.open(t, VALID_BEFORE, sig);
        assertEq(token.balanceOf(payer), 9 * AMOUNT, "charged once");
    }

    function test_v1_10_refund_up_to_and_at_prove_by_reverts() public {
        Terms memory t = _terms("v1-10");
        _open(t);
        vm.expectRevert(SoloSettlement.NotExpired.selector);
        settlement.refund(t);
        vm.warp(PROVE_BY);
        vm.expectRevert(SoloSettlement.NotExpired.selector);
        settlement.refund(t);
    }

    function test_v1_11_release_after_prove_by_reverts() public {
        Terms memory t = _terms("v1-11");
        _open(t);
        vm.warp(PROVE_BY + 1);
        vm.expectRevert(SoloSettlement.Expired.selector);
        _release(t);

        vm.warp(PROVE_BY); // the last second is still in time
        _release(t);
        assertEq(token.balanceOf(provider), AMOUNT);
    }

    function test_v1_12_output_of_the_wrong_length_is_proof_invalid() public {
        Terms memory t = _terms("v1-12");
        _open(t);
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        settlement.release(t, soloEntry, new bytes(288), proof);
        vm.expectRevert(SoloSettlement.ProofInvalid.selector);
        settlement.release(t, soloEntry, bytes.concat(output, bytes32(0)), proof);
    }

    function test_v1_13_open_with_prove_by_not_in_the_future_reverts() public {
        Terms memory t = _terms("v1-13");
        t.proveBy = uint64(block.timestamp);
        bytes memory sig = _signEscrow(t);
        vm.expectRevert(SoloSettlement.Expired.selector);
        settlement.open(t, VALID_BEFORE, sig);

        t.proveBy = uint64(block.timestamp - 1);
        sig = _signEscrow(t);
        vm.expectRevert(SoloSettlement.Expired.selector);
        settlement.open(t, VALID_BEFORE, sig);
        assertEq(token.balanceOf(payer), 10 * AMOUNT);
    }

    // ── Payer signatures ────────────────────────────────────────────────────────────────────────

    function test_smart_wallet_payer_opens_and_is_refunded() public {
        Terms memory t = _terms("1271");
        t.payer = address(wallet);
        bytes memory sig = _authorize(walletOwnerKey, address(wallet), address(settlement), AMOUNT, _escrowId(t));
        settlement.open(t, VALID_BEFORE, sig);
        assertEq(token.balanceOf(address(wallet)), 9 * AMOUNT, "wallet charged");
        vm.warp(PROVE_BY + 1);
        settlement.refund(t);
        assertEq(token.balanceOf(address(wallet)), 10 * AMOUNT, "wallet refunded");
    }

    function test_smart_wallet_that_rejects_the_signature_cannot_be_locked() public {
        Terms memory t = _terms("1271-reject");
        t.payer = address(wallet);
        bytes memory sig = _authorize(walletOwnerKey, address(wallet), address(settlement), AMOUNT, _escrowId(t));
        wallet.setAccepting(false);
        vm.expectRevert(bytes("invalid signature"));
        settlement.open(t, VALID_BEFORE, sig);
    }

    function test_an_escrow_authorization_cannot_settle_in_one_transaction() public {
        Terms memory t = _terms("cross");
        bytes memory sig = _signEscrow(t);
        vm.expectRevert(bytes("invalid signature"));
        _settle(t, sig);
    }

    // ── Who gets paid ───────────────────────────────────────────────────────────────────────────

    /// The terms identify the lock. Changing the recipient (or any field) names a lock that was
    /// never opened.
    function test_release_with_changed_terms_finds_no_lock() public {
        Terms memory t = _terms("changed");
        _open(t);
        Terms memory u = _terms("changed");
        u.payTo = stranger;
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.NotOpen.selector, _escrowId(u)));
        _release(u);
        u = _terms("changed");
        u.amount = 2 * AMOUNT;
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.NotOpen.selector, _escrowId(u)));
        _release(u);
        _release(t);
        assertEq(token.balanceOf(provider), AMOUNT);
        assertEq(token.balanceOf(stranger), 0);
    }

    // ── A verifier that becomes unusable leaves the payer a way out ─────────────────────────────

    function test_if_the_verifier_code_changes_release_is_unavailable_and_refund_still_works() public {
        Terms memory t = _terms("lost-verifier");
        bytes32 id = _open(t);
        vm.etch(SOLO, hex"600160005260206000f3"); // returns true for anything
        vm.expectRevert(abi.encodeWithSelector(SoloSettlement.VerifierUnavailable.selector, soloId));
        _release(t);
        vm.warp(PROVE_BY + 1);
        settlement.refund(t);
        assertEq(token.balanceOf(payer), 10 * AMOUNT);
        _assertState(id, SoloSettlement.EscrowState.Refunded);
    }

    // ── Paying out ──────────────────────────────────────────────────────────────────────────────

    function test_a_token_whose_transfer_returns_false_cannot_release_or_refund() public {
        FalseReturningERC3009 ft = new FalseReturningERC3009();
        ft.mint(payer, 10 * AMOUNT);
        tokenDomain = ft.DOMAIN_SEPARATOR();
        Terms memory t = _terms("false");
        t.asset = address(ft);
        bytes32 id = _open(t);
        vm.expectRevert(SoloSettlement.TransferFailed.selector);
        _release(t);
        vm.warp(PROVE_BY + 1);
        vm.expectRevert(SoloSettlement.TransferFailed.selector);
        settlement.refund(t);
        _assertState(id, SoloSettlement.EscrowState.Open);
    }

    // ── State is written before the payment leaves ──────────────────────────────────────────────

    function test_a_token_that_reenters_cannot_release_twice() public {
        ReentrantERC3009 rt = new ReentrantERC3009();
        rt.mint(payer, 10 * AMOUNT);
        tokenDomain = rt.DOMAIN_SEPARATOR();
        Terms memory t = _terms("reenter-release");
        t.asset = address(rt);
        _open(t);
        rt.mint(address(settlement), 5 * AMOUNT); // other locks in the same token
        rt.arm(address(settlement), abi.encodeCall(SoloSettlement.release, (t, soloEntry, output, proof)));
        _release(t);
        assertTrue(rt.reentered(), "the token did call back");
        assertFalse(rt.innerCallSucceeded(), "the inner release failed");
        assertEq(rt.balanceOf(provider), AMOUNT, "paid once");
        assertEq(rt.balanceOf(address(settlement)), 5 * AMOUNT, "other locks untouched");
    }

    function test_a_token_that_reenters_cannot_refund_twice() public {
        ReentrantERC3009 rt = new ReentrantERC3009();
        rt.mint(payer, 10 * AMOUNT);
        tokenDomain = rt.DOMAIN_SEPARATOR();
        Terms memory t = _terms("reenter-refund");
        t.asset = address(rt);
        _open(t);
        rt.mint(address(settlement), 5 * AMOUNT);
        vm.warp(PROVE_BY + 1);
        rt.arm(address(settlement), abi.encodeCall(SoloSettlement.refund, (t)));
        settlement.refund(t);
        assertTrue(rt.reentered(), "the token did call back");
        assertFalse(rt.innerCallSucceeded(), "the inner refund failed");
        assertEq(rt.balanceOf(payer), 10 * AMOUNT, "refunded once");
        assertEq(rt.balanceOf(address(settlement)), 5 * AMOUNT, "other locks untouched");
    }
}
