// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GasMeter} from "./GasMeter.sol";
import {AuthCaptureBase} from "./AuthCaptureBase.sol";
import {AuthCaptureProofOperator} from "../src/AuthCaptureProofOperator.sol";
import {IAuthCaptureEscrow} from "../src/IAuthCaptureEscrow.sol";

interface IEscrowStores {
    function getTokenStore(address operator) external view returns (address);
    function tokenStoreImplementation() external view returns (address);
}

/// Gas of the auth-capture route with the real solo proof, under the Osaka schedule: x402's escrow
/// built from source (base/commerce-payments v1.1.0, compiled with this repository's settings, not
/// the authors' deploy profile), the operator, and the test token. `GasMeter` explains how a
/// transaction's gas is rebuilt; the measured call is the first thing each test does.
///
/// "Steady": the operator's token store exists and holds other payments, and the receiver has been
/// paid before. "First": the operator's first payment ever: the escrow deploys its token store
/// (a minimal clone) on the first payout, and the store's and the receiver's balances start at zero.
abstract contract AuthCaptureGasBase is AuthCaptureBase, GasMeter {
    IAuthCaptureEscrow.PaymentInfo internal toAuthorize;
    bytes internal toAuthorizeSig;
    IAuthCaptureEscrow.PaymentInfo internal toCapture;
    IAuthCaptureEscrow.PaymentInfo internal toCharge;
    bytes internal toChargeSig;
    address internal tokenStore;
    address internal tokenStoreImpl;
    address internal tokenImpl; // a proxied token's implementation; zero for the test token
    uint256 internal receiverBefore; // read in setUp: a balance read in the test would warm the token

    function _setUpPayments(bool steady, bool holdToCapture) internal {
        _fund(payer, 90 * AMOUNT);
        if (steady) {
            // An earlier payment, captured: the token store is deployed and the receiver paid.
            AuthCaptureProofOperator.Terms memory t0 = _terms(1);
            IAuthCaptureEscrow.PaymentInfo memory p0 = _payment(t0);
            _authorize(p0);
            op.captureWithProof(p0, t0, soloEntry, output, proof);
            _authorize(_payment(_terms(2))); // another hold stays in the store
        }
        toAuthorize = _payment(_terms(10));
        toAuthorizeSig = _sign(toAuthorize, payerKey);
        toCapture = _payment(_terms(11));
        if (holdToCapture) _authorize(toCapture);
        toCharge = _payment(_terms(12));
        toChargeSig = _sign(toCharge, payerKey);
        tokenStore = IEscrowStores(ESCROW).getTokenStore(address(op));
        receiverBefore = token.balanceOf(receiver);
        tokenStoreImpl = IEscrowStores(ESCROW).tokenStoreImplementation();
    }

    function _cold() internal view returns (address[] memory a) {
        a = new address[](12);
        (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11]) =
        (
            address(op),
            ESCROW,
            COLLECTOR,
            TOKEN,
            tokenImpl,
            address(registry),
            address(adapter),
            SOLO,
            payer,
            receiver,
            tokenStore,
            tokenStoreImpl
        );
    }

    function _authorizeTx() internal returns (TxGas memory) {
        bytes memory data = abi.encodeCall(op.authorize, (toAuthorize, AMOUNT, COLLECTOR, toAuthorizeSig));
        return _measure(relayer, address(op), data, _cold());
    }

    function _captureTx() internal returns (TxGas memory) {
        bytes memory data = abi.encodeCall(op.captureWithProof, (toCapture, _terms(11), soloEntry, output, proof));
        return _measure(relayer, address(op), data, _cold());
    }

    function _chargeTx() internal returns (TxGas memory) {
        bytes memory data = abi.encodeCall(
            op.chargeWithProof, (toCharge, COLLECTOR, toChargeSig, _terms(12), soloEntry, output, proof)
        );
        return _measure(relayer, address(op), data, _cold());
    }
}

