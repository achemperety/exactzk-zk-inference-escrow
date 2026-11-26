// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GasMeter} from "./GasMeter.sol";
import {ChannelSettlementBase} from "./ChannelSettlementBase.sol";
import {AcceptAllTarget} from "./mocks/Mocks.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";
import {ChannelSettlement, ChannelConfig} from "../src/ChannelSettlement.sol";

/// Gas of channel transactions under the Osaka schedule, with the test token. `GasMeter` explains
/// how a transaction's gas is rebuilt. Each measured call is the first thing its test does, and its
/// calldata is built in `setUp` or from this contract's own storage, so no account it touches has
/// been touched earlier in the same transaction.
///
/// "First": the channels' first vouchers and the provider's first accrual. "Steady": the channels'
/// second vouchers, the provider's accrual already non-zero.
abstract contract ChannelGasBase is ChannelSettlementBase, GasMeter {
    uint256 internal constant K8_STEADY_LIMIT = 915_000;
    uint256 internal constant MARGINAL_LIMIT = 14_000;

    function _coldK8() internal view returns (address[] memory a) {
        a = new address[](5);
        (a[0], a[1], a[2], a[3], a[4]) = (address(settlement), address(registry), address(adapter), K8, address(token));
    }

    function _k8Call(ChannelConfig[] memory cs, bytes memory frames) internal view returns (bytes memory) {
        return abi.encodeCall(
            ChannelSettlement.settleBatch, (k8Entry, set, K8_INDEX, cs, frames, k8Commitments, k8Outputs, k8Proof)
        );
    }
}

// ── K=8, real proof, eight distinct channels and payers ─────────────────────────────────────────

/// Eight new channels; the provider has never been paid.
contract ChannelGasK8FirstTest is ChannelGasBase {
    bytes internal data;

    function setUp() public override {
        super.setUp();
        ChannelConfig[] memory cs = _openEight("gas");
        data = _k8Call(cs, _k8Frames(cs, 1));
    }

    function test_gas_k8_first_batch_new_channels_first_accrual() public {
        TxGas memory g = _measure(address(settlement), data, _coldK8());
        _log("K=8, eight new channels, provider's first accrual", g);
        assertEq(settlement.accrued(provider, address(token)), 8 * AMOUNT, "the measured call settled every lane");
        assertLe(g.total, 926_600, "pin: measured 926,389");
    }
}

/// Eight new channels; the provider has been paid before (a solo voucher on a ninth channel).
contract ChannelGasK8NewChannelsTest is ChannelGasBase {
    bytes internal data;

    function setUp() public override {
        super.setUp();
        ChannelConfig[] memory one = new ChannelConfig[](1);
        one[0] = _config(payers[0], "earlier");
        bytes32 id = _open(one[0], payerKeys[0], DEPOSIT);
        bytes memory sig = _voucher(payerKeys[0], id, 1, AMOUNT, AMOUNT, soloCommitments[0], PROVE_BY);
        settlement.settleBatch(
            soloEntry, set, SOLO_INDEX, one, _frame(0, 1, AMOUNT, PROVE_BY, sig), soloCommitments, soloOutput, soloProof
        );

        ChannelConfig[] memory cs = _openEight("gas");
        data = _k8Call(cs, _k8Frames(cs, 1));
    }

    function test_gas_k8_first_batch_new_channels_provider_paid_before() public {
        TxGas memory g = _measure(address(settlement), data, _coldK8());
        _log("K=8, eight new channels, provider paid before", g);
        assertEq(settlement.accrued(provider, address(token)), 9 * AMOUNT, "the measured call settled every lane");
        assertLe(g.total, 909_500, "pin: measured 909,289");
    }
}

