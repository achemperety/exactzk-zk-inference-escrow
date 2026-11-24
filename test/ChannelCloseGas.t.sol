// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GasMeter} from "./GasMeter.sol";
import {ChannelSettlementBase} from "./ChannelSettlementBase.sol";
import {ChannelSettlement, ChannelConfig} from "../src/ChannelSettlement.sol";

/// Gas of the close functions under the Osaka schedule, with the test token; `GasMeter` explains
/// the method, and `test/ChannelSettlementFork.t.sol` measures the same calls with real USDC. Each
/// measured call is the first thing its test does; everything before it happens in `setUp`.
///
/// The contract is seeded with one unit, as at deployment, so its own token balance never returns
/// to zero. "Steady": the payer already holds tokens when the call pays it. "First": the payer
/// deposited everything it had, so the call makes its token balance non-zero again. Nothing is read
/// from the token before a measured call: that would warm its account, which `vm.cool` does not undo.
/// `requestClose`, `challengeClose` and a `waive` before finalization move no tokens.
abstract contract ChannelCloseGasBase is ChannelSettlementBase, GasMeter {
    address internal fresh;
    uint256 internal freshKey;
    ChannelConfig internal steadyC; // payer 0, who keeps half its tokens
    ChannelConfig internal firstC; // a payer that deposits everything it has

    function setUp() public virtual override {
        super.setUp();
        token.mint(address(settlement), 1); // the deployment seed
        (fresh, freshKey) = makeAddrAndKey("fresh payer");
        token.mint(fresh, DEPOSIT);
        steadyC = _config(payers[0], "steady");
        firstC = _config(fresh, "first");
        _open(steadyC, payerKeys[0], DEPOSIT);
        _open(firstC, freshKey, DEPOSIT);
    }

    function _cold() internal view returns (address[] memory a) {
        a = new address[](5);
        (a[0], a[1], a[2], a[3], a[4]) = (address(settlement), address(token), payers[0], fresh, provider);
    }

    function _requestBoth() internal {
        _requestClose(steadyC);
        _requestClose(firstC);
    }

    /// Challenge both channels with a voucher that claims `cum` (`seq` 50).
    function _challengeBoth(uint256 cum) internal {
        _challenge(steadyC, payerKeys[0], _v(50, AMOUNT, cum, _c("gas", 50), block.timestamp + 1800));
        _challenge(firstC, freshKey, _v(50, AMOUNT, cum, _c("gas", 50), block.timestamp + 1800));
    }

    function _finalizeBoth() internal {
        vm.warp(T0 + CHALLENGE_WINDOW);
        settlement.finalizeClose(steadyC);
        settlement.finalizeClose(firstC);
    }

    function _finalizeData(ChannelConfig memory c) internal pure returns (bytes memory) {
        return abi.encodeCall(ChannelSettlement.finalizeClose, (c));
    }
}

contract ChannelGasRequestCloseTest is ChannelCloseGasBase {
    /// Every channel's first close request writes its cold slot from zero; there is no steady case.
    function test_gas_request_close() public {
        TxGas memory g = _measure(
            payers[0], address(settlement), abi.encodeCall(ChannelSettlement.requestClose, (steadyC)), _cold()
        );
        _log("requestClose", g);
        assertEq(uint8(_stateOf(steadyC)), uint8(ChannelSettlement.State.Closing), "the measured call closed");
        assertLe(g.total, 52_800, "pin: measured 52,541");
    }

    function _stateOf(ChannelConfig memory c) internal view returns (ChannelSettlement.State st) {
        (,,, st) = settlement.channel(_channelId(c));
    }
}

contract ChannelGasChallengeTest is ChannelCloseGasBase {
    bytes internal first;
    bytes internal raise;

    function setUp() public override {
        super.setUp();
        _requestBoth();
        ChannelSettlement.Voucher memory v = _std(3, "gas");
        first = abi.encodeCall(
            ChannelSettlement.challengeClose, (steadyC, v, _signV(payerKeys[0], _channelId(steadyC), v))
        );
        _challenge(firstC, freshKey, v);
        ChannelSettlement.Voucher memory w = _std(5, "gas");
        raise = abi.encodeCall(ChannelSettlement.challengeClose, (firstC, w, _signV(freshKey, _channelId(firstC), w)));
    }

    function test_gas_challenge_close() public {
        TxGas memory g = _measure(provider, address(settlement), first, _cold());
        _log("challengeClose", g);
        (, uint256 claimed,,) = settlement.closeState(_channelId(steadyC));
        assertEq(claimed, 3 * AMOUNT, "the measured call claimed");
        assertLe(g.total, 41_500, "pin: measured 41,243");
    }

    function test_gas_challenge_close_raising_an_earlier_claim() public {
        TxGas memory g = _measure(provider, address(settlement), raise, _cold());
        _log("challengeClose, raising an earlier claim", g);
        (, uint256 claimed,,) = settlement.closeState(_channelId(firstC));
        assertEq(claimed, 5 * AMOUNT, "the measured call raised the claim");
        assertLe(g.total, 41_500, "pin: measured 41,231");
    }
}