contract AuthCaptureGasSteadyTest is AuthCaptureGasBase {
    function setUp() public override {
        super.setUp();
        _setUpPayments(true, true);
    }

    function test_gas_authorize_steady() public {
        TxGas memory g = _authorizeTx();
        _log("authorize through the operator, steady", g);
        (uint120 held,) = _held(toAuthorize);
        assertEq(held, AMOUNT, "the measured call placed the hold");
        assertLe(g.total, 126_700, "pin: measured 126,385");
    }

    function test_gas_capture_with_proof_steady() public {
        TxGas memory g = _captureTx();
        _log("captureWithProof, steady", g);
        assertEq(token.balanceOf(receiver), receiverBefore + AMOUNT, "the measured call paid");
        assertLe(g.total, 736_100, "pin: measured 735,804");
    }

    function test_gas_charge_with_proof_steady() public {
        TxGas memory g = _chargeTx();
        _log("chargeWithProof, steady", g);
        assertEq(token.balanceOf(receiver), receiverBefore + AMOUNT, "the measured call paid");
        assertLe(g.total, 812_700, "pin: measured 812,420");
    }
}

/// The operator's first hold: its token store's balance starts at zero.
contract AuthCaptureGasFirstHoldTest is AuthCaptureGasBase {
    function setUp() public override {
        super.setUp();
        _setUpPayments(false, false);
    }

    function test_gas_authorize_first_hold_of_the_operator() public {
        TxGas memory g = _authorizeTx();
        _log("authorize through the operator, the store's first hold", g);
        (uint120 held,) = _held(toAuthorize);
        assertEq(held, AMOUNT, "the measured call placed the hold");
        assertLe(g.total, 143_800, "pin: measured 143,485");
    }
}

/// The operator's first payout: the escrow deploys the token store, and the receiver is paid for
/// the first time.
contract AuthCaptureGasFirstPayoutTest is AuthCaptureGasBase {
    function setUp() public override {
        super.setUp();
        _setUpPayments(false, true);
    }

    function test_gas_capture_with_proof_first_payout_of_the_operator() public {
        TxGas memory g = _captureTx();
        _log("captureWithProof, first payout (token store deployed, receiver's first payment)", g);
        assertEq(token.balanceOf(receiver), receiverBefore + AMOUNT, "the measured call paid");
        assertLe(g.total, 791_100, "pin: measured 790,770");
    }
}

/// The same with Circle's USDC on a fork of Base Sepolia, opt-in like the other fork tests:
///
///     FORK_RPC_URL=https://sepolia.base.org forge test --match-path test/AuthCaptureGas.t.sol -vv
///
/// The escrow and collector built from source replace whatever is at the canonical addresses on the
/// fork; USDC is the real token.
contract AuthCaptureForkGasTest is AuthCaptureGasBase {
    bool internal forked;

    function setUp() public override {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blockNumber = vm.envOr("FORK_BLOCK", uint256(0));
        if (blockNumber == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNumber);
        forked = true;
        emit log_named_uint("forked at block", block.number);
        super.setUp();
        tokenImpl = address(uint160(uint256(vm.load(TOKEN, keccak256("org.zeppelinos.proxy.implementation")))));
        _setUpPayments(true, true);
    }

    function _placeToken() internal override {}

    function _fund(address to, uint256 amount) internal override {
        deal(TOKEN, to, token.balanceOf(to) + amount);
    }

    modifier onlyForked() {
        if (!forked) vm.skip(true);
        _;
    }

    function test_fork_gas_authorize_steady() public onlyForked {
        TxGas memory g = _authorizeTx();
        _log("USDC authorize through the operator, steady", g);
        (uint120 held,) = _held(toAuthorize);
        assertEq(held, AMOUNT, "held");
    }

    function test_fork_gas_capture_with_proof_steady() public onlyForked {
        TxGas memory g = _captureTx();
        _log("USDC captureWithProof, steady", g);
        assertEq(token.balanceOf(receiver), receiverBefore + AMOUNT, "paid");
    }

    function test_fork_gas_charge_with_proof_steady() public onlyForked {
        TxGas memory g = _chargeTx();
        _log("USDC chargeWithProof, steady", g);
        assertEq(token.balanceOf(receiver), receiverBefore + AMOUNT, "paid");
    }
}
