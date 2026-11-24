// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GasMeter} from "./GasMeter.sol";
import {ChannelSettlementBase} from "./ChannelSettlementBase.sol";
import {ChannelSettlement, ChannelConfig} from "../src/ChannelSettlement.sol";

interface IUSDCForChannels {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function balanceOf(address) external view returns (uint256);
}

/// Channels against the real USDC contract of Base Sepolia, on a local fork of that chain: the same
/// contract, proof and gas method as `ChannelSettlementGas.t.sol`, with Circle's token in place of
/// the test token. `openChannel`, `withdraw` and the close functions that pay the payer touch the
/// token; a batch never does, so its gas must equal the test token's.
///
/// Skipped unless `FORK_RPC_URL` is set, so CI never depends on a network:
///
///     FORK_RPC_URL=https://sepolia.base.org FORK_BLOCK=62638490 \
///         forge test --match-path test/ChannelSettlementFork.t.sol -vv
///
/// Figures are logged, not pinned, because they depend on the live token.
abstract contract ChannelForkBase is ChannelSettlementBase, GasMeter {
    /// Circle's testnet USDC on Base Sepolia (developers.circle.com, "USDC contract addresses").
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    bool internal forked;
    address internal implementation;

    function setUp() public virtual override {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blockNumber = vm.envOr("FORK_BLOCK", uint256(0));
        if (blockNumber == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNumber);
        forked = true;
        emit log_named_uint("forked at block", block.number);
        super.setUp(); // deploys the core and the channel contract on the fork

        tokenDomain = IUSDCForChannels(USDC).DOMAIN_SEPARATOR();
        implementation = address(uint160(uint256(vm.load(USDC, keccak256("org.zeppelinos.proxy.implementation")))));
        for (uint256 i = 0; i < 8; i++) {
            deal(USDC, payers[i], 2 * DEPOSIT);
        }
        deal(USDC, address(wallet), 2 * DEPOSIT);
        deal(USDC, provider, 0);
        deal(USDC, address(settlement), 0);
    }

    modifier onlyForked() {
        if (!forked) vm.skip(true);
        _;
    }

    function _config(address payer, bytes32 salt) internal view override returns (ChannelConfig memory c) {
        c = super._config(payer, salt);
        c.asset = USDC;
    }

    function _cold() internal view returns (address[] memory a) {
        a = new address[](8);
        (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]) =
        (address(settlement), USDC, implementation, address(registry), address(adapter), K8, payers[0], provider);
    }

    function _openData(bytes32 salt) internal view returns (bytes memory) {
        ChannelConfig memory c = _config(payers[0], salt);
        return abi.encodeCall(
            ChannelSettlement.openChannel,
            (c, DEPOSIT, VALID_BEFORE, _authorize(payerKeys[0], c.payer, DEPOSIT, _channelId(c)))
        );
    }
}

/// The contract holds no USDC yet.
contract ChannelForkOpenFirstTest is ChannelForkBase {
    function test_fork_open_first_deposit_held_by_the_contract() public onlyForked {
        TxGas memory g = _measure(address(settlement), _openData("gas"), _cold());
        _log("USDC openChannel, first deposit held by the contract", g);
        assertEq(IUSDCForChannels(USDC).balanceOf(address(settlement)), DEPOSIT, "deposit held");
    }
}

/// The contract holds USDC already (as it will once seeded with one unit at deployment).
contract ChannelForkOpenSteadyTest is ChannelForkBase {
    function setUp() public override {
        super.setUp();
        if (!forked) return;
        deal(USDC, address(settlement), 1);
    }

    function test_fork_open_steady() public onlyForked {
        TxGas memory g = _measure(address(settlement), _openData("gas"), _cold());
        _log("USDC openChannel, steady", g);
        assertEq(IUSDCForChannels(USDC).balanceOf(address(settlement)), DEPOSIT + 1, "deposit held");
    }
}

/// The second vouchers of eight USDC channels: the batch does not touch the token.
contract ChannelForkK8SteadyTest is ChannelForkBase {
    bytes internal data;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        ChannelConfig[] memory cs = _openEight("gas");
        _settleK8(cs, _k8Frames(cs, 1));
        data = abi.encodeCall(
            ChannelSettlement.settleBatch,
            (k8Entry, set, K8_INDEX, cs, _k8Frames(cs, 2), k8Commitments, k8Outputs, k8Proof)
        );
    }

    function test_fork_k8_steady() public onlyForked {
        TxGas memory g = _measure(address(settlement), data, _cold());
        _log("USDC channels, K=8, steady", g);
        assertEq(settlement.accrued(provider, USDC), 16 * AMOUNT, "settled every lane");
        assertLe(g.total, 915_000, "limit");
    }
}

