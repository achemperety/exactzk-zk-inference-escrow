// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEscrowReclaim} from "./AuthCaptureBase.sol";
import {ProofCapturePolicyBase} from "./ProofCapturePolicyBase.sol";
import {Fixtures} from "./fixtures/Fixtures.sol";
import {FixturesK8} from "./fixtures/FixturesK8.sol";
import {IAuthCaptureEscrow} from "../src/IAuthCaptureEscrow.sol";
import {ICapturePolicyStatus, PolicyStatus} from "../src/ICapturePolicyStatus.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";
import {PolicyCaptureOperator} from "../src/PolicyCaptureOperator.sol";
import {ProofCheck} from "../src/ProofCheck.sol";
import {AlwaysTrueAdapter, GasGaugeAdapter} from "./mocks/Mocks.sol";
import {AuthCaptureEscrow} from "lib/commerce-payments/src/AuthCaptureEscrow.sol";

/// A policy that answers whatever word it is told to: the operator's side of the mapping, apart from
/// any proof.
contract WordPolicy is ICapturePolicyStatus {
    bytes32 public word;

    function set(bytes32 w) external {
        word = w;
    }

    function captureStatus(IAuthCaptureEscrow.PaymentInfo calldata, uint256, uint256, address, bytes calldata)
        external
        view
        returns (bytes32)
    {
        return word;
    }

    function chargeStatus(IAuthCaptureEscrow.PaymentInfo calldata, uint256, uint256, address, bytes calldata)
        external
        view
        returns (bytes32)
    {
        return word;
    }
}

