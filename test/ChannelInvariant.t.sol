// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {ChannelCloseBase} from "./ChannelCloseBase.sol";
import {MockERC3009} from "./mocks/MockERC3009.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";
import {ChannelSettlement, ChannelConfig} from "../src/ChannelSettlement.sol";

/// Drives `ChannelSettlement` through random sequences of every public action, as the fuzzer
/// chooses, with random time jumps. Each action targets a channel in a state where it can
/// succeed most of the time and an arbitrary channel otherwise, so both paths are exercised;
/// a call that reverts is counted by the fuzzer and leaves no trace in the ghost variables.
///
/// What leaves the contract is measured from outside, in the token: the payer's balance around
/// `finalizeClose`, `sweepExpiredHold` and `waive`, and the provider's around `withdraw`. What a
/// batch pays is measured per channel from the change in its balance, and cross-checked against
/// the change in the provider's accrual.
contract ChannelHandler is CommonBase, StdUtils {
    uint256 internal constant UNIT = 1_000_000;
    uint256 internal constant FIELD = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;
    uint256 internal constant OUTPUT_SIZE = 320;
    uint256 internal constant MAX_WARP = 1800;

    ChannelSettlement internal immutable settlement;
    MockERC3009 internal immutable token;
    address internal immutable provider;
    bytes32 internal immutable setHash;
    bytes32 internal immutable pad;
    uint256 internal immutable mock1Index;
    uint256 internal immutable mock4Index;
    VerifierEntry internal mock1;
    VerifierEntry internal mock4;
    bytes32[] internal set;

    address[4] internal payers;
    uint256[4] internal keys;
    ChannelConfig[] internal configs;
    bytes32[] public ids;
    mapping(bytes32 => uint256) internal keyOf;
    uint256 internal salt;

    // Ghost variables.
    uint256 public deposited;
    uint256 public withdrawn;
    uint256 public returned;
    mapping(bytes32 => uint256) public depositOf;
    mapping(bytes32 => uint256) public paidOf;
    mapping(bytes32 => uint256) public returnedOf;
    mapping(bytes32 => uint256) internal lastSeq;
    mapping(bytes32 => uint256) internal lastAccounted;
    mapping(bytes32 => uint8) internal lastState;
    mapping(bytes32 => bool) public closed;
    mapping(bytes32 => bytes32) public closedHot;
    mapping(bytes32 => bytes32) public closedCold;
    bool public seqDecreased;
    bool public accountedDecreased;
    bool public closedChanged;
    bool public stateWentBack;
    bool public heldNotBalance;
    bool public accrualMismatch;
    bool public wentDown;
    // Coverage: how often each state was entered, across all runs of one invariant.
    uint256 public enteredClosing;
    uint256 public enteredHeld;
    uint256 public enteredClosed;
    uint256 public heldSettled; // lanes settled out of a hold
    uint256 public closedChannels;
    uint256 public heldChannels;

    constructor(
        ChannelSettlement settlement_,
        MockERC3009 token_,
        address provider_,
        VerifierEntry memory mock1_,
        VerifierEntry memory mock4_,
        bytes32[] memory set_,
        uint256 mock1Index_,
        uint256 mock4Index_
    ) {
        settlement = settlement_;
        token = token_;
        provider = provider_;
        mock1 = mock1_;
        mock4 = mock4_;
        set = set_;
        setHash = keccak256(abi.encodePacked(set_));
        pad = mock4_.emptyLane;
        mock1Index = mock1Index_;
        mock4Index = mock4Index_;
        for (uint256 i = 0; i < 4; i++) {
            keys[i] = uint256(keccak256(abi.encode("invariant payer", i))) % (FIELD - 1) + 1;
            payers[i] = vm.addr(keys[i]);
        }
        for (uint256 i = 0; i < 4; i++) {
            _open(i, 10 * UNIT, uint256(keccak256(abi.encode("windows", i))));
        }
    }

    // ── Actions ─────────────────────────────────────────────────────────────────────────────────

    function open(uint256 payerSeed, uint256 depositSeed) external {
        _open(payerSeed % 4, 1 + depositSeed % (20 * UNIT), uint256(keccak256(abi.encode(payerSeed, depositSeed))));
        _observe();
    }

    function settle(uint256 seed, uint256 faults) external {
        uint256 n = 1 + seed % 3;
        ChannelConfig[] memory cs = new ChannelConfig[](n);
        bytes32[] memory lanes = new bytes32[](n == 1 ? 1 : 4);
        bytes memory frames;
        // Per lane: the channel's next seq, accounted amount and balance as earlier lanes leave them.
        uint256[] memory nextSeq = new uint256[](n);
        uint256[] memory acc = new uint256[](n);
        uint256[] memory bal = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bytes32 id = faults % 5 == 0 ? _any(r) : _pickPreferring(r, _isLiveHold, _acceptsVouchers);
            cs[i] = _configOf(id);
            (bal[i], acc[i], nextSeq[i],) = settlement.channel(id);
            nextSeq[i] += 1;
            for (uint256 j = 0; j < i; j++) {
                if (_idOf(cs[j]) == id) (nextSeq[i], acc[i], bal[i]) = (nextSeq[j], acc[j], bal[j]);
            }
            uint256 amount = (r >> 8) % (2 * UNIT + 1);
            uint256 proveBy = block.timestamp + (r >> 40) % (uint256(cs[i].proveWindow) + 1);
            uint256 seq = nextSeq[i];
            uint256 signer = keyOf[id];
            uint256 fault = (faults >> (8 * i)) % 16; // 0-3: a broken lane; otherwise a good one
            if (fault == 0) seq += 1;
            else if (fault == 1) proveBy = block.timestamp - 1;
            else if (fault == 2) amount = bal[i] + 1;
            else if (fault == 3) signer = keys[(r >> 100) % 4] == keyOf[id] ? 1 : keys[(r >> 100) % 4];
            lanes[i] = bytes32(uint256(keccak256(abi.encode("lane", seed, i))) % FIELD);
            bytes32 digest = settlement.voucherDigest(
                id, uint48(seq), uint96(amount), uint96(acc[i] + amount), lanes[i], uint40(proveBy)
            );
            (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(signer, digest);
            frames = bytes.concat(
                frames, abi.encodePacked(uint16(i), uint48(seq), uint96(amount), uint40(proveBy), uint16(65), rr, ss, v)
            );
            if (fault > 3 && amount <= bal[i]) {
                (nextSeq[i], acc[i], bal[i]) = (seq + 1, acc[i] + amount, bal[i] - amount);
            }
        }
        for (uint256 i = n; i < lanes.length; i++) {
            lanes[i] = pad;
        }

        uint256[] memory before = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            (before[i],,,) = settlement.channel(_idOf(cs[i]));
        }
        uint256 accruedBefore = settlement.accrued(provider, address(token));
        settlement.settleBatch(
            n == 1 ? mock1 : mock4,
            set,
            n == 1 ? mock1Index : mock4Index,
            cs,
            frames,
            lanes,
            new bytes(lanes.length * OUTPUT_SIZE),
            ""
        );
        uint256 paid;
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = _idOf(cs[i]);
            bool first = true;
            for (uint256 j = 0; j < i; j++) {
                if (_idOf(cs[j]) == id) first = false;
            }
            if (!first) continue;
            (uint256 after_,,,) = settlement.channel(id);
            uint256 drop = _diff(after_, before[i]); // a balance that grew is flagged, not reverted on
            paidOf[id] += drop;
            paid += drop;
            if (drop != 0 && lastState[id] == uint8(ChannelSettlement.State.Held)) heldSettled++;
        }
        if (settlement.accrued(provider, address(token)) - accruedBefore != paid) accrualMismatch = true;
        _observe();
    }

    function withdraw(uint256 seed) external {
        uint256 available = settlement.accrued(provider, address(token));
        uint256 amount = available == 0 || seed % 8 == 0 ? available + 1 : 1 + seed % available;
        uint256 before = token.balanceOf(provider);
        vm.prank(provider);
        settlement.withdraw(address(token), amount);
        withdrawn += _diff(before, token.balanceOf(provider));
        _observe();
    }

    function requestClose(uint256 seed) external {
        bytes32 id = seed % 5 == 0 ? _any(seed) : _pick(seed, _isOpen);
        ChannelConfig memory c = _configOf(id);
        vm.prank(seed % 7 == 0 ? provider : c.payer);
        settlement.requestClose(c);
        _observe();
    }

    function challengeClose(uint256 seed, uint256 amountSeed) external {
        bytes32 id = seed % 5 == 0 ? _any(seed) : _pick(seed, _canBeChallenged);
        ChannelConfig memory c = _configOf(id);
        (, uint256 acc, uint256 seq,) = settlement.channel(id);
        (, uint256 claimed,,) = settlement.closeState(id);
        ChannelSettlement.Voucher memory v = ChannelSettlement.Voucher({
            seq: uint48(seq + 1 + seed % 4),
            amount: uint96(UNIT),
            cumAmount: uint96((acc > claimed ? acc : claimed) + amountSeed % (6 * UNIT)),
            inputCommitment: bytes32(amountSeed % FIELD),
            proveBy: uint40(block.timestamp + (amountSeed >> 128) % (uint256(c.proveWindow) + 1))
        });
        bytes memory sig = _sign(keyOf[id], id, v);
        vm.prank(provider);
        settlement.challengeClose(c, v, sig);
        _observe();
    }

    function waive(uint256 seed, uint256 amountSeed) external {
        bytes32 id = seed % 5 == 0 ? _any(seed) : _pickPreferring(seed, _isLiveHold, _acceptsVouchers);
        ChannelConfig memory c = _configOf(id);
        (, uint256 acc, uint256 seq,) = settlement.channel(id);
        uint256 amount = amountSeed % (2 * UNIT + 1);
        ChannelSettlement.Voucher memory v = ChannelSettlement.Voucher({
            seq: uint48(seq + 1),
            amount: uint96(amount),
            cumAmount: uint96(acc + amount),
            inputCommitment: bytes32(amountSeed % FIELD),
            proveBy: uint40(block.timestamp + 4000 - (amountSeed >> 128) % 8000) // may have expired
        });
        bytes memory sig = _sign(keyOf[id], id, v);
        uint256 before = token.balanceOf(c.payer);
        vm.prank(provider);
        settlement.waive(c, v, sig);
        _returned(id, _diff(before, token.balanceOf(c.payer)));
        _observe();
    }

    function finalizeClose(uint256 seed) external {
        bytes32 id = seed % 5 == 0 ? _any(seed) : _pickPreferring(seed, _isChallenged, _isClosing);
        (uint256 closingAt,,,) = settlement.closeState(id);
        if (seed % 2 == 0 && block.timestamp < closingAt) vm.warp(closingAt);
        ChannelConfig memory c = _configOf(id);
        uint256 before = token.balanceOf(c.payer);
        settlement.finalizeClose(c);
        _returned(id, _diff(before, token.balanceOf(c.payer)));
        _observe();
    }

    function sweepExpiredHold(uint256 seed) external {
        bytes32 id = seed % 5 == 0 ? _any(seed) : _pick(seed, _isHeld);
        (,, uint256 holdExpiry,) = settlement.closeState(id);
        if (seed % 2 == 0 && block.timestamp <= holdExpiry) vm.warp(holdExpiry + 1);
        ChannelConfig memory c = _configOf(id);
        uint256 before = token.balanceOf(c.payer);
        settlement.sweepExpiredHold(c);
        _returned(id, _diff(before, token.balanceOf(c.payer)));
        _observe();
    }

    function warp(uint256 seed) external {
        // Up to half an hour: channels' windows run from one minute to an hour.
        vm.warp(block.timestamp + 1 + seed % MAX_WARP);
        _observe();
    }

    // ── Views for the invariants ────────────────────────────────────────────────────────────────

    function count() external view returns (uint256) {
        return ids.length;
    }

    function payerList() external view returns (address[4] memory) {
        return payers;
    }

    // ── Internals ───────────────────────────────────────────────────────────────────────────────

    /// A channel of payer `p` with its own windows: prove 60 s to an hour, challenge 300 s to an hour.
    function _open(uint256 p, uint256 deposit, uint256 windows) internal {
        ChannelConfig memory c = ChannelConfig({
            payer: payers[p],
            payTo: provider,
            asset: address(token),
            verifierSetHash: setHash,
            proveWindow: uint40(60 + windows % 3541),
            challengeWindow: uint40(300 + (windows >> 64) % 3301),
            salt: bytes32(++salt)
        });
        bytes32 id = settlement.channelId(c);
        uint256 validBefore = block.timestamp + 1 hours;
        token.mint(c.payer, deposit);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(keys[p], token.digestFor(c.payer, address(settlement), deposit, validBefore, id));
        settlement.openChannel(c, deposit, validBefore, abi.encodePacked(r, s, v));
        configs.push(c);
        ids.push(id);
        keyOf[id] = keys[p];
        depositOf[id] = deposit;
        deposited += deposit;
        lastState[id] = uint8(ChannelSettlement.State.Open);
    }

    function _sign(uint256 k, bytes32 id, ChannelSettlement.Voucher memory v) internal view returns (bytes memory) {
        bytes32 digest = settlement.voucherDigest(id, v.seq, v.amount, v.cumAmount, v.inputCommitment, v.proveBy);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(k, digest);
        return abi.encodePacked(r, s, vv);
    }

    /// `to - from`, or zero with `wentDown` set: a value that should only grow is flagged here
    /// rather than reverting, which the fuzzer would count as an ordinary revert.
    function _diff(uint256 from, uint256 to) internal returns (uint256) {
        if (to < from) {
            wentDown = true;
            return 0;
        }
        return to - from;
    }

    function _returned(bytes32 id, uint256 amount) internal {
        returnedOf[id] += amount;
        returned += amount;
    }

    function _any(uint256 seed) internal view returns (bytes32) {
        return ids[seed % ids.length];
    }

    /// The first channel from a random start that satisfies `ok`; a random one if none does.
    function _pick(uint256 seed, function(bytes32) internal view returns (bool) ok) internal view returns (bytes32) {
        uint256 n = ids.length;
        uint256 start = seed % n;
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = ids[(start + i) % n];
            if (ok(id)) return id;
        }
        return ids[start];
    }

    /// One time in three, a channel satisfying `preferred` if there is one; otherwise as `_pick`.
    function _pickPreferring(
        uint256 seed,
        function(bytes32) internal view returns (bool) preferred,
        function(bytes32) internal view returns (bool) ok
    ) internal view returns (bytes32) {
        if ((seed >> 160) % 3 == 0) {
            bytes32 id = _pick(seed, preferred);
            if (preferred(id)) return id;
        }
        return _pick(seed, ok);
    }

    function _isChallenged(bytes32 id) internal view returns (bool) {
        (, uint256 claimed,,) = settlement.closeState(id);
        return _isClosing(id) && claimed != 0;
    }

    function _isLiveHold(bytes32 id) internal view returns (bool) {
        return _isHeld(id) && _acceptsVouchers(id);
    }

    function _state(bytes32 id) internal view returns (ChannelSettlement.State st) {
        (,,, st) = settlement.channel(id);
    }

    function _isOpen(bytes32 id) internal view returns (bool) {
        return _state(id) == ChannelSettlement.State.Open;
    }

    function _isClosing(bytes32 id) internal view returns (bool) {
        return _state(id) == ChannelSettlement.State.Closing;
    }

    function _isHeld(bytes32 id) internal view returns (bool) {
        return _state(id) == ChannelSettlement.State.Held;
    }

    function _canBeChallenged(bytes32 id) internal view returns (bool) {
        (uint256 closingAt,,,) = settlement.closeState(id);
        return _isClosing(id) && block.timestamp < closingAt;
    }

    function _acceptsVouchers(bytes32 id) internal view returns (bool) {
        ChannelSettlement.State st = _state(id);
        if (st == ChannelSettlement.State.Held) {
            (,, uint256 holdExpiry,) = settlement.closeState(id);
            return block.timestamp <= holdExpiry;
        }
        return st == ChannelSettlement.State.Open || st == ChannelSettlement.State.Closing;
    }

    function _configOf(bytes32 id) internal view returns (ChannelConfig memory) {
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == id) return configs[i];
        }
        revert("unknown channel");
    }

    function _idOf(ChannelConfig memory c) internal view returns (bytes32) {
        return settlement.channelId(c);
    }

    /// After every action: seq and accounted never go down, states only move forward, a held
    /// channel holds exactly its balance, and a closed channel's two slots never change again.
    function _observe() internal {
        uint256 held;
        uint256 closedCount;
        for (uint256 i = 0; i < ids.length; i++) {
            bytes32 id = ids[i];
            (uint256 bal, uint256 acc, uint256 seq, ChannelSettlement.State st) = settlement.channel(id);
            if (seq < lastSeq[id]) seqDecreased = true;
            if (acc < lastAccounted[id]) accountedDecreased = true;
            if (!_forward(lastState[id], uint8(st))) stateWentBack = true;
            if (lastState[id] != uint8(st)) {
                if (st == ChannelSettlement.State.Closing) enteredClosing++;
                else if (st == ChannelSettlement.State.Held) enteredHeld++;
                else if (st == ChannelSettlement.State.Closed) enteredClosed++;
            }
            if (st == ChannelSettlement.State.Held) {
                held++;
                (,, uint256 holdExpiry, uint256 h) = settlement.closeState(id);
                if (block.timestamp <= holdExpiry && h != bal) heldNotBalance = true;
            }
            bytes32 slot = keccak256(abi.encode(id, uint256(0)));
            bytes32 hot = vm.load(address(settlement), slot);
            bytes32 cold = vm.load(address(settlement), bytes32(uint256(slot) + 1));
            if (closed[id]) {
                if (hot != closedHot[id] || cold != closedCold[id]) closedChanged = true;
            } else if (st == ChannelSettlement.State.Closed) {
                (closed[id], closedHot[id], closedCold[id]) = (true, hot, cold);
            }
            if (st == ChannelSettlement.State.Closed) closedCount++;
            (lastSeq[id], lastAccounted[id], lastState[id]) = (seq, acc, uint8(st));
        }
        if (held > heldChannels) heldChannels = held;
        if (closedCount > closedChannels) closedChannels = closedCount;
    }

    /// Open → Closing → (Held →) Closed, never back.
    function _forward(uint8 from, uint8 to) internal pure returns (bool) {
        if (from == to) return true;
        uint8 sOpen = uint8(ChannelSettlement.State.Open);
        uint8 sClosing = uint8(ChannelSettlement.State.Closing);
        uint8 sHeld = uint8(ChannelSettlement.State.Held);
        uint8 sClosed = uint8(ChannelSettlement.State.Closed);
        if (from == sOpen) return to == sClosing;
        if (from == sClosing) return to == sHeld || to == sClosed;
        if (from == sHeld) return to == sClosed;
        return false;
    }
}