/// Withdrawals after one K=8 batch of USDC channels.
abstract contract ChannelForkWithdrawBase is ChannelForkBase {
    function setUp() public virtual override {
        super.setUp();
        if (!forked) return;
        ChannelConfig[] memory cs = _openEight("w");
        _settleK8(cs, _k8Frames(cs, 1));
    }
}

contract ChannelForkWithdrawTest is ChannelForkWithdrawBase {
    function test_fork_withdraw_everything_first_usdc_of_the_provider() public onlyForked {
        bytes memory data = abi.encodeCall(ChannelSettlement.withdraw, (USDC, 8 * AMOUNT));
        TxGas memory g = _measure(provider, address(settlement), data, _cold());
        _log("USDC withdraw everything, provider's first USDC", g);
        assertEq(IUSDCForChannels(USDC).balanceOf(provider), 8 * AMOUNT, "paid");
    }
}

/// The same, to a provider that holds USDC already. The USDC is dealt in `setUp`: `deal` reads the
/// token, which would warm its proxy and implementation before the measured call, and `vm.cool`
/// does not undo that. (The day-3 figure, 50,424, was measured that way and was too low.)
contract ChannelForkWithdrawSteadyTest is ChannelForkWithdrawBase {
    function setUp() public override {
        super.setUp();
        if (!forked) return;
        deal(USDC, provider, 1);
    }

    function test_fork_withdraw_all_but_one_unit_steady() public onlyForked {
        bytes memory data = abi.encodeCall(ChannelSettlement.withdraw, (USDC, 8 * AMOUNT - 1));
        TxGas memory g = _measure(provider, address(settlement), data, _cold());
        _log("USDC withdraw all but one unit, steady", g);
        assertEq(IUSDCForChannels(USDC).balanceOf(provider), 8 * AMOUNT, "paid");
        assertEq(settlement.accrued(provider, USDC), 1, "one unit left accrued");
    }
}

/// A smart-wallet payer: real USDC checks its deposit authorization, this contract its voucher.
contract ChannelForkSmartWalletTest is ChannelForkBase {
    function test_fork_smart_wallet_opens_and_its_voucher_settles() public onlyForked {
        ChannelConfig[] memory cs = new ChannelConfig[](1);
        cs[0] = _config(address(wallet), "wallet");
        bytes32 id = _channelId(cs[0]);
        settlement.openChannel(cs[0], DEPOSIT, VALID_BEFORE, _authorize(walletOwnerKey, address(wallet), DEPOSIT, id));
        assertEq(IUSDCForChannels(USDC).balanceOf(address(wallet)), DEPOSIT, "deposit pulled");

        bytes memory sig = _voucher(walletOwnerKey, id, 1, AMOUNT, AMOUNT, soloCommitments[0], PROVE_BY);
        settlement.settleBatch(
            soloEntry, set, SOLO_INDEX, cs, _frame(0, 1, AMOUNT, PROVE_BY, sig), soloCommitments, soloOutput, soloProof
        );
        assertEq(settlement.accrued(provider, USDC), AMOUNT, "settled");
    }

    function test_fork_smart_wallet_that_rejects_is_not_charged() public onlyForked {
        ChannelConfig memory c = _config(address(wallet), "reject");
        bytes memory sig = _authorize(walletOwnerKey, address(wallet), DEPOSIT, _channelId(c));
        wallet.setAccepting(false);
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        settlement.openChannel(c, DEPOSIT, VALID_BEFORE, sig);
    }
}

// ── Closing, with USDC ──────────────────────────────────────────────────────────────────────────