/// The same eight channels' second vouchers.
contract ChannelGasK8SteadyTest is ChannelGasBase {
    bytes internal data;

    bytes internal frames;
    bytes internal configs;

    function setUp() public override {
        super.setUp();
        ChannelConfig[] memory cs = _openEight("gas");
        _settleK8(cs, _k8Frames(cs, 1));
        frames = _k8Frames(cs, 2);
        configs = abi.encode(cs);
        data = _k8Call(cs, frames);
    }

    function test_gas_k8_steady() public {
        TxGas memory g = _measure(address(settlement), data, _coldK8());
        _log("K=8, steady", g);
        assertEq(settlement.accrued(provider, address(token)), 16 * AMOUNT, "the measured call settled every lane");
        assertLe(g.total, K8_STEADY_LIMIT, "limit");
        assertLe(g.total, 909_500, "pin: measured 909,289");

        // Where the calldata goes. Each part is priced as the bytes of its ABI encoding (array
        // parts include their offset and length words); the entry, the set, the index and the
        // selector are the rest.
        (uint256 proofGas,) = _calldataGas(abi.encode(k8Proof));
        (uint256 publicGas,) = _calldataGas(bytes.concat(abi.encode(k8Commitments), abi.encode(k8Outputs)));
        (uint256 configGas,) = _calldataGas(configs);
        (uint256 frameGas,) = _calldataGas(abi.encode(frames));
        emit log_named_uint("K=8, steady, calldata: proof", proofGas);
        emit log_named_uint("K=8, steady, calldata: commitments and outputs", publicGas);
        emit log_named_uint("K=8, steady, calldata: channel configs", configGas);
        emit log_named_uint("K=8, steady, calldata: frames", frameGas);
        emit log_named_uint(
            "K=8, steady, calldata: entry, set, index, selector",
            g.calldataGas - proofGas - publicGas - configGas - frameGas
        );
    }
}

// ── K=8, real proof, one channel ────────────────────────────────────────────────────────────────

/// One new channel, eight of its vouchers in one batch; the provider has never been paid.
contract ChannelGasSingleChannelFirstTest is ChannelGasBase {
    bytes internal data;

    function setUp() public override {
        super.setUp();
        ChannelConfig[] memory cs = new ChannelConfig[](1);
        cs[0] = _config(payers[0], "single");
        _open(cs[0], payerKeys[0], DEPOSIT);
        data = _k8Call(cs, _singleChannelFrames(cs[0], 0));
    }

    function test_gas_single_channel_first_batch() public {
        TxGas memory g = _measure(address(settlement), data, _coldK8());
        _log("K=8, one channel, first batch", g);
        assertEq(settlement.accrued(provider, address(token)), 8 * AMOUNT, "the measured call settled every lane");
        assertLe(g.total, 878_300, "pin: measured 878,033");
    }
}

/// The same channel's next eight vouchers.
contract ChannelGasSingleChannelSteadyTest is ChannelGasBase {
    bytes internal data;

    function setUp() public override {
        super.setUp();
        ChannelConfig[] memory cs = new ChannelConfig[](1);
        cs[0] = _config(payers[0], "single");
        _open(cs[0], payerKeys[0], DEPOSIT);
        _settleK8(cs, _singleChannelFrames(cs[0], 0));
        data = _k8Call(cs, _singleChannelFrames(cs[0], 8));
    }

    function test_gas_single_channel_steady() public {
        TxGas memory g = _measure(address(settlement), data, _coldK8());
        _log("K=8, one channel, steady", g);
        assertEq(settlement.accrued(provider, address(token)), 16 * AMOUNT, "the measured call settled every lane");
        assertLe(g.total, 861_200, "pin: measured 860,957");
    }
}

// ── Opening and withdrawing ─────────────────────────────────────────────────────────────────────

/// `openChannel` when the contract holds no tokens, and when it already holds a deposit.
contract ChannelGasOpenTest is ChannelGasBase {
    bytes internal data;

    function setUp() public override {
        super.setUp();
        ChannelConfig memory c = _config(payers[0], "open");
        data = abi.encodeCall(
            ChannelSettlement.openChannel,
            (c, DEPOSIT, VALID_BEFORE, _authorize(payerKeys[0], c.payer, DEPOSIT, _channelId(c)))
        );
    }

    function _cold() internal view returns (address[] memory a) {
        a = new address[](3);
        (a[0], a[1], a[2]) = (address(settlement), address(token), payers[0]);
    }

    function test_gas_open_first_deposit_held_by_the_contract() public {
        TxGas memory g = _measure(address(settlement), data, _cold());
        _log("openChannel, first deposit held by the contract", g);
        assertEq(token.balanceOf(address(settlement)), DEPOSIT, "the measured call opened");
        assertLe(g.total, 117_000, "pin: measured 116,719");
    }
}

