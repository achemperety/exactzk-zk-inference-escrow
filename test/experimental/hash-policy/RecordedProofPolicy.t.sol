// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AuthCaptureBase} from "../../AuthCaptureBase.sol";
import {GasMeter} from "../../GasMeter.sol";
import {Fixtures} from "../../fixtures/Fixtures.sol";
import {FixturesK8} from "../../fixtures/FixturesK8.sol";
import {IAuthCaptureEscrow} from "../../../src/IAuthCaptureEscrow.sol";
import {PolicyStatus} from "../../../src/ICapturePolicyStatus.sol";
import {PolicyCaptureOperator} from "../../../src/PolicyCaptureOperator.sol";
import {ProofCheck, ProofStatus} from "../../../src/ProofCheck.sol";
import {RecordedProofPolicy} from "./RecordedProofPolicy.sol";

interface IEscrowStoresR {
    function getTokenStore(address operator) external view returns (address);
    function tokenStoreImplementation() external view returns (address);
}

/// PROTOTYPE: hash-only `policyData`. The proof is checked once by `recordCheck`; the policy hook
/// reads the recorded result by hash. Against x402's escrow built from source, on the `"custom"`
/// route through the unchanged `PolicyCaptureOperator`.
abstract contract RecordedProofPolicyBase is AuthCaptureBase {
    RecordedProofPolicy internal rpol;
    PolicyCaptureOperator internal rop;
    address internal serverAuthorizer = makeAddr("the server's receiver authorizer");

    function setUp() public virtual override {
        super.setUp();
        rpol = new RecordedProofPolicy(registry);
        rop = new PolicyCaptureOperator(escrow, rpol);
    }

    function _payment(address authorizer, bytes32 inputCommitment)
        internal
        view
        returns (IAuthCaptureEscrow.PaymentInfo memory p)
    {
        p = _paymentWithSalt(rpol.boundSalt(authorizer, address(0), soloId, inputCommitment));
        p.operator = address(rop);
    }

    function _payment() internal view returns (IAuthCaptureEscrow.PaymentInfo memory) {
        return _payment(serverAuthorizer, commitment);
    }

    function _authorizeHold(IAuthCaptureEscrow.PaymentInfo memory p) internal {
        rop.authorize(p, p.maxAmount, COLLECTOR, _sign(p, payerKey));
    }

    function _hashData(address authorizer, bytes32 inputCommitment, bytes memory out, bytes memory prf)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            RecordedProofPolicy.HashData({
                receiverAuthorizer: authorizer,
                policy: address(0),
                verifierId: soloId,
                inputCommitment: inputCommitment,
                proofHash: keccak256(abi.encode(out, prf))
            })
        );
    }

    function _goodData(address authorizer) internal view returns (bytes memory) {
        return _hashData(authorizer, commitment, output, proof);
    }

    /// The record's storage slot: `recorded` is the contract's only storage variable.
    function _slot(bytes32 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, uint256(0)));
    }

    function _goodKey() internal view returns (bytes32) {
        return rpol.recordKey(soloId, commitment, keccak256(abi.encode(output, proof)));
    }
}

