// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GasMeter} from "./GasMeter.sol";
import {SoloSettlementBase} from "./SoloSettlementBase.sol";
import {SoloSettlement, Terms} from "../src/SoloSettlement.sol";

/// Gas of each settlement transaction with the real solo proof, under the Osaka schedule, with
/// the test token. `GasMeter` explains how a transaction's gas is rebuilt; the same measurements
/// against the testnet's real USDC are in `SoloSettlementFork.t.sol`.
///
/// Each measured call is the first thing its test does. Everything it depends on (balances, an
/// open lock) is created in `setUp`, which runs as a separate transaction, because `vm.cool`
/// makes storage cold again but not an account that the test has already touched.
///
/// "First": the recipient's token balance starts at zero (the provider's first payment; the first
/// lock the contract holds). "Steady": every balance written was already non-zero.
abstract contract SoloGasBase is SoloSettlementBase, GasMeter {
    uint256 internal constant ONE_TX_TARGET = 775_000;
    uint256 internal constant ONE_TX_LIMIT = 795_000;
    uint256 internal constant OPEN_LIMIT = 130_000;
    uint256 internal constant ESCROW_TOTAL_LIMIT = 870_000;

    // Upper pins of the `open` figures, used to bound the escrow total in the release tests.
    uint256 internal constant OPEN_FIRST_PIN = 115_400;
    uint256 internal constant OPEN_STEADY_PIN = 98_300;

    function _cold() internal view returns (address[] memory a) {
        a = new address[](7);
        (a[0], a[1], a[2], a[3], a[4], a[5], a[6]) =
        (address(settlement), address(token), address(registry), address(adapter), SOLO, payer, provider);
    }

    function _settleTx() internal returns (TxGas memory) {
        Terms memory t = _terms("gas");
        bytes memory data =
            abi.encodeCall(SoloSettlement.settle, (t, soloEntry, VALID_BEFORE, _signPayment(t), output, proof));
        return _measure(address(settlement), data, _cold());
    }

    function _openTx() internal returns (TxGas memory) {
        Terms memory t = _terms("gas");
        return
            _measure(
                address(settlement), abi.encodeCall(SoloSettlement.open, (t, VALID_BEFORE, _signEscrow(t))), _cold()
            );
    }

    function _releaseTx() internal returns (TxGas memory) {
        bytes memory data = abi.encodeCall(SoloSettlement.release, (_terms("gas"), soloEntry, output, proof));
        return _measure(address(settlement), data, _cold());
    }

    function _refundTx() internal returns (TxGas memory) {
        vm.warp(PROVE_BY + 1);
        return _measure(address(settlement), abi.encodeCall(SoloSettlement.refund, (_terms("gas"))), _cold());
    }
}

/// The provider has never been paid and the contract holds no tokens.
contract SoloGasFirstTest is SoloGasBase {
    function test_gas_settle_first_payment_to_the_provider() public {
        TxGas memory g = _settleTx();
        _log("settle, first payment to the provider", g);
        assertEq(token.balanceOf(provider), AMOUNT, "the measured call paid");
        assertLe(g.total, ONE_TX_TARGET, "target");
        assertLe(g.total, 764_900, "pin: measured 764,628");
    }

    function test_gas_open_first_lock_held_by_the_contract() public {
        TxGas memory g = _openTx();
        _log("open, first lock held by the contract", g);
        assertEq(token.balanceOf(address(settlement)), AMOUNT, "the measured call locked");
        assertLe(g.total, OPEN_LIMIT, "open limit");
        assertLe(g.total, OPEN_FIRST_PIN, "pin: measured 115,078");
    }
}

/// The provider has been paid before and the contract holds other locks.
contract SoloGasSteadyTest is SoloGasBase {
    function setUp() public override {
        super.setUp();
        token.mint(provider, 1);
        token.mint(address(settlement), 1);
    }

    function test_gas_settle_steady() public {
        TxGas memory g = _settleTx();
        _log("settle, steady", g);
        assertEq(token.balanceOf(provider), AMOUNT + 1, "the measured call paid");
        assertLe(g.total, ONE_TX_TARGET, "target");
        assertLe(g.total, 747_800, "pin: measured 747,528");
    }

    function test_gas_open_steady() public {
        TxGas memory g = _openTx();
        _log("open, steady", g);
        assertEq(token.balanceOf(address(settlement)), AMOUNT + 1, "the measured call locked");
        assertLe(g.total, OPEN_LIMIT, "open limit");
        assertLe(g.total, OPEN_STEADY_PIN, "pin: measured 97,978");
    }
}

/// One lock open; it is the only one, and the provider has never been paid.
contract SoloGasReleaseFirstTest is SoloGasBase {
    function setUp() public override {
        super.setUp();
        _open(_terms("gas"));
    }

    function test_gas_release_first_payment_to_the_provider() public {
        TxGas memory g = _releaseTx();
        _log("release, first payment to the provider, last lock", g);
        emit log_named_uint("escrow flow, first: open pin + release", OPEN_FIRST_PIN + g.total);
        assertEq(token.balanceOf(provider), AMOUNT, "the measured call paid");
        assertLe(OPEN_FIRST_PIN + g.total, ESCROW_TOTAL_LIMIT, "escrow total limit");
        assertLe(g.total, 726_800, "pin: measured 726,516");
    }

    function test_gas_refund_last_lock() public {
        TxGas memory g = _refundTx();
        _log("refund, last lock", g);
        assertEq(token.balanceOf(payer), 10 * AMOUNT, "the measured call refunded");
        assertLe(g.total, 42_100, "pin: measured 41,805");
    }
}

/// One lock open among others, and the provider has been paid before.
contract SoloGasReleaseSteadyTest is SoloGasBase {
    function setUp() public override {
        super.setUp();
        token.mint(provider, 1);
        token.mint(address(settlement), 1);
        _open(_terms("gas"));
    }

    function test_gas_release_steady() public {
        TxGas memory g = _releaseTx();
        _log("release, steady", g);
        emit log_named_uint("escrow flow, steady: open pin + release", OPEN_STEADY_PIN + g.total);
        assertEq(token.balanceOf(provider), AMOUNT + 1, "the measured call paid");
        assertLe(OPEN_STEADY_PIN + g.total, ESCROW_TOTAL_LIMIT, "escrow total limit");
        assertLe(g.total, 714_500, "pin: measured 714,216");
    }

    function test_gas_refund_steady() public {
        TxGas memory g = _refundTx();
        _log("refund, steady", g);
        assertEq(token.balanceOf(payer), 10 * AMOUNT, "the measured call refunded");
        assertLe(g.total, 46_900, "pin: measured 46,605");
    }
}