contract ChannelGasOpenSteadyTest is ChannelGasBase {
    bytes internal data;

    function setUp() public override {
        super.setUp();
        _open(_config(payers[1], "other"), payerKeys[1], DEPOSIT);
        ChannelConfig memory c = _config(payers[0], "open");
        data = abi.encodeCall(
            ChannelSettlement.openChannel,
            (c, DEPOSIT, VALID_BEFORE, _authorize(payerKeys[0], c.payer, DEPOSIT, _channelId(c)))
        );
    }

    function test_gas_open_steady() public {
        address[] memory cold = new address[](3);
        (cold[0], cold[1], cold[2]) = (address(settlement), address(token), payers[0]);
        TxGas memory g = _measure(address(settlement), data, cold);
        _log("openChannel, steady", g);
        assertEq(token.balanceOf(address(settlement)), 2 * DEPOSIT, "the measured call opened");
        assertLe(g.total, 99_900, "pin: measured 99,619");
    }
}

/// `withdraw` after one K=8 batch: everything, to a provider holding no tokens; and all but one
/// unit, to a provider that holds some.
abstract contract ChannelGasWithdrawBase is ChannelGasBase {
    function setUp() public virtual override {
        super.setUp();
        ChannelConfig[] memory cs = _openEight("w");
        _settleK8(cs, _k8Frames(cs, 1));
    }

    function _cold() internal view returns (address[] memory a) {
        a = new address[](3);
        (a[0], a[1], a[2]) = (address(settlement), address(token), provider);
    }
}

contract ChannelGasWithdrawTest is ChannelGasWithdrawBase {
    function test_gas_withdraw_everything_first_payment_to_the_provider() public {
        bytes memory data = abi.encodeCall(ChannelSettlement.withdraw, (address(token), 8 * AMOUNT));
        TxGas memory g = _measure(provider, address(settlement), data, _cold());
        _log("withdraw everything, provider's first tokens", g);
        assertEq(token.balanceOf(provider), 8 * AMOUNT, "the measured call paid");
        assertLe(g.total, 57_300, "pin: measured 57,035");
    }
}

/// The same, to a provider that holds tokens already. The tokens are minted in `setUp`: minting
/// inside the test would warm the token's account before the measured call, which `vm.cool` does
/// not undo. (The day-3 figure, 42,078, was measured that way and was 2,500 too low.)
contract ChannelGasWithdrawSteadyTest is ChannelGasWithdrawBase {
    function setUp() public override {
        super.setUp();
        token.mint(provider, 1);
    }

    function test_gas_withdraw_all_but_one_unit_steady() public {
        bytes memory data = abi.encodeCall(ChannelSettlement.withdraw, (address(token), 8 * AMOUNT - 1));
        TxGas memory g = _measure(provider, address(settlement), data, _cold());
        _log("withdraw all but one unit, steady", g);
        assertEq(settlement.accrued(provider, address(token)), 1, "one unit left accrued");
        assertLe(g.total, 45_000, "pin: measured 44,747");
    }
}

// ── K-sweep with an accept-everything verifier behind the EZKL adapter ──────────────────────────

