// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AuthCaptureBase, IEscrowReclaim} from "./AuthCaptureBase.sol";
import {FixturesK8} from "./fixtures/FixturesK8.sol";
import {AuthCaptureProofOperator} from "../src/AuthCaptureProofOperator.sol";
import {IAuthCaptureEscrow} from "../src/IAuthCaptureEscrow.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";
import {AuthCaptureEscrow} from "lib/commerce-payments/src/AuthCaptureEscrow.sol";

/// `AuthCaptureProofOperator` against x402's auth-capture escrow built from source
/// (base/commerce-payments v1.1.0), with the real solo proof.
contract AuthCaptureProofOperatorTest is AuthCaptureBase {
    uint256 internal constant NONCE = uint256(keccak256("the client's random salt nonce"));

    function _flip(bytes memory data, uint256 index) internal pure returns (bytes memory c) {
        c = bytes.concat(data);
        c[index] = bytes1(uint8(c[index]) ^ 0x01);
    }

    function _capture(IAuthCaptureEscrow.PaymentInfo memory p, AuthCaptureProofOperator.Terms memory t) internal {
        op.captureWithProof(p, t, soloEntry, output, proof);
    }

    function _assertHeld(IAuthCaptureEscrow.PaymentInfo memory p, uint120 amount) internal view {
        (uint120 capturable, uint120 refundable) = _held(p);
        assertEq(capturable, amount, "held");
        assertEq(refundable, 0, "nothing captured");
        assertEq(token.balanceOf(receiver), 0, "receiver unpaid");
        assertEq(token.balanceOf(payer), 10 * AMOUNT - amount, "payer");
    }

    // ── The escrow flow: hold, then capture only with a proof ───────────────────────────────────

    function test_anyone_places_the_hold_and_a_valid_proof_captures_it_for_the_receiver() public {
        AuthCaptureProofOperator.Terms memory t = _terms(NONCE);
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(t);

        vm.prank(relayer);
        _authorize(p);
        _assertHeld(p, AMOUNT);

        bytes32 h = escrow.getHash(p);
        bytes32 digest = keccak256(abi.encode(block.chainid, soloId, commitment, keccak256(output)));
        vm.expectEmit(ESCROW);
        emit AuthCaptureEscrow.PaymentCaptured(h, AMOUNT, 0, address(0));
        vm.expectEmit(address(op));
        emit AuthCaptureProofOperator.CapturedWithProof(h, digest, AMOUNT, output);
        vm.prank(stranger);
        _capture(p, t);

        (uint120 capturable, uint120 refundable) = _held(p);
        assertEq(capturable, 0, "hold spent");
        assertEq(refundable, AMOUNT, "captured");
        assertEq(token.balanceOf(receiver), AMOUNT, "receiver paid");
        assertEq(token.balanceOf(payer), 9 * AMOUNT, "payer paid once");
        assertEq(token.balanceOf(stranger), 0, "the caller gets nothing");
    }

    function test_the_fee_taken_is_the_payers_minimum() public {
        AuthCaptureProofOperator.Terms memory t = _terms(NONCE);
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(t);
        p.minFeeBps = 100;
        p.maxFeeBps = 300;
        p.feeReceiver = feeRecipient;
        _authorize(p);
        _capture(p, t);
        assertEq(token.balanceOf(feeRecipient), 10_000, "1 %, the minimum");
        assertEq(token.balanceOf(receiver), AMOUNT - 10_000, "receiver");
    }

    function test_an_invalid_proof_cannot_capture_and_the_payer_reclaims_after_the_deadline() public {
        AuthCaptureProofOperator.Terms memory t = _terms(NONCE);
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(t);
        _authorize(p);

        vm.expectRevert(AuthCaptureProofOperator.ProofInvalid.selector);
        op.captureWithProof(p, t, soloEntry, output, _flip(proof, 100));
        bytes memory other = bytes.concat(output);
        _setWord(other, 2, _word(other, 2) + 1);
        vm.expectRevert(AuthCaptureProofOperator.ProofInvalid.selector);
        op.captureWithProof(p, t, soloEntry, other, proof);
        vm.expectRevert(AuthCaptureProofOperator.ProofInvalid.selector);
        op.captureWithProof(p, t, soloEntry, output, "");
        _assertHeld(p, AMOUNT);

        // Before the capture deadline the payer cannot take the hold back; from it on, it can.
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(AuthCaptureEscrow.BeforeAuthorizationExpiry.selector, uint48(T0), CAPTURE_DEADLINE)
        );
        IEscrowReclaim(ESCROW).reclaim(p);
        vm.warp(CAPTURE_DEADLINE);
        vm.prank(payer);
        IEscrowReclaim(ESCROW).reclaim(p);
        assertEq(token.balanceOf(payer), 10 * AMOUNT, "payer has it all back");
        assertEq(token.balanceOf(receiver), 0, "receiver unpaid");
    }

    function test_a_check_that_cannot_run_cannot_capture() public {
        AuthCaptureProofOperator.Terms memory t = _terms(NONCE);
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(t);
        _authorize(p);

        VerifierEntry memory e = soloEntry;
        e.verifyGas += 1;
        vm.expectRevert(abi.encodeWithSelector(AuthCaptureProofOperator.VerifierUnavailable.selector, soloId));
        op.captureWithProof(p, t, e, output, proof);

        vm.etch(SOLO, FixturesK8.verifierBytecode());
        vm.expectRevert(abi.encodeWithSelector(AuthCaptureProofOperator.VerifierUnavailable.selector, soloId));
        _capture(p, t);
        _assertHeld(p, AMOUNT);
    }

    function test_a_proof_for_other_terms_than_the_payer_signed_cannot_capture() public {
        // The payer signed for a different input commitment; the real proof is for `commitment`.
        AuthCaptureProofOperator.Terms memory signed = _terms(NONCE);
        signed.inputCommitment = bytes32(uint256(commitment) ^ 1);
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(signed);
        _authorize(p);

        // Presenting the real terms does not match the salt...
        vm.expectRevert(AuthCaptureProofOperator.TermsMismatch.selector);
        _capture(p, _terms(NONCE));
        // ...and presenting the signed terms makes the real proof invalid for them.
        vm.expectRevert(AuthCaptureProofOperator.ProofInvalid.selector);
        _capture(p, signed);
        // Another verifier or another salt nonce does not match either.
        AuthCaptureProofOperator.Terms memory t = _terms(NONCE + 1);
        t.inputCommitment = signed.inputCommitment;
        vm.expectRevert(AuthCaptureProofOperator.TermsMismatch.selector);
        _capture(p, t);
        t = signed;
        t.verifierId = k8Id;
        vm.expectRevert(AuthCaptureProofOperator.TermsMismatch.selector);
        _capture(p, t);
        _assertHeld(p, AMOUNT);
    }

    function test_a_payment_not_bound_to_terms_can_never_be_captured() public {
        // A client that ignored `extra.receiverAuthorizer` leaves an unbound random salt.
        IAuthCaptureEscrow.PaymentInfo memory p = _paymentWithSalt(NONCE);
        _authorize(p);
        vm.expectRevert(AuthCaptureProofOperator.TermsMismatch.selector);
        _capture(p, _terms(NONCE));
        vm.warp(CAPTURE_DEADLINE);
        vm.prank(payer);
        IEscrowReclaim(ESCROW).reclaim(p);
        assertEq(token.balanceOf(payer), 10 * AMOUNT, "the payer gets it back");
    }

    function test_a_payment_for_another_operator_is_refused() public {
        AuthCaptureProofOperator.Terms memory t = _terms(NONCE);
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(t);
        p.operator = stranger;
        vm.expectRevert(AuthCaptureProofOperator.WrongOperator.selector);
        _capture(p, t);
    }

    function test_no_capture_from_the_capture_deadline_on() public {
        AuthCaptureProofOperator.Terms memory t = _terms(NONCE);
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(t);
        _authorize(p);
        vm.warp(CAPTURE_DEADLINE - 1);
        _capture(p, t);
        assertEq(token.balanceOf(receiver), AMOUNT, "a second before the deadline");

        IAuthCaptureEscrow.PaymentInfo memory q = _payment(_terms(NONCE + 7));
        vm.warp(T0);
        _authorize(q);
        vm.warp(CAPTURE_DEADLINE);
        vm.expectRevert(
            abi.encodeWithSelector(
                AuthCaptureEscrow.AfterAuthorizationExpiry.selector, CAPTURE_DEADLINE, CAPTURE_DEADLINE
            )
        );
        _capture(q, _terms(NONCE + 7));
    }

    function test_a_hold_is_captured_once() public {
        AuthCaptureProofOperator.Terms memory t = _terms(NONCE);
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(t);
        _authorize(p);
        _capture(p, t);
        vm.expectRevert(AuthCaptureEscrow.ZeroAmount.selector);
        _capture(p, t);
        assertEq(token.balanceOf(receiver), AMOUNT, "paid once");
    }

    // ── Collect ─────────────────────────────────────────────────────────────────────────────────

    function test_authorize_must_collect_the_full_amount() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(_terms(NONCE));
        bytes memory sig = _sign(p, payerKey);
        vm.expectRevert(abi.encodeWithSelector(AuthCaptureProofOperator.PartialAuthorization.selector, 1, AMOUNT));
        op.authorize(p, 1, COLLECTOR, sig);
        op.authorize(p, AMOUNT, COLLECTOR, sig);
        _assertHeld(p, AMOUNT);
    }

    function test_the_escrows_charge_is_not_reachable_without_a_proof() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(_terms(NONCE));
        bytes memory sig = _sign(p, payerKey);
        vm.expectRevert(AuthCaptureProofOperator.ProofRequired.selector);
        op.charge(p, AMOUNT, COLLECTOR, sig, 0, address(0));
        assertEq(token.balanceOf(payer), 10 * AMOUNT, "nothing moved");
    }

    // ── The one-step flow ───────────────────────────────────────────────────────────────────────

    function test_charge_with_a_valid_proof_pays_the_receiver_in_one_step() public {
        AuthCaptureProofOperator.Terms memory t = _terms(NONCE);
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(t);
        bytes memory sig = _sign(p, payerKey);
        vm.expectEmit(address(op));
        emit AuthCaptureProofOperator.ChargedWithProof(
            escrow.getHash(p),
            keccak256(abi.encode(block.chainid, soloId, commitment, keccak256(output))),
            AMOUNT,
            output
        );
        vm.prank(relayer);
        op.chargeWithProof(p, COLLECTOR, sig, t, soloEntry, output, proof);
        assertEq(token.balanceOf(receiver), AMOUNT, "receiver paid");
        assertEq(token.balanceOf(payer), 9 * AMOUNT, "payer charged");
        (uint120 capturable, uint120 refundable) = _held(p);
        assertEq(capturable, 0, "no hold");
        assertEq(refundable, AMOUNT, "charged");
    }

    function test_charge_with_an_invalid_proof_moves_nothing_and_the_authorization_stays_usable() public {
        AuthCaptureProofOperator.Terms memory t = _terms(NONCE);
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(t);
        bytes memory sig = _sign(p, payerKey);
        vm.expectRevert(AuthCaptureProofOperator.ProofInvalid.selector);
        op.chargeWithProof(p, COLLECTOR, sig, t, soloEntry, output, _flip(proof, 7));
        vm.expectRevert(AuthCaptureProofOperator.TermsMismatch.selector);
        op.chargeWithProof(p, COLLECTOR, sig, _terms(NONCE + 1), soloEntry, output, proof);
        assertEq(token.balanceOf(payer), 10 * AMOUNT, "nothing moved");
        op.chargeWithProof(p, COLLECTOR, sig, t, soloEntry, output, proof);
        assertEq(token.balanceOf(receiver), AMOUNT, "the same authorization then pays with the proof");
    }

    // ── Giving the hold back ────────────────────────────────────────────────────────────────────

    function test_only_the_receiver_can_give_the_hold_back_early() public {
        AuthCaptureProofOperator.Terms memory t = _terms(NONCE);
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(t);
        _authorize(p);
        address[3] memory others = [payer, stranger, relayer];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(AuthCaptureProofOperator.NotReceiver.selector);
            op.voidByReceiver(p);
        }
        vm.expectEmit(address(op));
        emit AuthCaptureProofOperator.VoidedByReceiver(escrow.getHash(p));
        vm.prank(receiver);
        op.voidByReceiver(p);
        assertEq(token.balanceOf(payer), 10 * AMOUNT, "payer has it back");
        vm.expectRevert(abi.encodeWithSelector(AuthCaptureEscrow.ZeroAmount.selector));
        _capture(p, t);
    }

    // ── Terms ───────────────────────────────────────────────────────────────────────────────────

    function test_the_terms_authorizer_and_the_bound_salt_follow_the_schemes_derivation() public view {
        address a = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encode(
                            keccak256("ProofGatedTerms(bytes32 verifierId,bytes32 inputCommitment)"), soloId, commitment
                        )
                    )
                )
            )
        );
        assertEq(op.termsAuthorizer(soloId, commitment), a, "terms authorizer");
        bytes32 tag =
            keccak256("x402AuthCaptureSaltBinding(address receiverAuthorizer,address policy,uint256 saltNonce)");
        assertEq(op.SALT_BINDING_TYPEHASH(), tag, "the scheme's tag");
        assertEq(
            op.boundSalt(soloId, commitment, NONCE),
            uint256(keccak256(abi.encode(tag, a, address(0), NONCE))),
            "salt as the scheme derives it with receiverAuthorizer = terms authorizer, policy = 0"
        );
    }
}