contract RecordedProofPolicyTest is RecordedProofPolicyBase {
    function _flip(bytes memory data, uint256 index) internal pure returns (bytes memory c) {
        c = bytes.concat(data);
        c[index] = bytes1(uint8(c[index]) ^ 0x01);
    }

    function _status(IAuthCaptureEscrow.PaymentInfo memory p, bytes memory data) internal view returns (bytes32) {
        return rpol.captureStatus(p, p.maxAmount, 0, p.feeReceiver, data);
    }

    function _expectRefused(bytes32 status) internal {
        vm.expectRevert(abi.encodeWithSelector(PolicyCaptureOperator.PolicyRefused.selector, status));
    }

    function _assertHeld(IAuthCaptureEscrow.PaymentInfo memory p) internal view {
        (uint120 capturable,) = _held(p);
        assertEq(capturable, AMOUNT, "still held");
    }

    // ── The three the profile needs ─────────────────────────────────────────────────────────────

    function test_an_unrecorded_hash_is_verifier_unavailable_never_proof_invalid() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _payment();
        _authorizeHold(p);
        bytes memory good = _goodData(serverAuthorizer);
        bytes memory junk = _hashData(serverAuthorizer, commitment, output, _flip(proof, 100));
        assertEq(_status(p, good), PolicyStatus.VERIFIER_UNAVAILABLE, "the real proof, not yet recorded");
        assertEq(_status(p, junk), PolicyStatus.VERIFIER_UNAVAILABLE, "a tampered proof, not recorded");
        _expectRefused(PolicyStatus.VERIFIER_UNAVAILABLE);
        vm.prank(relayer);
        rop.captureWithPolicy(p, good);
        _assertHeld(p);
    }

    function test_a_recorded_invalid_proof_is_proof_invalid_and_does_not_block_the_real_one() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _payment();
        _authorizeHold(p);
        bytes memory bad = _flip(proof, 100);
        vm.prank(stranger);
        assertEq(uint8(rpol.recordCheck(soloId, commitment, output, bad)), uint8(ProofStatus.Invalid), "invalid");
        bytes memory badData = _hashData(serverAuthorizer, commitment, output, bad);
        assertEq(_status(p, badData), PolicyStatus.PROOF_INVALID, "recorded invalid");
        _expectRefused(PolicyStatus.PROOF_INVALID);
        rop.captureWithPolicy(p, badData);
        _assertHeld(p);

        // The record is the tampered proof's own; the real proof is checked and captures.
        assertEq(uint8(rpol.recordCheck(soloId, commitment, output, proof)), uint8(ProofStatus.Valid), "valid");
        rop.captureWithPolicy(p, _goodData(serverAuthorizer));
        assertEq(token.balanceOf(receiver), AMOUNT, "captured");
    }

    function test_a_proof_can_be_presented_again_after_verifier_unavailable() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _payment();
        _authorizeHold(p);
        bytes32 key = _goodKey();

        // The verifier's code is not the registered code: nothing can be decided, nothing is stored.
        vm.etch(SOLO, FixturesK8.verifierBytecode());
        vm.recordLogs();
        assertEq(uint8(rpol.recordCheck(soloId, commitment, output, proof)), uint8(ProofStatus.Unverifiable), "u");
        assertEq(vm.getRecordedLogs().length, 0, "no event");
        assertEq(rpol.recorded(key), 0, "nothing recorded");
        assertEq(_status(p, _goodData(serverAuthorizer)), PolicyStatus.VERIFIER_UNAVAILABLE, "still unchecked");

        // An unknown verifier id: the same.
        assertEq(
            uint8(rpol.recordCheck(keccak256("unknown"), commitment, output, proof)),
            uint8(ProofStatus.Unverifiable),
            "unknown id"
        );

        // The registered code is back: the same proof is presented again and settles.
        vm.etch(SOLO, Fixtures.verifierBytecode());
        assertEq(uint8(rpol.recordCheck(soloId, commitment, output, proof)), uint8(ProofStatus.Valid), "valid now");
        rop.captureWithPolicy(p, _goodData(serverAuthorizer));
        assertEq(token.balanceOf(receiver), AMOUNT, "captured");
    }

    // ── What else the record must hold to ───────────────────────────────────────────────────────

    function test_anyone_records_anyone_captures_and_the_output_is_in_the_record_event() public {
        IAuthCaptureEscrow.PaymentInfo memory p = _payment();
        _authorizeHold(p);
        bytes32 key = _goodKey();
        vm.expectEmit(address(rpol));
        emit RecordedProofPolicy.CheckRecorded(key, soloId, commitment, true, output);
        vm.prank(stranger);
        rpol.recordCheck(soloId, commitment, output, proof);
        assertEq(rpol.recorded(key), 1, "recorded valid");
        assertEq(_status(p, _goodData(serverAuthorizer)), PolicyStatus.AUTHORIZED, "authorized");
        vm.prank(relayer);
        rop.captureWithPolicy(p, _goodData(serverAuthorizer));
        assertEq(token.balanceOf(receiver), AMOUNT, "the receiver is paid");
        assertEq(token.balanceOf(relayer) + token.balanceOf(stranger), 0, "nobody else");
    }

    /// A valid record is about one commitment. A payment whose salt binds another commitment is not
    /// opened by it, even with the same proof hash.
    function test_a_valid_record_for_another_commitment_does_not_open_this_payment() public {
        rpol.recordCheck(soloId, commitment, output, proof);
        bytes32 other = keccak256("another input commitment");
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(serverAuthorizer, other);
        _authorizeHold(p);
        bytes memory data = _hashData(serverAuthorizer, other, output, proof); // the valid proof's hash
        assertEq(_status(p, data), PolicyStatus.VERIFIER_UNAVAILABLE, "no record for this commitment");
        _expectRefused(PolicyStatus.VERIFIER_UNAVAILABLE);
        rop.captureWithPolicy(p, data);
        _assertHeld(p);
    }

    function test_terms_the_payer_did_not_sign_are_denied_even_with_a_valid_record() public {
        rpol.recordCheck(soloId, commitment, output, proof);
        IAuthCaptureEscrow.PaymentInfo memory p = _payment();
        _authorizeHold(p);
        bytes memory wrongAuthorizer = _goodData(makeAddr("another authorizer"));
        assertEq(_status(p, wrongAuthorizer), PolicyStatus.DENIED, "salt not opened");
        _expectRefused(PolicyStatus.DENIED);
        rop.captureWithPolicy(p, wrongAuthorizer);
        _assertHeld(p);
    }

    function test_a_salt_bound_to_another_policy_is_denied() public {
        rpol.recordCheck(soloId, commitment, output, proof);
        address otherPolicy = makeAddr("another policy");
        IAuthCaptureEscrow.PaymentInfo memory p =
            _paymentWithSalt(rpol.boundSalt(serverAuthorizer, otherPolicy, soloId, commitment));
        p.operator = address(rop);
        _authorizeHold(p);
        bytes memory data = abi.encode(
            RecordedProofPolicy.HashData({
                receiverAuthorizer: serverAuthorizer,
                policy: otherPolicy,
                verifierId: soloId,
                inputCommitment: commitment,
                proofHash: keccak256(abi.encode(output, proof))
            })
        );
        assertEq(_status(p, data), PolicyStatus.DENIED, "bound to another policy");
    }

    function test_a_record_never_changes() public {
        bytes memory bad = _flip(proof, 100);
        rpol.recordCheck(soloId, commitment, output, proof);
        rpol.recordCheck(soloId, commitment, output, bad);
        // Even with the verifier's code gone, a stored result is returned as stored, and no event.
        vm.etch(SOLO, FixturesK8.verifierBytecode());
        vm.recordLogs();
        assertEq(uint8(rpol.recordCheck(soloId, commitment, output, proof)), uint8(ProofStatus.Valid), "valid");
        assertEq(uint8(rpol.recordCheck(soloId, commitment, output, bad)), uint8(ProofStatus.Invalid), "invalid");
        assertEq(vm.getRecordedLogs().length, 0, "no event");
    }

    function test_too_little_gas_reverts_and_records_nothing() public {
        vm.expectPartialRevert(ProofCheck.InsufficientGasForVerifier.selector);
        rpol.recordCheck{gas: 400_000}(soloId, commitment, output, proof);
        assertEq(rpol.recorded(_goodKey()), 0, "nothing recorded");
    }
}