/// Entries with K = 1, 2, 4, 8, 16, 32 lanes whose target accepts everything, so the figures are
/// the contract's own cost plus the adapter's. The 3,840-byte K=8 proof is passed as filler, the
/// K=8 commitments and outputs are repeated across lanes, and every lane is a different channel
/// of a different payer.
abstract contract ChannelSweepBase is ChannelGasBase {
    uint256 internal constant SWEEP_POINTS = 6;
    uint32 internal constant SWEEP_VERIFY_GAS = 400_000;

    address internal acceptAll;
    VerifierEntry[SWEEP_POINTS] internal sweepEntries;
    bytes32[] internal sweepSet;
    ChannelConfig[32] internal sweepChannels;
    uint256[32] internal sweepKeys;

    function _k(uint256 j) internal pure returns (uint256) {
        return 1 << j;
    }

    function setUp() public virtual override {
        super.setUp();
        acceptAll = address(new AcceptAllTarget());
        sweepSet = new bytes32[](SWEEP_POINTS);
        for (uint256 j = 0; j < SWEEP_POINTS; j++) {
            VerifierEntry memory e = _entry(
                address(adapter), acceptAll, uint32(_k(j)), OUTPUT_SIZE, SWEEP_VERIFY_GAS, keccak256(abi.encode(j))
            );
            sweepEntries[j] = e;
            sweepSet[j] = registry.register(e);
        }
        bytes32 h = keccak256(abi.encodePacked(sweepSet));
        for (uint256 i = 0; i < 32; i++) {
            (address p, uint256 key) = makeAddrAndKey(string.concat("sweep payer ", vm.toString(i)));
            token.mint(p, DEPOSIT);
            ChannelConfig memory c = _config(p, bytes32(i));
            c.verifierSetHash = h;
            sweepChannels[i] = c;
            sweepKeys[i] = key;
            _open(c, key, DEPOSIT);
        }
    }

    /// The batch at point `j`: lane `i` is voucher `seq` of channel `i`.
    function _sweepCall(uint256 j, uint256 seq) internal view returns (bytes memory) {
        uint256 k = _k(j);
        ChannelConfig[] memory cs = new ChannelConfig[](k);
        bytes32[] memory commitments = new bytes32[](k);
        bytes memory outputs;
        bytes memory frames;
        for (uint256 i = 0; i < k; i++) {
            cs[i] = sweepChannels[i];
            commitments[i] = k8Commitments[i % 8];
            outputs = bytes.concat(outputs, _laneOutput(i % 8));
            bytes memory sig =
                _voucher(sweepKeys[i], _channelId(cs[i]), seq, AMOUNT, seq * AMOUNT, commitments[i], PROVE_BY);
            frames = bytes.concat(frames, _frame(i, seq, AMOUNT, PROVE_BY, sig));
        }
        return abi.encodeCall(
            ChannelSettlement.settleBatch, (sweepEntries[j], sweepSet, j, cs, frames, commitments, outputs, k8Proof)
        );
    }

    function _laneOutput(uint256 lane) internal view returns (bytes memory out) {
        out = new bytes(OUTPUT_SIZE);
        for (uint256 b = 0; b < OUTPUT_SIZE; b++) {
            out[b] = k8Outputs[lane * OUTPUT_SIZE + b];
        }
    }

    function _coldSweep() internal view returns (address[] memory a) {
        a = new address[](4);
        (a[0], a[1], a[2], a[3]) = (address(settlement), address(registry), address(adapter), acceptAll);
    }

    function _runSweep(uint256 j, uint256 seq, string memory label) internal returns (TxGas memory g) {
        bytes memory data = _sweepCall(j, seq);
        g = _measure(address(settlement), data, _coldSweep());
        string memory l = string.concat(label, ", K=", vm.toString(_k(j)));
        _log(l, g);
        bool floorBinds = g.total > 21_000 + g.calldataGas + g.execution - g.refund;
        emit log_named_string(string.concat(l, ":   EIP-7623 floor binds"), floorBinds ? "yes" : "no");
        assertEq(settlement.accrued(provider, address(token)), (seq == 1 ? 0 : 32 * AMOUNT) + _k(j) * AMOUNT, "paid");
        assertEq(g.refund, 0, "no refund");
    }
}

/// New channels; the provider has never been paid.
contract ChannelSweepFirstTest is ChannelSweepBase {
    function _check(uint256 j) internal {
        TxGas memory g = _runSweep(j, 1, "sweep, first");
        assertEq(g.execution, ChannelSweepFigures.firstExecution(j), "pin: ChannelSweepFigures.firstExecution");
        assertEq(g.calldataGas, ChannelSweepFigures.firstCalldata(j), "pin: ChannelSweepFigures.firstCalldata");
    }

    function test_gas_sweep_first_k01() public {
        _check(0);
    }

    function test_gas_sweep_first_k02() public {
        _check(1);
    }

    function test_gas_sweep_first_k04() public {
        _check(2);
    }

    function test_gas_sweep_first_k08() public {
        _check(3);
    }

    function test_gas_sweep_first_k16() public {
        _check(4);
    }

    function test_gas_sweep_first_k32() public {
        _check(5);
    }
}

/// The same channels' second vouchers (a K=32 batch settled every channel's first in `setUp`).
contract ChannelSweepSteadyTest is ChannelSweepBase {
    function setUp() public override {
        super.setUp();
        (bool ok,) = address(settlement).call(_sweepCall(5, 1));
        assertTrue(ok, "first vouchers");
    }

    function _check(uint256 j) internal {
        TxGas memory g = _runSweep(j, 2, "sweep, steady");
        assertEq(g.execution, ChannelSweepFigures.steadyExecution(j), "pin: ChannelSweepFigures.steadyExecution");
        assertEq(g.calldataGas, ChannelSweepFigures.steadyCalldata(j), "pin: ChannelSweepFigures.steadyCalldata");
    }

    function test_gas_sweep_steady_k01() public {
        _check(0);
    }

    function test_gas_sweep_steady_k02() public {
        _check(1);
    }

    function test_gas_sweep_steady_k04() public {
        _check(2);
    }

    function test_gas_sweep_steady_k08() public {
        _check(3);
    }

    function test_gas_sweep_steady_k16() public {
        _check(4);
    }

    function test_gas_sweep_steady_k32() public {
        _check(5);
    }
}