/// The stateful properties of channel settlement, over random sequences of opening, settling,
/// withdrawing, closing, challenging, waiving, finalizing, sweeping and time passing.
contract ChannelInvariantTest is ChannelCloseBase {
    ChannelHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ChannelHandler(settlement, token, provider, mock1, mock4, set, MOCK1_INDEX, MOCK4_INDEX);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = ChannelHandler.open.selector;
        selectors[1] = ChannelHandler.settle.selector;
        selectors[2] = ChannelHandler.withdraw.selector;
        selectors[3] = ChannelHandler.requestClose.selector;
        selectors[4] = ChannelHandler.challengeClose.selector;
        selectors[5] = ChannelHandler.waive.selector;
        selectors[6] = ChannelHandler.finalizeClose.selector;
        selectors[7] = ChannelHandler.sweepExpiredHold.selector;
        selectors[8] = ChannelHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// Every deposited unit is, to the unit, in exactly one place: a channel's balance (held or
    /// free), the provider's accrual, the provider's wallet (withdrawn) or a payer's wallet
    /// (returned). And the contract holds exactly the balances plus the accrual.
    function invariant_tokens_are_conserved_to_the_unit() public view {
        uint256 balances;
        for (uint256 i = 0; i < handler.count(); i++) {
            (uint256 bal,,,) = settlement.channel(handler.ids(i));
            balances += bal;
        }
        uint256 accrued = settlement.accrued(provider, address(token));
        assertEq(token.balanceOf(address(settlement)), balances + accrued, "contract holds balances + accrual");
        assertEq(
            handler.deposited(),
            balances + accrued + handler.withdrawn() + handler.returned(),
            "deposits = balances + accrued + withdrawn + returned"
        );
        assertEq(token.balanceOf(provider), handler.withdrawn(), "the provider received only withdrawals");
        uint256 payersHold;
        address[4] memory ps = handler.payerList();
        for (uint256 i = 0; i < 4; i++) {
            payersHold += token.balanceOf(ps[i]);
        }
        assertEq(payersHold, handler.returned(), "the payers received only returns");
        assertFalse(handler.accrualMismatch(), "a batch accrued what its channels paid");
        assertFalse(handler.wentDown(), "no balance moved the wrong way");
    }

    /// Per channel: what it paid the provider plus what it returned plus its balance is its
    /// deposit, so no channel pays out more than it took in.
    function invariant_no_channel_pays_out_more_than_its_deposit() public view {
        for (uint256 i = 0; i < handler.count(); i++) {
            bytes32 id = handler.ids(i);
            (uint256 bal,,,) = settlement.channel(id);
            uint256 out = handler.paidOf(id) + handler.returnedOf(id);
            assertLe(out, handler.depositOf(id), "paid out <= deposit");
            assertEq(out + bal, handler.depositOf(id), "paid + returned + balance = deposit");
        }
    }

    function invariant_seq_and_accounted_never_decrease() public view {
        assertFalse(handler.seqDecreased(), "seq decreased");
        assertFalse(handler.accountedDecreased(), "accounted decreased");
    }

    /// Once closed, neither of a channel's slots changes again: no settlement, waive, challenge,
    /// close request, finalization or sweep is accepted, and it cannot be reopened.
    function invariant_a_closed_channel_accepts_nothing() public view {
        assertFalse(handler.closedChanged(), "a closed channel changed");
        for (uint256 i = 0; i < handler.count(); i++) {
            bytes32 id = handler.ids(i);
            if (!handler.closed(id)) continue;
            bytes32 slot = keccak256(abi.encode(id, uint256(0)));
            assertEq(vm.load(address(settlement), slot), handler.closedHot(id), "hot slot");
            assertEq(vm.load(address(settlement), bytes32(uint256(slot) + 1)), handler.closedCold(id), "cold slot");
            (uint256 bal,,, ChannelSettlement.State st) = settlement.channel(id);
            assertEq(bal, 0, "a closed channel is empty");
            assertEq(uint8(st), uint8(ChannelSettlement.State.Closed), "and stays closed");
        }
    }

    function invariant_states_only_move_forward_and_a_held_channel_holds_its_balance() public view {
        assertFalse(handler.stateWentBack(), "state went back");
        assertFalse(handler.heldNotBalance(), "held != balance");
    }

    /// What one run reached, logged at the end of every run (shown with `-vv`).
    function afterInvariant() external {
        emit log_named_uint("channels", handler.count());
        emit log_named_uint("entered Closing", handler.enteredClosing());
        emit log_named_uint("entered Held", handler.enteredHeld());
        emit log_named_uint("entered Closed", handler.enteredClosed());
        emit log_named_uint("batches that settled out of a hold", handler.heldSettled());
    }
}