/// Finalization with nothing held: everything goes back to the payer and the channel is closed.
contract ChannelGasFinalizeTest is ChannelCloseGasBase {
    function setUp() public override {
        super.setUp();
        _requestBoth();
        vm.warp(T0 + CHALLENGE_WINDOW);
    }

    function test_gas_finalize_steady() public {
        uint256 before = DEPOSIT; // payer 0's balance; reading it here would warm the token
        TxGas memory g = _measure(payers[0], address(settlement), _finalizeData(steadyC), _cold());
        _log("finalizeClose, nothing held, steady", g);
        assertEq(token.balanceOf(payers[0]), before + DEPOSIT, "the measured call paid");
        assertLe(g.total, 48_800, "pin: measured 48,522");
    }

    function test_gas_finalize_payers_first_tokens() public {
        TxGas memory g = _measure(fresh, address(settlement), _finalizeData(firstC), _cold());
        _log("finalizeClose, nothing held, payer's first tokens", g);
        assertEq(token.balanceOf(fresh), DEPOSIT, "the measured call paid");
        assertLe(g.total, 65_900, "pin: measured 65,610");
    }
}

/// Finalization with three units held: the rest goes back, the channel keeps the hold.
contract ChannelGasFinalizeHoldTest is ChannelCloseGasBase {
    function setUp() public override {
        super.setUp();
        _requestBoth();
        _challengeBoth(3 * AMOUNT);
        vm.warp(T0 + CHALLENGE_WINDOW);
    }

    function test_gas_finalize_with_a_hold_steady() public {
        uint256 before = DEPOSIT; // payer 0's balance; reading it here would warm the token
        TxGas memory g = _measure(payers[0], address(settlement), _finalizeData(steadyC), _cold());
        _log("finalizeClose, with a hold, steady", g);
        assertEq(token.balanceOf(payers[0]), before + DEPOSIT - 3 * AMOUNT, "the measured call paid");
        assertLe(g.total, 48_900, "pin: measured 48,685");
    }

    function test_gas_finalize_with_a_hold_payers_first_tokens() public {
        TxGas memory g = _measure(fresh, address(settlement), _finalizeData(firstC), _cold());
        _log("finalizeClose, with a hold, payer's first tokens", g);
        assertEq(token.balanceOf(fresh), DEPOSIT - 3 * AMOUNT, "the measured call paid");
        assertLe(g.total, 66_000, "pin: measured 65,773");
    }
}

/// A hold covering the whole balance, finalized (nothing returned) and then expired.
contract ChannelGasSweepTest is ChannelCloseGasBase {
    function setUp() public override {
        super.setUp();
        _requestBoth();
        _challengeBoth(DEPOSIT);
        _finalizeBoth();
        vm.warp(T0 + CHALLENGE_WINDOW + PROVE_WINDOW + 1);
    }

    function test_gas_sweep_steady() public {
        uint256 before = DEPOSIT; // payer 0's balance; reading it here would warm the token
        bytes memory data = abi.encodeCall(ChannelSettlement.sweepExpiredHold, (steadyC));
        TxGas memory g = _measure(payers[0], address(settlement), data, _cold());
        _log("sweepExpiredHold, steady", g);
        assertEq(token.balanceOf(payers[0]), before + DEPOSIT, "the measured call paid");
        assertLe(g.total, 48_300, "pin: measured 48,090");
    }

    function test_gas_sweep_payers_first_tokens() public {
        bytes memory data = abi.encodeCall(ChannelSettlement.sweepExpiredHold, (firstC));
        TxGas memory g = _measure(fresh, address(settlement), data, _cold());
        _log("sweepExpiredHold, payer's first tokens", g);
        assertEq(token.balanceOf(fresh), DEPOSIT, "the measured call paid");
        assertLe(g.total, 65_400, "pin: measured 65,178");
    }
}

/// `waive` of an open channel's next voucher: no tokens move.
contract ChannelGasWaiveTest is ChannelCloseGasBase {
    bytes internal data;

    function setUp() public override {
        super.setUp();
        ChannelSettlement.Voucher memory v = _std(1, "gas");
        data = abi.encodeCall(ChannelSettlement.waive, (steadyC, v, _signV(payerKeys[0], _channelId(steadyC), v)));
    }

    function test_gas_waive() public {
        TxGas memory g = _measure(provider, address(settlement), data, _cold());
        _log("waive, open channel", g);
        (,, uint256 seq,) = settlement.channel(_channelId(steadyC));
        assertEq(seq, 1, "the measured call waived");
        assertLe(g.total, 39_300, "pin: measured 39,088");
    }
}

/// `waive` after finalization with the whole balance held: the waived unit goes back to the payer.
contract ChannelGasWaiveHeldTest is ChannelCloseGasBase {
    bytes internal steadyData;
    bytes internal firstData;

    function setUp() public override {
        super.setUp();
        _requestBoth();
        _challengeBoth(DEPOSIT);
        _finalizeBoth();
        ChannelSettlement.Voucher memory v = _std(1, "gas");
        steadyData = abi.encodeCall(ChannelSettlement.waive, (steadyC, v, _signV(payerKeys[0], _channelId(steadyC), v)));
        firstData = abi.encodeCall(ChannelSettlement.waive, (firstC, v, _signV(freshKey, _channelId(firstC), v)));
    }

    function test_gas_waive_held_steady() public {
        uint256 before = DEPOSIT; // payer 0's balance; reading it here would warm the token
        TxGas memory g = _measure(provider, address(settlement), steadyData, _cold());
        _log("waive, held channel, steady", g);
        assertEq(token.balanceOf(payers[0]), before + AMOUNT, "the measured call returned the unit");
        assertLe(g.total, 57_400, "pin: measured 57,107");
    }

    function test_gas_waive_held_payers_first_tokens() public {
        TxGas memory g = _measure(provider, address(settlement), firstData, _cold());
        _log("waive, held channel, payer's first tokens", g);
        assertEq(token.balanceOf(fresh), AMOUNT, "the measured call returned the unit");
        assertLe(g.total, 74_400, "pin: measured 74,183");
    }
}