/// The close functions of `test/ChannelCloseGas.t.sol` with Circle's token: payer 0 holds USDC
/// already ("steady"); a fresh payer deposits all it has ("first"). The contract holds one unit
/// of its own, as it will after deployment. Nothing reads the token inside a measured test.
abstract contract ChannelForkCloseBase is ChannelForkBase {
    address internal fresh;
    uint256 internal freshKey;
    ChannelConfig internal steadyC;
    ChannelConfig internal firstC;

    function setUp() public virtual override {
        super.setUp();
        if (!forked) return;
        deal(USDC, address(settlement), 1);
        (fresh, freshKey) = makeAddrAndKey("fresh payer");
        deal(USDC, fresh, DEPOSIT);
        steadyC = _config(payers[0], "steady");
        firstC = _config(fresh, "first");
        _open(steadyC, payerKeys[0], DEPOSIT);
        _open(firstC, freshKey, DEPOSIT);
    }

    function _coldClose() internal view returns (address[] memory a) {
        a = new address[](5);
        (a[0], a[1], a[2], a[3], a[4]) = (address(settlement), USDC, implementation, payers[0], fresh);
    }

    function _requestBoth() internal {
        _requestClose(steadyC);
        _requestClose(firstC);
    }

    function _challengeBoth(uint256 cum) internal {
        _challenge(steadyC, payerKeys[0], _v(50, AMOUNT, cum, _c("gas", 50), block.timestamp + 1800));
        _challenge(firstC, freshKey, _v(50, AMOUNT, cum, _c("gas", 50), block.timestamp + 1800));
    }

    function _finalizeBoth() internal {
        vm.warp(block.timestamp + CHALLENGE_WINDOW);
        settlement.finalizeClose(steadyC);
        settlement.finalizeClose(firstC);
    }

    function _usdc(address who) internal view returns (uint256) {
        return IUSDCForChannels(USDC).balanceOf(who);
    }
}

contract ChannelForkRequestChallengeTest is ChannelForkCloseBase {
    bytes internal challengeData;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        _requestClose(firstC);
        ChannelSettlement.Voucher memory v = _std(3, "gas");
        challengeData =
            abi.encodeCall(ChannelSettlement.challengeClose, (firstC, v, _signV(freshKey, _channelId(firstC), v)));
    }

    function test_fork_request_close() public onlyForked {
        bytes memory data = abi.encodeCall(ChannelSettlement.requestClose, (steadyC));
        TxGas memory g = _measure(payers[0], address(settlement), data, _coldClose());
        _log("USDC requestClose", g);
        (,,, ChannelSettlement.State st) = settlement.channel(_channelId(steadyC));
        assertEq(uint8(st), uint8(ChannelSettlement.State.Closing), "closing");
    }

    function test_fork_challenge_close() public onlyForked {
        TxGas memory g = _measure(provider, address(settlement), challengeData, _coldClose());
        _log("USDC challengeClose", g);
        (, uint256 claimed,,) = settlement.closeState(_channelId(firstC));
        assertEq(claimed, 3 * AMOUNT, "claimed");
    }
}

contract ChannelForkFinalizeTest is ChannelForkCloseBase {
    function setUp() public override {
        super.setUp();
        if (!forked) return;
        _requestBoth();
        vm.warp(block.timestamp + CHALLENGE_WINDOW);
    }

    function test_fork_finalize_steady() public onlyForked {
        bytes memory data = abi.encodeCall(ChannelSettlement.finalizeClose, (steadyC));
        TxGas memory g = _measure(payers[0], address(settlement), data, _coldClose());
        _log("USDC finalizeClose, nothing held, steady", g);
        assertEq(_usdc(payers[0]), 2 * DEPOSIT, "paid");
    }

    function test_fork_finalize_payers_first_usdc() public onlyForked {
        bytes memory data = abi.encodeCall(ChannelSettlement.finalizeClose, (firstC));
        TxGas memory g = _measure(fresh, address(settlement), data, _coldClose());
        _log("USDC finalizeClose, nothing held, payer's first USDC", g);
        assertEq(_usdc(fresh), DEPOSIT, "paid");
    }
}

contract ChannelForkFinalizeHoldTest is ChannelForkCloseBase {
    function setUp() public override {
        super.setUp();
        if (!forked) return;
        _requestBoth();
        _challengeBoth(3 * AMOUNT);
        vm.warp(block.timestamp + CHALLENGE_WINDOW);
    }

    function test_fork_finalize_with_a_hold_steady() public onlyForked {
        bytes memory data = abi.encodeCall(ChannelSettlement.finalizeClose, (steadyC));
        TxGas memory g = _measure(payers[0], address(settlement), data, _coldClose());
        _log("USDC finalizeClose, with a hold, steady", g);
        assertEq(_usdc(payers[0]), 2 * DEPOSIT - 3 * AMOUNT, "paid");
    }

    function test_fork_finalize_with_a_hold_payers_first_usdc() public onlyForked {
        bytes memory data = abi.encodeCall(ChannelSettlement.finalizeClose, (firstC));
        TxGas memory g = _measure(fresh, address(settlement), data, _coldClose());
        _log("USDC finalizeClose, with a hold, payer's first USDC", g);
        assertEq(_usdc(fresh), DEPOSIT - 3 * AMOUNT, "paid");
    }
}