/// Gas: `recordCheck` + `captureWithPolicy` against today's one-step `captureWithPolicy`
/// (`test/ProofCapturePolicyGas.t.sol`), measured the same way: real solo proof, Osaka schedule,
/// x402's escrow built from source, every account cold, steady (the operator's token store exists and
/// holds another payment; the receiver has been paid before). The record is a fresh one: its slot is
/// cleared before measuring, as for a payment with its own fresh input commitment.
abstract contract RecordedProofPolicyGasBase is RecordedProofPolicyBase, GasMeter {
    IAuthCaptureEscrow.PaymentInfo internal toCapture;
    address internal tokenStore;
    address internal tokenStoreImpl;
    uint256 internal receiverBefore;
    address internal tokenImpl;

    function _auth(uint256 i) internal pure returns (address) {
        return address(uint160(0xA000 + i));
    }

    function _setUpPayments() internal {
        _fund(payer, 90 * AMOUNT);
        IAuthCaptureEscrow.PaymentInfo memory p0 = _payment(_auth(1), commitment);
        _authorizeHold(p0);
        rpol.recordCheck(soloId, commitment, output, proof);
        rop.captureWithPolicy(p0, _goodData(_auth(1)));
        _authorizeHold(_payment(_auth(2), commitment)); // another hold stays in the store
        toCapture = _payment(_auth(11), commitment);
        _authorizeHold(toCapture);
        vm.store(address(rpol), _slot(_goodKey()), bytes32(0)); // a fresh record again
        tokenStore = IEscrowStoresR(ESCROW).getTokenStore(address(rop));
        tokenStoreImpl = IEscrowStoresR(ESCROW).tokenStoreImplementation();
        receiverBefore = token.balanceOf(receiver);
    }

    function _cold() internal view returns (address[] memory a) {
        a = new address[](13);
        (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12]) =
        (
            address(rop),
            address(rpol),
            ESCROW,
            COLLECTOR,
            TOKEN,
            address(registry),
            address(adapter),
            SOLO,
            payer,
            receiver,
            tokenStore,
            tokenStoreImpl,
            tokenImpl
        );
    }

    function _twoSteps() internal returns (TxGas memory rec, TxGas memory cap) {
        rec = _measure(
            relayer, address(rpol), abi.encodeCall(rpol.recordCheck, (soloId, commitment, output, proof)), _cold()
        );
        assertEq(rpol.recorded(_goodKey()), 1, "the measured call recorded");
        cap = _measure(
            relayer, address(rop), abi.encodeCall(rop.captureWithPolicy, (toCapture, _goodData(_auth(11)))), _cold()
        );
        assertEq(token.balanceOf(receiver), receiverBefore + AMOUNT, "the measured call paid");
    }
}

