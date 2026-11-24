// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AuthCaptureBase, IEscrowReclaim} from "./AuthCaptureBase.sol";
import {AuthCaptureProofOperator} from "../src/AuthCaptureProofOperator.sol";
import {IAuthCaptureEscrow} from "../src/IAuthCaptureEscrow.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";

/// A payment signed by x402's own auth-capture client (`AuthCaptureEvmScheme` at x402 3eb54b2,
/// unmodified), replayed against the escrow built from source. The payment is the one the
/// end-to-end run captured (x402/client/e2e.ts), read from x402/.state/stock-client-payment.json.
/// That file is local and not tracked, so these tests skip when it is absent, as the fork tests do.
contract AuthCaptureStockClientTest is AuthCaptureBase {
    string internal constant FIXTURE = "x402/.state/stock-client-payment.json";

    bool internal present;
    IAuthCaptureEscrow.PaymentInfo internal p;
    bytes internal sig;
    uint256 internal saltNonce;
    address internal advertisedAuthorizer;

    function setUp() public override {
        super.setUp();
        present = vm.exists(FIXTURE);
        if (!present) return;
        string memory j = vm.readFile(FIXTURE);
        address at = vm.parseJsonAddress(j, ".accepted.extra.captureAuthorizer");
        deployCodeTo("AuthCaptureProofOperator.sol:AuthCaptureProofOperator", abi.encode(ESCROW, registry), at);
        op = AuthCaptureProofOperator(at);
        p = IAuthCaptureEscrow.PaymentInfo({
            operator: at,
            payer: vm.parseJsonAddress(j, ".paymentInfo.payer"),
            receiver: vm.parseJsonAddress(j, ".paymentInfo.receiver"),
            token: vm.parseJsonAddress(j, ".paymentInfo.token"),
            maxAmount: uint120(vm.parseJsonUint(j, ".paymentInfo.maxAmount")),
            preApprovalExpiry: uint48(vm.parseJsonUint(j, ".paymentInfo.preApprovalExpiry")),
            authorizationExpiry: uint48(vm.parseJsonUint(j, ".paymentInfo.authorizationExpiry")),
            refundExpiry: uint48(vm.parseJsonUint(j, ".paymentInfo.refundExpiry")),
            minFeeBps: uint16(vm.parseJsonUint(j, ".paymentInfo.minFeeBps")),
            maxFeeBps: uint16(vm.parseJsonUint(j, ".paymentInfo.maxFeeBps")),
            feeReceiver: vm.parseJsonAddress(j, ".paymentInfo.feeReceiver"),
            salt: vm.parseJsonUint(j, ".paymentInfo.salt")
        });
        sig = vm.parseJsonBytes(j, ".payload.signature");
        saltNonce = vm.parseJsonUint(j, ".payload.saltNonce");
        advertisedAuthorizer = vm.parseJsonAddress(j, ".accepted.extra.receiverAuthorizer");
        assertEq(vm.parseJsonBytes32(j, ".accepted.extra.verifierId"), soloId, "same verifier entry as here");
        assertEq(vm.parseJsonBytes32(j, ".accepted.extra.inputCommitment"), commitment, "same input commitment");
        token.mint(p.payer, 10 * AMOUNT);
        vm.warp(p.preApprovalExpiry - 600); // when it was signed
    }

    modifier withFixture() {
        if (!present) vm.skip(true);
        _;
    }

    function _t() internal view returns (AuthCaptureProofOperator.Terms memory) {
        return _terms(saltNonce);
    }

    function test_x402s_client_bound_the_terms_through_receiver_authorizer() public withFixture {
        assertEq(
            advertisedAuthorizer, op.termsAuthorizer(soloId, commitment), "the server advertised the terms address"
        );
        assertEq(p.salt, op.boundSalt(soloId, commitment, saltNonce), "the client's salt binds it, unchanged");
    }

    function test_x402s_client_payment_is_held_and_captured_only_with_a_valid_proof() public withFixture {
        vm.prank(relayer);
        op.authorize(p, p.maxAmount, COLLECTOR, sig);
        (uint120 capturable,) = _held(p);
        assertEq(capturable, AMOUNT, "held");

        bytes memory bad = bytes.concat(proof);
        bad[100] = bytes1(uint8(bad[100]) ^ 0x01);
        vm.expectRevert(AuthCaptureProofOperator.ProofInvalid.selector);
        op.captureWithProof(p, _t(), soloEntry, output, bad);
        VerifierEntry memory e = soloEntry;
        e.verifyGas += 1;
        vm.expectRevert(abi.encodeWithSelector(AuthCaptureProofOperator.VerifierUnavailable.selector, soloId));
        op.captureWithProof(p, _t(), e, output, proof);
        assertEq(token.balanceOf(p.receiver), 0, "nothing paid on a failed check");

        op.captureWithProof(p, _t(), soloEntry, output, proof);
        assertEq(token.balanceOf(p.receiver), AMOUNT, "paid with the proof");
        assertEq(token.balanceOf(p.payer), 9 * AMOUNT, "the payer paid once");
    }

    function test_x402s_client_payment_left_unproven_is_reclaimed_after_the_deadline() public withFixture {
        op.authorize(p, p.maxAmount, COLLECTOR, sig);
        vm.warp(p.authorizationExpiry);
        vm.prank(p.payer);
        IEscrowReclaim(ESCROW).reclaim(p);
        assertEq(token.balanceOf(p.payer), 10 * AMOUNT, "all back");
    }
}