/// `ProofCapturePolicy` through `PolicyCaptureOperator` against x402's auth-capture escrow built from
/// source (base/commerce-payments v1.1.0), with the real solo proof.
contract ProofCapturePolicyTest is ProofCapturePolicyBase {
    function _flip(bytes memory data, uint256 index) internal pure returns (bytes memory c) {
        c = bytes.concat(data);
        c[index] = bytes1(uint8(c[index]) ^ 0x01);
    }

    function _status(IAuthCaptureEscrow.PaymentInfo memory p, bytes memory data) internal view returns (bytes32) {
        return policy.captureStatus(p, p.maxAmount, 0, p.feeReceiver, data);
    }

    function _expectRefused(bytes32 status) internal {
        vm.expectRevert(abi.encodeWithSelector(PolicyCaptureOperator.PolicyRefused.selector, status));
    }

    function _assertHeld(IAuthCaptureEscrow.PaymentInfo memory p) internal view {
        (uint120 capturable, uint120 refundable) = _held(p);
        assertEq(capturable, AMOUNT, "still held");
        assertEq(refundable, 0, "nothing captured");
        assertEq(token.balanceOf(receiver), 0, "receiver unpaid");
        assertEq(token.balanceOf(payer), 9 * AMOUNT, "payer");
    }

    function _dataWith(VerifierEntry memory e, bytes memory out, bytes memory prf)
        internal
        view
        returns (bytes memory)
    {
        return _proofData(serverAuthorizer, address(0), soloId, commitment, e, out, prf);
    }

    // ── Authorized ──────────────────────────────────────────────────────────────────────────────

    function test_a_valid_proof_authorizes_and_anyone_captures_for_the_receiver() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        vm.prank(relayer);
        _policyAuthorize(p);
        _assertHeld(p);
        assertEq(_status(p, _goodData()), PolicyStatus.AUTHORIZED, "status");

        bytes32 h = escrow.getHash(p);
        bytes memory data = _goodData();
        vm.expectEmit(ESCROW);
        emit AuthCaptureEscrow.PaymentCaptured(h, AMOUNT, 0, address(0));
        vm.expectEmit(address(pop));
        emit PolicyCaptureOperator.CapturedWithPolicy(h, AMOUNT, keccak256(data));
        vm.prank(stranger);
        pop.captureWithPolicy(p, data);

        (uint120 capturable, uint120 refundable) = _held(p);
        assertEq(capturable, 0, "hold spent");
        assertEq(refundable, AMOUNT, "captured");
        assertEq(token.balanceOf(receiver), AMOUNT, "receiver paid");
        assertEq(token.balanceOf(stranger), 0, "the caller gets nothing");
    }

    function test_the_fee_taken_is_the_payers_minimum() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        p.minFeeBps = 100;
        p.maxFeeBps = 300;
        p.feeReceiver = feeRecipient;
        _policyAuthorize(p);
        pop.captureWithPolicy(p, _goodData());
        assertEq(token.balanceOf(feeRecipient), 10_000, "1 %, the minimum");
        assertEq(token.balanceOf(receiver), AMOUNT - 10_000, "receiver");
    }

    function test_a_hold_is_captured_once() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        _policyAuthorize(p);
        pop.captureWithPolicy(p, _goodData());
        vm.expectRevert(AuthCaptureEscrow.ZeroAmount.selector);
        pop.captureWithPolicy(p, _goodData());
        assertEq(token.balanceOf(receiver), AMOUNT, "paid once");
    }

    // ── ProofInvalid ────────────────────────────────────────────────────────────────────────────

    function test_an_invalid_proof_is_refused_with_proof_invalid() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        _policyAuthorize(p);

        bytes memory tampered = _dataWith(soloEntry, output, _flip(proof, 100));
        bytes memory other = bytes.concat(output);
        _setWord(other, 2, _word(other, 2) + 1);
        bytes memory wrongOutput = _dataWith(soloEntry, other, proof);
        bytes memory noProof = _dataWith(soloEntry, output, "");
        bytes memory shortOutput = _dataWith(soloEntry, bytes.concat(output, hex"00"), proof);

        bytes[4] memory cases = [tampered, wrongOutput, noProof, shortOutput];
        for (uint256 i = 0; i < cases.length; i++) {
            assertEq(_status(p, cases[i]), PolicyStatus.PROOF_INVALID, "status");
            _expectRefused(PolicyStatus.PROOF_INVALID);
            pop.captureWithPolicy(p, cases[i]);
        }
        _assertHeld(p);
    }

    // ── VerifierUnavailable, never ProofInvalid ─────────────────────────────────────────────────

    function test_an_unknown_entry_is_refused_with_verifier_unavailable_never_proof_invalid() public {
        // The payer signed for a verifier id nobody registered.
        bytes32 unknownId = keccak256("a verifier nobody registered");
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment(serverAuthorizer, address(0), unknownId, commitment);
        _policyAuthorize(p);
        bytes memory valid = _proofData(serverAuthorizer, address(0), unknownId, commitment, soloEntry, output, proof);
        bytes memory tampered =
            _proofData(serverAuthorizer, address(0), unknownId, commitment, soloEntry, output, _flip(proof, 100));
        for (uint256 i = 0; i < 2; i++) {
            bytes memory data = i == 0 ? valid : tampered;
            assertEq(_status(p, data), PolicyStatus.VERIFIER_UNAVAILABLE, "unknown id");
            _expectRefused(PolicyStatus.VERIFIER_UNAVAILABLE);
            pop.captureWithPolicy(p, data);
        }

        // A known id with an entry that is not its registered entry.
        IAuthCaptureEscrow.PaymentInfo memory q = _policyPayment();
        _policyAuthorize(q);
        VerifierEntry memory e = soloEntry;
        e.verifyGas += 1;
        bytes[2] memory cases = [_dataWith(e, output, proof), _dataWith(e, output, _flip(proof, 100))];
        for (uint256 i = 0; i < cases.length; i++) {
            assertEq(_status(q, cases[i]), PolicyStatus.VERIFIER_UNAVAILABLE, "not the registered entry");
            _expectRefused(PolicyStatus.VERIFIER_UNAVAILABLE);
            pop.captureWithPolicy(q, cases[i]);
        }
        (uint120 held,) = _held(q);
        assertEq(held, AMOUNT, "still held");
    }

    function test_changed_code_is_refused_with_verifier_unavailable_never_proof_invalid() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        _policyAuthorize(p);
        bytes[2] memory cases = [_goodData(), _dataWith(soloEntry, output, _flip(proof, 100))];

        // The verifier's code is not the registered code.
        vm.etch(SOLO, FixturesK8.verifierBytecode());
        for (uint256 i = 0; i < cases.length; i++) {
            assertEq(_status(p, cases[i]), PolicyStatus.VERIFIER_UNAVAILABLE, "target code changed");
            _expectRefused(PolicyStatus.VERIFIER_UNAVAILABLE);
            pop.captureWithPolicy(p, cases[i]);
        }
        vm.etch(SOLO, _soloCode());

        // The adapter's code is not the registered code.
        bytes memory adapterCode = address(adapterV2).code;
        vm.etch(address(adapterV2), hex"600160005260206000f3");
        for (uint256 i = 0; i < cases.length; i++) {
            assertEq(_status(p, cases[i]), PolicyStatus.VERIFIER_UNAVAILABLE, "adapter code changed");
            _expectRefused(PolicyStatus.VERIFIER_UNAVAILABLE);
            pop.captureWithPolicy(p, cases[i]);
        }
        vm.etch(address(adapterV2), adapterCode);
        _assertHeld(p);
    }

    // ── A refusal refuses the attempt, not the authorization ────────────────────────────────────

    function test_a_refused_attempt_leaves_the_authorization_capturable() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        _policyAuthorize(p);

        _expectRefused(PolicyStatus.PROOF_INVALID);
        pop.captureWithPolicy(p, _dataWith(soloEntry, output, _flip(proof, 100)));
        vm.etch(SOLO, FixturesK8.verifierBytecode());
        _expectRefused(PolicyStatus.VERIFIER_UNAVAILABLE);
        pop.captureWithPolicy(p, _goodData());
        vm.etch(SOLO, _soloCode());
        _expectRefused(PolicyStatus.DENIED);
        pop.captureWithPolicy(p, _goodData(stranger));
        _assertHeld(p);

        // Up to the last second before the capture deadline, the valid proof still captures.
        vm.warp(CAPTURE_DEADLINE - 1);
        pop.captureWithPolicy(p, _goodData());
        assertEq(token.balanceOf(receiver), AMOUNT, "captured after three refusals");
    }

    function test_after_refusals_the_payer_reclaims_from_the_capture_deadline_on() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        _policyAuthorize(p);
        _expectRefused(PolicyStatus.PROOF_INVALID);
        pop.captureWithPolicy(p, _dataWith(soloEntry, output, _flip(proof, 100)));
        vm.etch(SOLO, FixturesK8.verifierBytecode());
        _expectRefused(PolicyStatus.VERIFIER_UNAVAILABLE);
        pop.captureWithPolicy(p, _goodData());
        vm.etch(SOLO, _soloCode());

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(AuthCaptureEscrow.BeforeAuthorizationExpiry.selector, uint48(T0), CAPTURE_DEADLINE)
        );
        IEscrowReclaim(ESCROW).reclaim(p);

        vm.warp(CAPTURE_DEADLINE);
        // From the deadline on, not even a valid proof captures.
        vm.expectRevert(
            abi.encodeWithSelector(
                AuthCaptureEscrow.AfterAuthorizationExpiry.selector, CAPTURE_DEADLINE, CAPTURE_DEADLINE
            )
        );
        pop.captureWithPolicy(p, _goodData());
        vm.prank(payer);
        IEscrowReclaim(ESCROW).reclaim(p);
        assertEq(token.balanceOf(payer), 10 * AMOUNT, "payer has it all back");
        assertEq(token.balanceOf(receiver), 0, "receiver unpaid");
    }

    // ── Denied: the data does not open this payment's salt ──────────────────────────────────────

    function test_terms_the_payer_did_not_sign_are_denied_not_proof_invalid() public {
        // The payer signed for another input commitment; the real proof is for `commitment`.
        bytes32 otherCommitment = bytes32(uint256(commitment) ^ 1);
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment(serverAuthorizer, address(0), soloId, otherCommitment);
        _policyAuthorize(p);
        assertEq(_status(p, _goodData()), PolicyStatus.DENIED, "valid proof, other terms");
        _expectRefused(PolicyStatus.DENIED);
        pop.captureWithPolicy(p, _goodData());

        // The signed terms with a proof that does not verify for them: invalid, now that they open.
        bytes memory signedTerms =
            _proofData(serverAuthorizer, address(0), soloId, otherCommitment, soloEntry, output, proof);
        assertEq(_status(p, signedTerms), PolicyStatus.PROOF_INVALID, "signed terms, proof for others");

        // The right terms, opened with the wrong authorizer or a policy the payment does not name.
        IAuthCaptureEscrow.PaymentInfo memory q = _policyPayment();
        _policyAuthorize(q);
        assertEq(_status(q, _goodData(stranger)), PolicyStatus.DENIED, "wrong authorizer");
        bytes memory asPolicyType =
            _proofData(serverAuthorizer, address(policy), soloId, commitment, soloEntry, output, proof);
        assertEq(_status(q, asPolicyType), PolicyStatus.DENIED, "bound with policy zero, opened as the policy type");
    }

    function test_a_salt_bound_to_another_policy_is_denied() public {
        // Even when the data opens the salt exactly, a policy address that is neither zero nor this
        // policy is refused.
        address otherPolicy = makeAddr("another policy");
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment(serverAuthorizer, otherPolicy, soloId, commitment);
        _policyAuthorize(p);
        bytes memory data = _proofData(serverAuthorizer, otherPolicy, soloId, commitment, soloEntry, output, proof);
        assertEq(_status(p, data), PolicyStatus.DENIED, "another policy");
        _expectRefused(PolicyStatus.DENIED);
        pop.captureWithPolicy(p, data);
    }

    /// The same policy answers for a payment bound as the reserved `"policy"` type binds it, with
    /// `extra.policy` set to the policy.
    function test_a_payment_bound_with_the_policy_address_is_answered_too() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment(serverAuthorizer, address(policy), soloId, commitment);
        _policyAuthorize(p);
        bytes memory data = _proofData(serverAuthorizer, address(policy), soloId, commitment, soloEntry, output, proof);
        assertEq(_status(p, data), PolicyStatus.AUTHORIZED, "authorized");
        pop.captureWithPolicy(p, data);
        assertEq(token.balanceOf(receiver), AMOUNT, "captured");
    }

    // ── Charge ──────────────────────────────────────────────────────────────────────────────────

    function test_charge_with_a_valid_proof_pays_the_receiver_in_one_step() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        bytes memory data = _goodData();
        assertEq(policy.chargeStatus(p, AMOUNT, 0, address(0), data), PolicyStatus.AUTHORIZED, "status");
        vm.expectEmit(address(pop));
        emit PolicyCaptureOperator.ChargedWithPolicy(escrow.getHash(p), AMOUNT, keccak256(data));
        vm.prank(stranger);
        pop.chargeWithPolicy(p, COLLECTOR, _sign(p, payerKey), data);
        assertEq(token.balanceOf(receiver), AMOUNT, "receiver paid");
        assertEq(token.balanceOf(payer), 9 * AMOUNT, "payer");
    }

    function test_a_refused_charge_moves_nothing_and_the_authorization_stays_usable() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        bytes memory sig = _sign(p, payerKey);
        bytes memory tampered = _dataWith(soloEntry, output, _flip(proof, 100));
        assertEq(policy.chargeStatus(p, AMOUNT, 0, address(0), tampered), PolicyStatus.PROOF_INVALID, "invalid");
        _expectRefused(PolicyStatus.PROOF_INVALID);
        pop.chargeWithPolicy(p, COLLECTOR, sig, tampered);

        vm.etch(SOLO, FixturesK8.verifierBytecode());
        assertEq(
            policy.chargeStatus(p, AMOUNT, 0, address(0), _goodData()), PolicyStatus.VERIFIER_UNAVAILABLE, "unavailable"
        );
        _expectRefused(PolicyStatus.VERIFIER_UNAVAILABLE);
        pop.chargeWithPolicy(p, COLLECTOR, sig, _goodData());
        vm.etch(SOLO, _soloCode());

        assertEq(token.balanceOf(payer), 10 * AMOUNT, "nothing moved");
        pop.chargeWithPolicy(p, COLLECTOR, sig, _goodData());
        assertEq(token.balanceOf(receiver), AMOUNT, "the same authorization, now with a valid proof");
    }

    // ── The boolean hooks and ERC-165 ───────────────────────────────────────────────────────────

    function test_the_boolean_hooks_are_true_only_for_authorized() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        bytes memory tampered = _dataWith(soloEntry, output, _flip(proof, 100));
        assertTrue(policy.authorizeCapture(p, AMOUNT, 0, address(0), _goodData()), "capture, valid");
        assertTrue(policy.authorizeCharge(p, AMOUNT, 0, address(0), _goodData()), "charge, valid");
        assertFalse(policy.authorizeCapture(p, AMOUNT, 0, address(0), tampered), "capture, invalid");
        assertFalse(policy.authorizeCharge(p, AMOUNT, 0, address(0), tampered), "charge, invalid");
        assertFalse(policy.authorizeCapture(p, AMOUNT, 0, address(0), _goodData(stranger)), "capture, denied");
        vm.etch(SOLO, FixturesK8.verifierBytecode());
        assertFalse(policy.authorizeCapture(p, AMOUNT, 0, address(0), _goodData()), "capture, unavailable");
        assertFalse(policy.authorizeCharge(p, AMOUNT, 0, address(0), _goodData()), "charge, unavailable");
    }

    function test_supports_its_interface_and_erc165_only() public view {
        assertTrue(policy.supportsInterface(type(ICapturePolicyStatus).interfaceId), "status interface");
        assertTrue(policy.supportsInterface(0x01ffc9a7), "ERC-165");
        assertFalse(policy.supportsInterface(0xffffffff), "never 0xffffffff");
        assertEq(
            type(ICapturePolicyStatus).interfaceId,
            bytes4(policy.captureStatus.selector ^ policy.chargeStatus.selector),
            "interface id"
        );
    }

    function test_the_status_words_and_the_salt_follow_the_derivation() public view {
        assertEq(PolicyStatus.AUTHORIZED, bytes32("Authorized"), "Authorized");
        assertEq(PolicyStatus.PROOF_INVALID, bytes32("ProofInvalid"), "ProofInvalid");
        assertEq(PolicyStatus.VERIFIER_UNAVAILABLE, bytes32("VerifierUnavailable"), "VerifierUnavailable");
        assertEq(PolicyStatus.DENIED, bytes32("Denied"), "Denied");
        uint256 nonce = uint256(
            keccak256(
                abi.encode(keccak256("ProofGatedTerms(bytes32 verifierId,bytes32 inputCommitment)"), soloId, commitment)
            )
        );
        assertEq(policy.saltNonce(soloId, commitment), nonce, "salt nonce");
        uint256 salt = uint256(
            keccak256(
                abi.encode(
                    keccak256(
                        "x402AuthCaptureSaltBinding(address receiverAuthorizer,address policy,uint256 saltNonce)"
                    ),
                    serverAuthorizer,
                    address(0),
                    nonce
                )
            )
        );
        assertEq(policy.boundSalt(serverAuthorizer, address(0), soloId, commitment), salt, "salt");
    }

    // ── Gas: a short call reverts as such, never as a refusal ───────────────────────────────────

    function test_too_little_gas_reverts_with_a_typed_error_not_a_refusal() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        _policyAuthorize(p);
        bytes memory data = _goodData();
        vm.expectPartialRevert(ProofCheck.InsufficientGasForVerifier.selector);
        pop.captureWithPolicy{gas: 400_000}(p, data);
        _assertHeld(p);
        pop.captureWithPolicy{gas: 1_000_000}(p, data);
        assertEq(token.balanceOf(receiver), AMOUNT, "enough gas: captured");
    }

    /// The verifier gets exactly its entry's allowance through the policy: a gauge adapter that says
    /// yes only when it was started with the whole allowance, calibrated as in `test/ProofCheck.t.sol`.
    function test_the_verifier_receives_exactly_its_allowance_through_the_policy() public {
        uint32 allowance = 3_000_000;
        uint256 probeThreshold = allowance - 1_000;
        address probe = address(new GasGaugeAdapter(probeThreshold));
        uint256 g = probeThreshold;
        while (true) {
            (bool reached, bytes memory answer) = probe.staticcall{gas: g}(hex"00000000");
            if (reached && abi.decode(answer, (uint256)) == 1) break;
            g++;
        }
        uint256 spentBeforeLooking = g - probeThreshold;
        address gauge = address(new GasGaugeAdapter(allowance - spentBeforeLooking));
        (bool ok, bytes memory ret) = gauge.staticcall{gas: allowance - 1}(hex"00000000");
        assertTrue(ok && abi.decode(ret, (uint256)) == 0, "gauge refuses one unit less");

        VerifierEntry memory e = _entry(gauge, address(0), 1, OUTPUT_SIZE, allowance, bytes32(0));
        bytes32 id = registry.register(e);
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment(serverAuthorizer, address(0), id, commitment);
        bytes memory data = _proofData(serverAuthorizer, address(0), id, commitment, e, output, proof);
        assertEq(_status(p, data), PolicyStatus.AUTHORIZED, "the gauge got its whole allowance");
    }

    /// Arguments that do not fit the entry are invalid even behind an adapter that accepts anything.
    function test_arguments_that_do_not_fit_the_entry_are_invalid_through_the_policy() public {
        address yes = address(new AlwaysTrueAdapter());
        VerifierEntry memory one = _entry(yes, address(0), 1, OUTPUT_SIZE, 100_000, bytes32(0));
        bytes32 oneId = registry.register(one);
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment(serverAuthorizer, address(0), oneId, commitment);
        bytes memory fits = _proofData(serverAuthorizer, address(0), oneId, commitment, one, output, proof);
        assertEq(_status(p, fits), PolicyStatus.AUTHORIZED, "fits: the adapter accepts");
        bytes memory longer =
            _proofData(serverAuthorizer, address(0), oneId, commitment, one, bytes.concat(output, hex"00"), proof);
        assertEq(_status(p, longer), PolicyStatus.PROOF_INVALID, "output one byte too long");
        bytes memory shorter = _proofData(serverAuthorizer, address(0), oneId, commitment, one, "", proof);
        assertEq(_status(p, shorter), PolicyStatus.PROOF_INVALID, "no output");

        VerifierEntry memory two = _entry(yes, address(0), 2, OUTPUT_SIZE, 100_000, bytes32(0));
        bytes32 twoId = registry.register(two);
        IAuthCaptureEscrow.PaymentInfo memory q = _policyPayment(serverAuthorizer, address(0), twoId, commitment);
        bytes memory twoLanes = _proofData(serverAuthorizer, address(0), twoId, commitment, two, output, proof);
        assertEq(_status(q, twoLanes), PolicyStatus.PROOF_INVALID, "a two-lane entry for one commitment");
    }

    // ── The operator: every word but Authorized is refused, and passed on as it is ──────────────

    function test_the_operator_refuses_every_word_but_authorized() public {
        WordPolicy words = new WordPolicy();
        PolicyCaptureOperator wop = new PolicyCaptureOperator(escrow, words);
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        p.operator = address(wop);
        wop.authorize(p, AMOUNT, COLLECTOR, _sign(p, payerKey));

        bytes32[6] memory refused = [
            bytes32(0),
            PolicyStatus.PROOF_INVALID,
            PolicyStatus.VERIFIER_UNAVAILABLE,
            PolicyStatus.DENIED,
            bytes32("authorized"),
            bytes32(type(uint256).max)
        ];
        for (uint256 i = 0; i < refused.length; i++) {
            words.set(refused[i]);
            _expectRefused(refused[i]);
            wop.captureWithPolicy(p, "");
        }
        words.set(PolicyStatus.AUTHORIZED);
        wop.captureWithPolicy(p, "");
        assertEq(token.balanceOf(receiver), AMOUNT, "authorized: captured");
    }

    function test_the_escrows_charge_is_not_reachable_without_the_policy() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        bytes memory sig = _sign(p, payerKey);
        vm.expectRevert(PolicyCaptureOperator.PolicyRequired.selector);
        pop.charge(p, AMOUNT, COLLECTOR, sig, 0, address(0));
        assertEq(token.balanceOf(payer), 10 * AMOUNT, "nothing moved");
    }

    function test_authorize_must_collect_the_full_amount() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        bytes memory sig = _sign(p, payerKey);
        vm.expectRevert(abi.encodeWithSelector(PolicyCaptureOperator.PartialAuthorization.selector, 1, AMOUNT));
        pop.authorize(p, 1, COLLECTOR, sig);
    }

    function test_a_payment_for_another_operator_cannot_be_captured_here() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        p.operator = address(op); // the proof operator of the other route
        op.authorize(p, AMOUNT, COLLECTOR, _sign(p, payerKey));
        vm.expectRevert(abi.encodeWithSelector(AuthCaptureEscrow.InvalidSender.selector, address(pop), address(op)));
        pop.captureWithPolicy(p, _goodData());
    }

    function test_only_the_receiver_can_give_the_hold_back_early() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _policyPayment();
        _policyAuthorize(p);
        address[2] memory others = [stranger, payer];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(PolicyCaptureOperator.NotReceiver.selector);
            pop.voidByReceiver(p);
        }
        vm.expectEmit(address(pop));
        emit PolicyCaptureOperator.VoidedByReceiver(escrow.getHash(p));
        vm.prank(receiver);
        pop.voidByReceiver(p);
        assertEq(token.balanceOf(payer), 10 * AMOUNT, "payer has it back");
        vm.expectRevert(AuthCaptureEscrow.ZeroAmount.selector);
        pop.captureWithPolicy(p, _goodData());
    }

    function _soloCode() internal pure returns (bytes memory) {
        return Fixtures.verifierBytecode();
    }
}