contract RecordedProofPolicyGasTest is RecordedProofPolicyGasBase {
    function setUp() public override {
        super.setUp();
        _setUpPayments();
    }

    function test_gas_record_check_then_capture_steady() public {
        (TxGas memory rec, TxGas memory cap) = _twoSteps();
        _log("recordCheck, a fresh record", rec);
        _log("captureWithPolicy, hash-only policyData, steady", cap);
        emit log_named_uint("recordCheck + captureWithPolicy", rec.total + cap.total);
        assertLe(rec.total + cap.total, 1_000_000, "a loose bound; the figure is recorded in MUTATIONS.md");
    }
}

/// The same with Circle's USDC on a fork of Base Sepolia, opt-in like the other fork tests:
///
///     FORK_RPC_URL=https://sepolia.base.org FORK_BLOCK=62638490 \
///         forge test --match-path 'test/experimental/hash-policy/*.t.sol' -vv
contract RecordedProofPolicyForkGasTest is RecordedProofPolicyGasBase {
    bool internal forked;

    function setUp() public override {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blockNumber = vm.envOr("FORK_BLOCK", uint256(0));
        if (blockNumber == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNumber);
        forked = true;
        super.setUp();
        tokenImpl = address(uint160(uint256(vm.load(TOKEN, keccak256("org.zeppelinos.proxy.implementation")))));
        _setUpPayments();
    }

    function _placeToken() internal override {}

    function _fund(address to, uint256 amount) internal override {
        deal(TOKEN, to, token.balanceOf(to) + amount);
    }

    function test_fork_gas_record_check_then_capture_steady() public {
        if (!forked) vm.skip(true);
        (TxGas memory rec, TxGas memory cap) = _twoSteps();
        _log("USDC recordCheck, a fresh record", rec);
        _log("USDC captureWithPolicy, hash-only policyData, steady", cap);
        emit log_named_uint("USDC recordCheck + captureWithPolicy", rec.total + cap.total);
    }
}
