// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GasMeter} from "./GasMeter.sol";
import {ProofCapturePolicyBase} from "./ProofCapturePolicyBase.sol";
import {IAuthCaptureEscrow} from "../src/IAuthCaptureEscrow.sol";

interface IEscrowStoresP {
    function getTokenStore(address operator) external view returns (address);
    function tokenStoreImplementation() external view returns (address);
}

/// Gas of the reason-returning proof policy on the `"custom"` route (`PolicyCaptureOperator` +
/// `ProofCapturePolicy`), measured as `test/AuthCaptureGas.t.sol` measures `captureWithProof`: real
/// solo proof, Osaka schedule, x402's escrow built from source, the test token, every account cold.
/// "Steady": the operator's token store exists and holds another payment, and the receiver has been
/// paid before. Payments differ only in the server's receiver authorizer, which changes the salt.
abstract contract ProofCapturePolicyGasBase is ProofCapturePolicyBase, GasMeter {
    IAuthCaptureEscrow.PaymentInfo internal toAuthorize;
    bytes internal toAuthorizeSig;
    IAuthCaptureEscrow.PaymentInfo internal toCapture;
    IAuthCaptureEscrow.PaymentInfo internal toCharge;
    bytes internal toChargeSig;
    address internal tokenStore;
    address internal tokenStoreImpl;
    uint256 internal receiverBefore;
    address internal tokenImpl; // a proxied token's implementation; zero for the test token

    function _auth(uint256 i) internal pure returns (address) {
        return address(uint160(0xA000 + i));
    }

    function _p(uint256 i) internal view returns (IAuthCaptureEscrow.PaymentInfo memory) {
        return _policyPayment(_auth(i), address(0), soloId, commitment);
    }

    function _setUpPayments() internal {
        _fund(payer, 90 * AMOUNT);
        IAuthCaptureEscrow.PaymentInfo memory p0 = _p(1);
        _policyAuthorize(p0);
        pop.captureWithPolicy(p0, _goodData(_auth(1)));
        _policyAuthorize(_p(2)); // another hold stays in the store
        toAuthorize = _p(10);
        toAuthorizeSig = _sign(toAuthorize, payerKey);
        toCapture = _p(11);
        _policyAuthorize(toCapture);
        toCharge = _p(12);
        toChargeSig = _sign(toCharge, payerKey);
        tokenStore = IEscrowStoresP(ESCROW).getTokenStore(address(pop));
        tokenStoreImpl = IEscrowStoresP(ESCROW).tokenStoreImplementation();
        receiverBefore = token.balanceOf(receiver);
    }

    function _cold() internal view returns (address[] memory a) {
        a = new address[](13);
        (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12]) =
        (
            address(pop),
            address(policy),
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

    function _authorizeTx() internal returns (TxGas memory) {
        bytes memory data = abi.encodeCall(pop.authorize, (toAuthorize, AMOUNT, COLLECTOR, toAuthorizeSig));
        return _measure(relayer, address(pop), data, _cold());
    }

    function _captureTx() internal returns (TxGas memory) {
        bytes memory data = abi.encodeCall(pop.captureWithPolicy, (toCapture, _goodData(_auth(11))));
        return _measure(relayer, address(pop), data, _cold());
    }

    function _chargeTx() internal returns (TxGas memory) {
        bytes memory data =
            abi.encodeCall(pop.chargeWithPolicy, (toCharge, COLLECTOR, toChargeSig, _goodData(_auth(12))));
        return _measure(relayer, address(pop), data, _cold());
    }
}

contract ProofCapturePolicyGasSteadyTest is ProofCapturePolicyGasBase {
    function setUp() public override {
        super.setUp();
        _setUpPayments();
    }

    function test_gas_policy_authorize_steady() public {
        TxGas memory g = _authorizeTx();
        _log("authorize through the policy operator, steady", g);
        (uint120 held,) = _held(toAuthorize);
        assertEq(held, AMOUNT, "the measured call placed the hold");
        assertLe(g.total, 126_700, "pin: measured 126,385");
    }

    function test_gas_capture_with_policy_steady() public {
        TxGas memory g = _captureTx();
        _log("captureWithPolicy, steady", g);
        assertEq(token.balanceOf(receiver), receiverBefore + AMOUNT, "the measured call paid");
        assertLe(g.total, 740_200, "pin: measured 739,872");
    }

    function test_gas_charge_with_policy_steady() public {
        TxGas memory g = _chargeTx();
        _log("chargeWithPolicy, steady", g);
        assertEq(token.balanceOf(receiver), receiverBefore + AMOUNT, "the measured call paid");
        assertLe(g.total, 817_100, "pin: measured 816,774");
    }
}

/// The same with Circle's USDC on a fork of Base Sepolia, opt-in like the other fork tests:
///
///     FORK_RPC_URL=https://sepolia.base.org FORK_BLOCK=62638490 \
///         forge test --match-path test/ProofCapturePolicyGas.t.sol -vv
contract ProofCapturePolicyForkGasTest is ProofCapturePolicyGasBase {
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
        _setUpPayments();
    }

    function _placeToken() internal override {}

    function _fund(address to, uint256 amount) internal override {
        deal(TOKEN, to, token.balanceOf(to) + amount);
    }

    modifier onlyForked() {
        if (!forked) vm.skip(true);
        _;
    }

    function test_fork_gas_policy_authorize_steady() public onlyForked {
        TxGas memory g = _authorizeTx();
        _log("USDC authorize through the policy operator, steady", g);
        (uint120 held,) = _held(toAuthorize);
        assertEq(held, AMOUNT, "held");
    }

    function test_fork_gas_capture_with_policy_steady() public onlyForked {
        TxGas memory g = _captureTx();
        _log("USDC captureWithPolicy, steady", g);
        assertEq(token.balanceOf(receiver), receiverBefore + AMOUNT, "paid");
    }

    function test_fork_gas_charge_with_policy_steady() public onlyForked {
        TxGas memory g = _chargeTx();
        _log("USDC chargeWithPolicy, steady", g);
        assertEq(token.balanceOf(receiver), receiverBefore + AMOUNT, "paid");
    }
}