contract ChannelForkSweepTest is ChannelForkCloseBase {
    function setUp() public override {
        super.setUp();
        if (!forked) return;
        _requestBoth();
        _challengeBoth(DEPOSIT);
        _finalizeBoth();
        vm.warp(block.timestamp + PROVE_WINDOW + 1);
    }

    function test_fork_sweep_steady() public onlyForked {
        bytes memory data = abi.encodeCall(ChannelSettlement.sweepExpiredHold, (steadyC));
        TxGas memory g = _measure(payers[0], address(settlement), data, _coldClose());
        _log("USDC sweepExpiredHold, steady", g);
        assertEq(_usdc(payers[0]), 2 * DEPOSIT, "paid");
    }

    function test_fork_sweep_payers_first_usdc() public onlyForked {
        bytes memory data = abi.encodeCall(ChannelSettlement.sweepExpiredHold, (firstC));
        TxGas memory g = _measure(fresh, address(settlement), data, _coldClose());
        _log("USDC sweepExpiredHold, payer's first USDC", g);
        assertEq(_usdc(fresh), DEPOSIT, "paid");
    }
}

contract ChannelForkWaiveTest is ChannelForkCloseBase {
    bytes internal openData;
    bytes internal heldSteady;
    bytes internal heldFirst;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        ChannelConfig memory third = _config(payers[1], "third");
        _open(third, payerKeys[1], DEPOSIT);
        ChannelSettlement.Voucher memory v = _std(1, "gas");
        openData = abi.encodeCall(ChannelSettlement.waive, (third, v, _signV(payerKeys[1], _channelId(third), v)));
        _requestBoth();
        _challengeBoth(DEPOSIT);
        _finalizeBoth();
        v = _std(1, "gas");
        heldSteady = abi.encodeCall(ChannelSettlement.waive, (steadyC, v, _signV(payerKeys[0], _channelId(steadyC), v)));
        heldFirst = abi.encodeCall(ChannelSettlement.waive, (firstC, v, _signV(freshKey, _channelId(firstC), v)));
    }

    function test_fork_waive_open_channel() public onlyForked {
        TxGas memory g = _measure(provider, address(settlement), openData, _coldClose());
        _log("USDC waive, open channel", g);
        (,, uint256 seq,) = settlement.channel(_channelId(_config(payers[1], "third")));
        assertEq(seq, 1, "waived");
    }

    function test_fork_waive_held_steady() public onlyForked {
        TxGas memory g = _measure(provider, address(settlement), heldSteady, _coldClose());
        _log("USDC waive, held channel, steady", g);
        assertEq(_usdc(payers[0]), DEPOSIT + AMOUNT, "returned");
    }

    function test_fork_waive_held_payers_first_usdc() public onlyForked {
        TxGas memory g = _measure(provider, address(settlement), heldFirst, _coldClose());
        _log("USDC waive, held channel, payer's first USDC", g);
        assertEq(_usdc(fresh), AMOUNT, "returned");
    }
}

/// A smart-wallet payer closes its USDC channel; the provider's challenge carries the wallet's
/// ERC-1271 signature, and the free balance goes back to the wallet.
contract ChannelForkSmartWalletCloseTest is ChannelForkCloseBase {
    function test_fork_smart_wallet_closes_with_a_hold() public onlyForked {
        ChannelConfig memory w = _config(address(wallet), "wallet close");
        _open(w, walletOwnerKey, DEPOSIT);
        vm.prank(wallet.owner());
        wallet.execute(address(settlement), abi.encodeCall(ChannelSettlement.requestClose, (w)));
        _challenge(w, walletOwnerKey, _std(2, "wc"));
        vm.warp(block.timestamp + CHALLENGE_WINDOW);
        uint256 before = _usdc(address(wallet));
        settlement.finalizeClose(w);
        assertEq(_usdc(address(wallet)), before + DEPOSIT - 2 * AMOUNT, "free part to the wallet");
    }
}