/// The figures the sweep tests pin, exactly: gas used by the call frame (no refund occurs) and
/// calldata at 4 and 16 gas per byte, for K = 1, 2, 4, 8, 16, 32.
library ChannelSweepFigures {
    function firstExecution(uint256 j) internal pure returns (uint256) {
        return [uint256(56_937), 69_779, 95_118, 145_805, 247_576, 451_299][j];
    }

    function steadyExecution(uint256 j) internal pure returns (uint256) {
        return [uint256(39_837), 52_679, 78_018, 128_705, 230_476, 434_199][j];
    }

    function firstCalldata(uint256 j) internal pure returns (uint256) {
        return [uint256(75_396), 82_584, 95_808, 125_344, 182_060, 295_540][j];
    }

    function steadyCalldata(uint256 j) internal pure returns (uint256) {
        return [uint256(75_408), 82_596, 95_820, 125_356, 182_108, 295_588][j];
    }
}

/// Least-squares lines through the pinned sweep figures: fixed term and cost per frame.
contract ChannelSweepFitTest is ChannelGasBase {
    /// One decimal: returns ten times the fixed term and ten times the slope, and the largest
    /// distance of a point from the line, in gas.
    function _fit(uint256[6] memory y) internal pure returns (int256 fixed10, int256 slope10, uint256 maxResidual) {
        int256 n = 6;
        int256 sx;
        int256 sxx;
        int256 sy;
        int256 sxy;
        for (uint256 j = 0; j < 6; j++) {
            int256 x = int256(1 << j);
            sx += x;
            sxx += x * x;
            sy += int256(y[j]);
            sxy += x * int256(y[j]);
        }
        slope10 = (10 * (n * sxy - sx * sy)) / (n * sxx - sx * sx);
        fixed10 = (10 * sy - slope10 * sx) / n;
        for (uint256 j = 0; j < 6; j++) {
            int256 r = 10 * int256(y[j]) - fixed10 - slope10 * int256(1 << j);
            uint256 a = uint256(r < 0 ? -r : r) / 10;
            if (a > maxResidual) maxResidual = a;
        }
    }

    function _series(bool first, bool withCalldata) internal pure returns (uint256[6] memory y) {
        for (uint256 j = 0; j < 6; j++) {
            y[j] = first ? ChannelSweepFigures.firstExecution(j) : ChannelSweepFigures.steadyExecution(j);
            if (withCalldata) {
                y[j] += 21_000 + (first ? ChannelSweepFigures.firstCalldata(j) : ChannelSweepFigures.steadyCalldata(j));
            }
        }
    }

    function _report(string memory label, uint256[6] memory y) internal returns (int256 slope10, uint256 maxResidual) {
        int256 fixed10;
        (fixed10, slope10, maxResidual) = _fit(y);
        emit log_named_decimal_int(string.concat(label, ": fixed"), fixed10, 1);
        emit log_named_decimal_int(string.concat(label, ": per frame"), slope10, 1);
        emit log_named_uint(string.concat(label, ": largest residual"), maxResidual);
    }

    function test_sweep_steady_cost_per_frame_is_within_the_limit() public {
        (int256 slope10, uint256 maxResidual) = _report("execution, steady", _series(false, false));
        _report("execution, first", _series(true, false));
        _report("21,000 + calldata + execution, steady", _series(false, true));
        _report("21,000 + calldata + execution, first", _series(true, true));
        assertLe(slope10, int256(10 * MARGINAL_LIMIT), "limit: 14,000 per frame");
        assertLe(maxResidual, 300, "linear in K");
    }

    function test_sweep_first_minus_steady_is_the_providers_first_accrual() public pure {
        for (uint256 j = 0; j < 6; j++) {
            // The accrual slot goes from zero to non-zero (20,000) instead of being changed (2,900).
            assertEq(
                ChannelSweepFigures.firstExecution(j) - ChannelSweepFigures.steadyExecution(j), 17_100, "difference"
            );
        }
    }
}
