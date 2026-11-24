// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChannelCloseBase} from "./ChannelCloseBase.sol";
import {AcceptAllTarget} from "./mocks/Mocks.sol";
import {FalseReturningERC3009, MockERC3009, ReentrantERC3009} from "./mocks/MockERC3009.sol";
import {IVerifierRegistry, VerifierEntry} from "../src/IVerifierRegistry.sol";
import {ChannelSettlement, ChannelConfig} from "../src/ChannelSettlement.sol";

/// Closing a channel: `requestClose`, `challengeClose`, `finalizeClose`, `sweepExpiredHold` and
/// `waive`, with the previous version's close, challenge, waive and integration cases ported
/// (`test_v1_03`, `test_v2_*`, `test_it*`, see `test/PORTED.md`).
contract ChannelCloseTest is ChannelCloseBase {
    ChannelConfig internal c;
    bytes32 internal id;
    address internal payer;
    uint256 internal key;
    uint256 internal closingAt;

    function setUp() public override {
        super.setUp();
        (payer, key) = (payers[0], payerKeys[0]);
        c = _config(payer, "close");
        id = _open(c, key, DEPOSIT);
        closingAt = T0 + CHALLENGE_WINDOW;
    }

    // ── V1 batch suite, case 3 ──────────────────────────────────────────────────────────────────

    function test_v1_03_request_close_then_finalize_returns_the_deposit() public {
        uint256 before = token.balanceOf(payer);
        vm.expectEmit(true, false, false, true, address(settlement));
        emit ChannelSettlement.CloseRequested(id, closingAt);
        _requestClose(c);
        _assertState(id, ChannelSettlement.State.Closing);
        assertEq(_closingAt(id), closingAt, "closingAt");

        vm.warp(closingAt);
        vm.expectEmit(true, false, false, true, address(settlement));
        emit ChannelSettlement.ChannelFinalized(id, DEPOSIT, 0);
        vm.prank(stranger); // anyone may finalize; the payer is paid
        settlement.finalizeClose(c);

        assertEq(token.balanceOf(payer), before + DEPOSIT, "refund");
        assertEq(_balanceOf(id), 0, "channel emptied");
        _assertState(id, ChannelSettlement.State.Closed);
    }

    // ── V2 channel suite: cumulative amounts (G1) ───────────────────────────────────────────────

    function test_v2_g1_cumulative_amount_persists_across_batches() public {
        _settleRange(c, key, 1, 3, "g1"); // one batch of three vouchers
        (uint256 bal, uint256 acc, uint256 seq,) = settlement.channel(id);
        assertEq(seq, 3, "batch 1: seq");
        assertEq(acc, 3 * AMOUNT, "batch 1: accounted");
        assertEq(bal, DEPOSIT - 3 * AMOUNT, "batch 1: balance");

        _settleRange(c, key, 4, 5, "g1");
        (bal, acc, seq,) = settlement.channel(id);
        assertEq(seq, 5, "batch 2: seq");
        assertEq(acc, 5 * AMOUNT, "batch 2: accounted");
        assertEq(bal, DEPOSIT - 5 * AMOUNT, "batch 2: balance");
        assertEq(settlement.accrued(provider, address(token)), 5 * AMOUNT, "accrued");
    }

    function test_v2_g1_two_vouchers_of_one_channel_settle_in_one_batch() public {
        _settleOne(c, key, _std(1, "sc"));
        _mockSettle(_one(c), _lanes2(_lane(0, key, _std(2, "sc")), _lane(0, key, _std(3, "sc"))));
        (, uint256 acc, uint256 seq,) = settlement.channel(id);
        assertEq(seq, 3, "seq");
        assertEq(acc, 3 * AMOUNT, "accounted");
    }

    function test_v2_g1_a_voucher_signed_with_a_wrong_cumulative_amount_is_skipped() public {
        // The frame carries no cumulative amount: settlement uses accounted + amount, and the
        // payer's signature over 99 units does not verify against it.
        bytes32 cm = _c("wc", 1);
        uint256 proveBy = block.timestamp + 1800;
        bytes memory frame = _frame(0, 1, AMOUNT, proveBy, _voucher(key, id, 1, AMOUNT, 99 * AMOUNT, cm, proveBy));
        bytes memory results = new bytes(1);
        results[0] = _code(ChannelSettlement.LaneResult.BadSignature);
        vm.expectRevert(_nothingSettled(results));
        _settleRaw(_one(c), cm, frame);
        (, uint256 acc, uint256 seq,) = settlement.channel(id);
        assertEq(seq, 0, "seq unchanged");
        assertEq(acc, 0, "accounted unchanged");
    }

    // ── V2 channel suite: waiving (G2) ──────────────────────────────────────────────────────────

    function test_v2_g2_waive_advances_seq_and_accounted_and_the_next_voucher_settles() public {
        _settleOne(c, key, _std(1, "w"));
        uint256 accruedBefore = settlement.accrued(provider, address(token));

        vm.expectEmit(true, false, false, true, address(settlement));
        emit ChannelSettlement.FrameWaived(id, 2, AMOUNT, 0);
        _waive(c, key, _std(2, "w"));

        (uint256 bal, uint256 acc, uint256 seq,) = settlement.channel(id);
        assertEq(seq, 2, "waive: seq");
        assertEq(acc, 2 * AMOUNT, "waive: accounted");
        assertEq(bal, DEPOSIT - AMOUNT, "waive: balance kept");
        assertEq(settlement.accrued(provider, address(token)), accruedBefore, "waive: provider not paid");

        _settleOne(c, key, _std(3, "w")); // cumulative 3 units: accounted (2) + 1
        (bal, acc, seq,) = settlement.channel(id);
        assertEq(seq, 3, "after: seq");
        assertEq(acc, 3 * AMOUNT, "after: accounted");
        assertEq(bal, DEPOSIT - 2 * AMOUNT, "after: balance");
        assertEq(settlement.accrued(provider, address(token)), accruedBefore + AMOUNT, "after: paid once more");
    }

    function test_v2_g2_only_the_provider_can_waive() public {
        ChannelSettlement.Voucher memory v = _std(1, "tp");
        bytes memory sig = _signV(key, id, v);
        vm.prank(stranger);
        vm.expectRevert(ChannelSettlement.NotProvider.selector);
        settlement.waive(c, v, sig);
        vm.prank(payer);
        vm.expectRevert(ChannelSettlement.NotProvider.selector);
        settlement.waive(c, v, sig);
        vm.prank(provider);
        settlement.waive(c, v, sig);
        assertEq(_seqOf(id), 1, "the provider can");
    }

    function test_v2_g2_waive_with_a_wrong_cumulative_amount_reverts() public {
        ChannelSettlement.Voucher memory v = _v(1, AMOUNT, 99 * AMOUNT, _c("wcum", 1), block.timestamp + 1800);
        bytes memory sig = _signV(key, id, v); // the payer did sign it
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.CumAmountMismatch.selector, AMOUNT));
        settlement.waive(c, v, sig);
    }

    // ── V2 channel suite: challenge, finalize, sweep (G3) ───────────────────────────────────────

    function test_v2_g3_request_challenge_finalize_sweep() public {
        _requestClose(c);
        assertEq(_closingAt(id), closingAt, "closingAt");

        vm.expectEmit(true, false, false, true, address(settlement));
        emit ChannelSettlement.CloseChallenged(id, 3, 3 * AMOUNT, closingAt + PROVE_WINDOW);
        _challenge(c, key, _std(3, "g3")); // the provider holds vouchers 1 to 3
        assertEq(_held(id), 3 * AMOUNT, "held");
        assertEq(_holdExpiry(id), closingAt + PROVE_WINDOW, "hold expiry: closingAt + proveWindow");
        assertEq(_balanceOf(id), DEPOSIT, "a challenge moves nothing");

        vm.warp(closingAt);
        uint256 before = token.balanceOf(payer);
        settlement.finalizeClose(c);
        assertEq(token.balanceOf(payer), before + DEPOSIT - 3 * AMOUNT, "free balance returned");
        assertEq(_balanceOf(id), 3 * AMOUNT, "held amount stays");
        _assertState(id, ChannelSettlement.State.Held);

        vm.warp(closingAt + PROVE_WINDOW + 1);
        vm.expectEmit(true, false, false, true, address(settlement));
        emit ChannelSettlement.HoldSwept(id, 3 * AMOUNT);
        vm.prank(stranger);
        settlement.sweepExpiredHold(c);
        assertEq(token.balanceOf(payer), before + DEPOSIT, "held amount swept back");
        assertEq(_balanceOf(id), 0, "emptied");
        _assertState(id, ChannelSettlement.State.Closed);
    }

    function test_v2_g3_without_a_challenge_finalize_returns_everything() public {
        _settleOne(c, key, _std(1, "nc"));
        _requestClose(c);
        vm.warp(closingAt);
        uint256 before = token.balanceOf(payer);
        vm.prank(payer);
        settlement.finalizeClose(c);
        assertEq(token.balanceOf(payer), before + DEPOSIT - AMOUNT, "full remaining balance");
        _assertState(id, ChannelSettlement.State.Closed);
    }

    function test_v2_g3_a_higher_challenge_raises_the_claim_and_a_lower_one_reverts() public {
        _settleOne(c, key, _std(1, "mc"));
        _requestClose(c);

        _challenge(c, key, _std(3, "mc"));
        assertEq(_held(id), 2 * AMOUNT, "first: 3 claimed - 1 accounted");
        _challenge(c, key, _std(5, "mc"));
        assertEq(_held(id), 4 * AMOUNT, "second: 5 - 1");

        // The previous version ignored a lower challenge; here it reverts.
        ChannelSettlement.Voucher memory v = _std(4, "mc");
        bytes memory sig = _signV(key, id, v);
        vm.prank(provider);
        vm.expectRevert(ChannelSettlement.NoNewClaim.selector);
        settlement.challengeClose(c, v, sig);
        assertEq(_held(id), 4 * AMOUNT, "unchanged");
    }

    function test_v2_g3_a_challenge_with_a_settled_voucher_reverts() public {
        _settleRange(c, key, 1, 3, "cas");
        _requestClose(c);

        ChannelSettlement.Voucher memory settled = _std(2, "cas");
        bytes memory sig = _signV(key, id, settled);
        vm.prank(provider);
        vm.expectRevert(_refused(ChannelSettlement.LaneResult.WrongSeq));
        settlement.challengeClose(c, settled, sig);

        // A later voucher whose cumulative amount is not above what is accounted claims nothing.
        ChannelSettlement.Voucher memory empty = _v(4, 0, 3 * AMOUNT, _c("cas", 4), block.timestamp + 1800);
        sig = _signV(key, id, empty);
        vm.prank(provider);
        vm.expectRevert(ChannelSettlement.NoNewClaim.selector);
        settlement.challengeClose(c, empty, sig);
    }

    function test_v2_g3_at_closing_at_the_challenge_reverts_and_finalize_works() public {
        _requestClose(c);
        vm.warp(closingAt);
        ChannelSettlement.Voucher memory v = _std(1, "b");
        bytes memory sig = _signV(key, id, v);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.ChallengeWindowClosed.selector, closingAt));
        settlement.challengeClose(c, v, sig);

        vm.prank(payer);
        settlement.finalizeClose(c);
        _assertState(id, ChannelSettlement.State.Closed);
    }

    function test_v2_g3_at_hold_expiry_the_sweep_reverts_and_a_second_later_it_works() public {
        _requestClose(c);
        _challenge(c, key, _std(1, "h"));
        uint256 holdExpiry = _holdExpiry(id);
        vm.warp(closingAt);
        settlement.finalizeClose(c);

        vm.warp(holdExpiry);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.HoldNotExpired.selector, holdExpiry));
        settlement.sweepExpiredHold(c);

        vm.warp(holdExpiry + 1);
        uint256 before = token.balanceOf(payer);
        settlement.sweepExpiredHold(c);
        assertEq(token.balanceOf(payer), before + AMOUNT, "swept");
        _assertState(id, ChannelSettlement.State.Closed);
    }

    function test_v2_g3_the_hold_is_capped_at_the_balance() public {
        ChannelConfig memory small = _config(payer, "small");
        bytes32 sid = _open(small, key, 5 * AMOUNT);
        _settleRange(small, key, 1, 3, "ib");
        assertEq(_balanceOf(sid), 2 * AMOUNT, "balance");

        _requestClose(small);
        _challenge(small, key, _v(100, AMOUNT, 100 * AMOUNT, _c("ib", 100), block.timestamp + 1800));
        assertEq(_held(sid), 2 * AMOUNT, "held: capped at the balance");

        vm.warp(closingAt);
        uint256 before = token.balanceOf(payer);
        settlement.finalizeClose(small);
        assertEq(token.balanceOf(payer), before, "nothing free");
        assertEq(_balanceOf(sid), 2 * AMOUNT, "all of it held");
        _assertState(sid, ChannelSettlement.State.Held);
    }

    /// Inverted on purpose: the previous version kept the hold at 5 after three of the five
    /// vouchers settled, and locked 3 units of the payer's free balance until the hold expired.
    function test_v2_g3_vouchers_settled_while_closing_shrink_the_hold() public {
        _requestClose(c);
        _challenge(c, key, _std(5, "sdd"));
        assertEq(_held(id), 5 * AMOUNT, "held");

        _settleRange(c, key, 1, 3, "sdd");
        assertEq(_balanceOf(id), DEPOSIT - 3 * AMOUNT, "balance");
        assertEq(_held(id), 2 * AMOUNT, "the hold shrinks by what settled");

        vm.warp(closingAt);
        uint256 before = token.balanceOf(payer);
        settlement.finalizeClose(c);
        assertEq(token.balanceOf(payer), before + DEPOSIT - 5 * AMOUNT, "free: deposit - 3 settled - 2 held");
        assertEq(_balanceOf(id), 2 * AMOUNT, "2 held");

        _settleRange(c, key, 4, 5, "sdd");
        assertEq(_balanceOf(id), 0, "the hold settled in full");
        _assertState(id, ChannelSettlement.State.Closed);
        assertEq(settlement.accrued(provider, address(token)), 5 * AMOUNT, "five paid");
        assertEq(token.balanceOf(payer), before + DEPOSIT - 5 * AMOUNT, "and nothing more returned");
    }

    // ── V2 integration suite (IT) ───────────────────────────────────────────────────────────────

    function test_it1_a_new_channel_has_its_deposit_and_no_close_state() public view {
        (uint256 bal, uint256 acc, uint256 seq, ChannelSettlement.State st) = settlement.channel(id);
        assertEq(bal, DEPOSIT, "balance");
        assertEq(acc, 0, "accounted");
        assertEq(seq, 0, "seq");
        assertEq(uint8(st), uint8(ChannelSettlement.State.Open), "state");
        (uint256 cAt, uint256 claimed, uint256 holdExpiry, uint256 held) = settlement.closeState(id);
        assertEq(cAt + claimed + holdExpiry + held, 0, "no close state");
        assertEq(uint256(vm.load(address(settlement), bytes32(uint256(_slotOf(id)) + 1))), 0, "cold slot untouched");
    }

    /// Inverted on purpose: the previous version let its owner re-register a model with other
    /// verifier contracts. Here nothing can re-point an id.
    function test_it1_re_pointing_a_verifier_is_impossible() public {
        bytes32 id1 = set[MOCK1_INDEX];
        // The same code at another address has the same id, and the id is taken.
        VerifierEntry memory moved = mock1;
        moved.target = address(new AcceptAllTarget());
        vm.expectRevert(abi.encodeWithSelector(IVerifierRegistry.AlreadyRegistered.selector, id1));
        registry.register(moved);

        // A batch cannot supply the moved entry under the registered id.
        ChannelSettlement.Voucher memory v = _std(1, "rp");
        bytes32[] memory cm = new bytes32[](1);
        cm[0] = v.inputCommitment;
        bytes memory frame = _frame(0, 1, AMOUNT, v.proveBy, _signV(key, id, v));
        ChannelConfig[] memory cs = _one(c);
        bytes memory out = new bytes(OUTPUT_SIZE);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.VerifierUnavailable.selector, id1));
        settlement.settleBatch(moved, set, MOCK1_INDEX, cs, frame, cm, out, "");

        // Other code is another id, which the channel's verifier set does not name.
        VerifierEntry memory other = mock1;
        other.vkHash = keccak256("another circuit");
        bytes32 otherId = registry.register(other);
        bytes32[] memory otherSet = new bytes32[](1);
        otherSet[0] = otherId;
        bytes memory results = new bytes(1);
        results[0] = _code(ChannelSettlement.LaneResult.VerifierNotAllowed);
        vm.expectRevert(_nothingSettled(results));
        settlement.settleBatch(other, otherSet, 0, cs, frame, cm, out, "");

        assertEq(keccak256(abi.encode(registry.entry(id1))), keccak256(abi.encode(mock1)), "the entry is as registered");
        _settleOne(c, key, v);
        assertEq(_seqOf(id), 1, "and still settles");
    }

    function testFuzz_it2_the_provider_is_paid_exactly_the_settled_vouchers(uint8 nPaid, uint8 nWaive, uint8 nPaidAfter)
        public
    {
        nPaid = uint8(bound(nPaid, 1, 8));
        nWaive = uint8(bound(nWaive, 0, 4));
        nPaidAfter = uint8(bound(nPaidAfter, 0, 4));
        uint256 seq;
        uint256 expected;
        for (uint256 i = 0; i < nPaid; i++) {
            _settleOne(c, key, _std(++seq, "fz"));
            expected += AMOUNT;
        }
        for (uint256 i = 0; i < nWaive; i++) {
            _waive(c, key, _std(++seq, "fz"));
        }
        for (uint256 i = 0; i < nPaidAfter; i++) {
            _settleOne(c, key, _std(++seq, "fz"));
            expected += AMOUNT;
        }
        uint256 accrued = settlement.accrued(provider, address(token));
        assertEq(accrued, expected, "accrued = settled vouchers");
        assertEq(_balanceOf(id) + accrued, DEPOSIT, "balance + paid = deposit");
        assertEq(_accountedOf(id), seq * AMOUNT, "accounted = settled + waived");

        vm.prank(provider);
        settlement.withdraw(address(token), accrued);
        assertEq(token.balanceOf(provider), expected, "the provider received exactly that");
    }

    function testFuzz_it2_with_a_challenge_close(uint8 nBefore, uint8 nAfter) public {
        nBefore = uint8(bound(nBefore, 1, 8));
        nAfter = uint8(bound(nAfter, 1, 5));
        _settleRange(c, key, 1, nBefore, "pre");
        uint256 paidBefore = settlement.accrued(provider, address(token));

        _requestClose(c);
        uint256 last = uint256(nBefore) + nAfter;
        _challenge(c, key, _std(last, "pre"));
        assertEq(settlement.accrued(provider, address(token)), paidBefore, "a challenge pays nothing");
        assertEq(_held(id), uint256(nAfter) * AMOUNT, "held");

        vm.warp(closingAt);
        uint256 before = token.balanceOf(payer);
        settlement.finalizeClose(c);
        _settleRange(c, key, uint256(nBefore) + 1, last, "pre");

        uint256 paid = settlement.accrued(provider, address(token));
        uint256 returned = token.balanceOf(payer) - before;
        assertEq(paid, last * AMOUNT, "every voucher paid once");
        assertEq(paid + returned, DEPOSIT, "paid + returned = deposit");
        assertEq(_accountedOf(id), last * AMOUNT, "accounted");
        _assertState(id, ChannelSettlement.State.Closed);
    }

    function test_it3_a_mixed_batch_settles_open_and_closing_channels_and_reports_the_rest() public {
        ChannelConfig[] memory cs = new ChannelConfig[](3);
        cs[0] = _config(payers[1], "it3-0");
        cs[1] = _config(payers[2], "it3-1");
        cs[2] = _config(payers[3], "it3-2");
        for (uint256 i = 0; i < 3; i++) {
            _open(cs[i], payerKeys[i + 1], DEPOSIT);
        }
        _requestClose(cs[1]);

        Lane[] memory lanes = new Lane[](3);
        lanes[0] = _lane(0, payerKeys[1], _std(1, "it3-0")); // open
        lanes[1] = _lane(1, payerKeys[2], _std(1, "it3-1")); // closing
        lanes[2] = _lane(2, payerKeys[3], _v(1, AMOUNT, AMOUNT, _c("it3-2", 1), block.timestamp - 1)); // expired
        // lane 3 is padding
        vm.recordLogs();
        _mockSettle(cs, lanes);
        (uint256 total, bytes memory results) = _batchSettled();

        bytes memory expected = new bytes(4);
        expected[2] = _code(ChannelSettlement.LaneResult.Expired);
        expected[3] = _code(ChannelSettlement.LaneResult.Padding);
        assertEq(results, expected, "lane results");
        assertEq(total, 2 * AMOUNT, "two lanes paid");
        assertEq(_seqOf(_channelId(cs[0])), 1, "open channel settled");
        assertEq(_seqOf(_channelId(cs[1])), 1, "closing channel settled");
        assertEq(_seqOf(_channelId(cs[2])), 0, "expired lane untouched");
        assertEq(_balanceOf(_channelId(cs[2])), DEPOSIT, "expired lane untouched");
    }

    function test_it3_a_closing_channel_settled_in_a_batch_finalizes_with_the_rest() public {
        ChannelConfig[] memory cs = new ChannelConfig[](2);
        cs[0] = c;
        cs[1] = _config(payers[1], "it3b");
        _open(cs[1], payerKeys[1], DEPOSIT);
        _requestClose(cs[1]);
        _mockSettle(cs, _lanes2(_lane(0, key, _std(1, "it3b-0")), _lane(1, payerKeys[1], _std(1, "it3b-1"))));

        vm.warp(closingAt);
        uint256 before = token.balanceOf(payers[1]);
        settlement.finalizeClose(cs[1]);
        assertEq(token.balanceOf(payers[1]) - before, DEPOSIT - AMOUNT, "remaining balance returned");
    }

    /// Inverted on purpose, as for G3: the previous version returned 94 of 100 here and kept the
    /// settled voucher's unit in the hold.
    function test_it3_a_challenged_channel_settles_in_a_batch_and_its_hold_shrinks() public {
        ChannelConfig[] memory cs = new ChannelConfig[](2);
        cs[0] = c;
        cs[1] = _config(payers[1], "it3c");
        bytes32 id1 = _open(cs[1], payerKeys[1], DEPOSIT);
        _requestClose(cs[1]);
        _challenge(cs[1], payerKeys[1], _std(5, "it3c-1"));
        assertEq(_held(id1), 5 * AMOUNT, "held");

        vm.recordLogs();
        _mockSettle(cs, _lanes2(_lane(0, key, _std(1, "it3c-0")), _lane(1, payerKeys[1], _std(1, "it3c-1"))));
        (uint256 total, bytes memory results) = _batchSettled();
        bytes memory expected = new bytes(4);
        (expected[2], expected[3]) =
        (_code(ChannelSettlement.LaneResult.Padding), _code(ChannelSettlement.LaneResult.Padding));
        assertEq(results, expected, "two settled, two padding");
        assertEq(total, 2 * AMOUNT, "total");
        assertEq(_held(id1), 4 * AMOUNT, "hold shrank by the settled voucher");

        vm.warp(closingAt);
        uint256 before = token.balanceOf(payers[1]);
        settlement.finalizeClose(cs[1]);
        assertEq(token.balanceOf(payers[1]) - before, DEPOSIT - AMOUNT - 4 * AMOUNT, "free: 100 - 1 - 4");
    }

    // ── Two checks that only the gas pins could notice before closing existed ───────────────────

    /// A closing channel settles vouchers (settlement must not refuse it), and refuses a second
    /// close request, a sweep, and finalization before the challenge window ends.
    function test_a_closing_channel_settles_and_refuses_what_it_must() public {
        _requestClose(c);
        _settleOne(c, key, _std(1, "cl"));
        assertEq(_seqOf(id), 1, "settled while closing");

        vm.prank(payer);
        vm.expectRevert(_wrongState(ChannelSettlement.State.Closing));
        settlement.requestClose(c);
        vm.expectRevert(_wrongState(ChannelSettlement.State.Closing));
        settlement.sweepExpiredHold(c);
        vm.warp(closingAt - 1);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.ChallengeWindowOpen.selector, closingAt));
        settlement.finalizeClose(c);
    }

    /// Waiving moves `accounted` without spending the balance, so it can reach 2^96 - 1. The next
    /// voucher's cumulative amount would then need 97 bits; even if the payer signs that word,
    /// the lane is refused, and the slot keeps its sequence number.
    function test_a_cumulative_amount_beyond_96_bits_never_settles() public {
        uint256 max = type(uint96).max;
        _waive(c, key, _v(1, max, max, _c("big", 1), block.timestamp + 1800)); // above the balance: allowed
        assertEq(_accountedOf(id), max, "accounted at the limit");

        bytes32 cm = _c("big", 2);
        uint256 proveBy = block.timestamp + 1800;
        bytes memory frame = _frame(0, 2, 1, proveBy, _voucher(key, id, 2, 1, max + 1, cm, proveBy));
        bytes memory results = new bytes(1);
        results[0] = _code(ChannelSettlement.LaneResult.BadSignature);
        vm.expectRevert(_nothingSettled(results));
        _settleRaw(_one(c), cm, frame);

        (uint256 bal, uint256 acc, uint256 seq,) = settlement.channel(id);
        assertEq(seq, 1, "seq");
        assertEq(acc, max, "accounted");
        assertEq(bal, DEPOSIT, "balance");

        // Nor can waiving go past it.
        ChannelSettlement.Voucher memory v = _v(2, 1, max, cm, proveBy);
        bytes memory sig = _signV(key, id, v);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.CumAmountMismatch.selector, max + 1));
        settlement.waive(c, v, sig);
    }

    // ── Holds and the prove window ──────────────────────────────────────────────────────────────

    function test_the_hold_ends_at_closing_at_plus_the_prove_window_whatever_the_voucher_says() public {
        _requestClose(c);
        // A voucher due in one minute and, later, one due a full prove window ahead.
        _challenge(c, key, _v(1, AMOUNT, AMOUNT, _c("he", 1), block.timestamp + 60));
        assertEq(_holdExpiry(id), closingAt + PROVE_WINDOW, "first");
        vm.warp(closingAt - 1);
        _challenge(c, key, _v(2, AMOUNT, 2 * AMOUNT, _c("he", 2), block.timestamp + PROVE_WINDOW));
        assertEq(_holdExpiry(id), closingAt + PROVE_WINDOW, "second: the same");
    }

    function test_a_challenge_refuses_an_expired_voucher_and_one_beyond_the_prove_window() public {
        _requestClose(c);
        ChannelSettlement.Voucher memory expired = _v(1, AMOUNT, AMOUNT, _c("pw", 1), block.timestamp - 1);
        bytes memory sig = _signV(key, id, expired);
        vm.prank(provider);
        vm.expectRevert(_refused(ChannelSettlement.LaneResult.Expired));
        settlement.challengeClose(c, expired, sig);

        ChannelSettlement.Voucher memory far = _v(1, AMOUNT, AMOUNT, _c("pw", 1), block.timestamp + PROVE_WINDOW + 1);
        sig = _signV(key, id, far);
        vm.prank(provider);
        vm.expectRevert(_refused(ChannelSettlement.LaneResult.BeyondProveWindow));
        settlement.challengeClose(c, far, sig);

        // At the window's edge it holds.
        ChannelSettlement.Voucher memory edge = _v(1, AMOUNT, AMOUNT, _c("pw", 1), block.timestamp + PROVE_WINDOW);
        _challenge(c, key, edge);
        assertEq(_held(id), AMOUNT, "held");
    }

    function test_a_challenge_needs_the_payers_signature_and_the_provider() public {
        _requestClose(c);
        ChannelSettlement.Voucher memory v = _std(2, "sig");
        bytes memory forged = _signV(payerKeys[1], id, v);
        vm.prank(provider);
        vm.expectRevert(_refused(ChannelSettlement.LaneResult.BadSignature));
        settlement.challengeClose(c, v, forged);

        bytes memory sig = _signV(key, id, v);
        vm.prank(payer);
        vm.expectRevert(ChannelSettlement.NotProvider.selector);
        settlement.challengeClose(c, v, sig);
        vm.prank(stranger);
        vm.expectRevert(ChannelSettlement.NotProvider.selector);
        settlement.challengeClose(c, v, sig);
    }

    function test_only_the_payer_can_request_close() public {
        vm.prank(provider);
        vm.expectRevert(ChannelSettlement.NotPayer.selector);
        settlement.requestClose(c);
        vm.prank(stranger);
        vm.expectRevert(ChannelSettlement.NotPayer.selector);
        settlement.requestClose(c);
    }

    /// The hold's last second is `holdExpiry` itself: a late finalization then still keeps it.
    function test_at_hold_expiry_the_hold_still_counts_and_a_second_later_it_does_not() public {
        _requestClose(c);
        _challenge(c, key, _std(2, "hc"));
        uint256 holdExpiry = _holdExpiry(id);
        vm.warp(holdExpiry);
        assertEq(_held(id), 2 * AMOUNT, "held at holdExpiry");
        uint256 before = token.balanceOf(payer);
        settlement.finalizeClose(c);
        assertEq(token.balanceOf(payer), before + DEPOSIT - 2 * AMOUNT, "the hold kept");
        _assertState(id, ChannelSettlement.State.Held);
        vm.warp(holdExpiry + 1);
        assertEq(_held(id), 0, "expired a second later");
    }

    function test_finalize_after_the_hold_expired_returns_everything() public {
        _requestClose(c);
        _challenge(c, key, _std(3, "late"));
        vm.warp(closingAt + PROVE_WINDOW + 1);
        uint256 before = token.balanceOf(payer);
        settlement.finalizeClose(c);
        assertEq(token.balanceOf(payer), before + DEPOSIT, "nothing held any more");
        _assertState(id, ChannelSettlement.State.Closed);
    }

    function test_a_held_channel_refuses_a_challenge_a_close_request_and_a_second_finalize() public {
        _requestClose(c);
        _challenge(c, key, _std(2, "hr"));
        vm.warp(closingAt);
        settlement.finalizeClose(c);
        _assertState(id, ChannelSettlement.State.Held);

        ChannelSettlement.Voucher memory v = _std(3, "hr");
        bytes memory sig = _signV(key, id, v);
        vm.prank(provider);
        vm.expectRevert(_wrongState(ChannelSettlement.State.Held));
        settlement.challengeClose(c, v, sig);
        vm.prank(payer);
        vm.expectRevert(_wrongState(ChannelSettlement.State.Held));
        settlement.requestClose(c);
        vm.expectRevert(_wrongState(ChannelSettlement.State.Held));
        settlement.finalizeClose(c);
    }

    // ── Waiving ─────────────────────────────────────────────────────────────────────────────────

    function test_waive_accepts_an_expired_voucher_and_one_above_the_balance() public {
        ChannelSettlement.Voucher memory v1 = _v(1, AMOUNT, AMOUNT, _c("wx", 1), block.timestamp);
        bytes memory sig1 = _signV(key, id, v1);
        vm.warp(block.timestamp + 1); // voucher 1 has expired: no batch can settle it now
        vm.prank(provider);
        settlement.waive(c, v1, sig1);

        uint256 big = DEPOSIT + 1;
        _waive(c, key, _v(2, big, AMOUNT + big, _c("wx", 2), block.timestamp + 1800));
        (uint256 bal, uint256 acc, uint256 seq,) = settlement.channel(id);
        assertEq(seq, 2, "seq");
        assertEq(acc, AMOUNT + big, "accounted");
        assertEq(bal, DEPOSIT, "balance untouched");
        _settleOne(c, key, _v(3, AMOUNT, 2 * AMOUNT + big, _c("wx", 3), block.timestamp + 1800));
        assertEq(_seqOf(id), 3, "and the next one settles");
    }

    function test_waive_needs_the_next_voucher_and_the_payers_signature() public {
        ChannelSettlement.Voucher memory v2 = _v(2, AMOUNT, AMOUNT, _c("wn", 2), block.timestamp + 1800);
        bytes memory sig = _signV(key, id, v2);
        vm.prank(provider);
        vm.expectRevert(_refused(ChannelSettlement.LaneResult.WrongSeq));
        settlement.waive(c, v2, sig);

        ChannelSettlement.Voucher memory v1 = _std(1, "wn");
        bytes memory forged = _signV(payerKeys[1], id, v1);
        vm.prank(provider);
        vm.expectRevert(_refused(ChannelSettlement.LaneResult.BadSignature));
        settlement.waive(c, v1, forged);
    }

    function test_waive_after_finalize_returns_what_it_releases_to_the_payer() public {
        _requestClose(c);
        _challenge(c, key, _std(3, "wh"));
        vm.warp(closingAt);
        settlement.finalizeClose(c);
        uint256 before = token.balanceOf(payer);

        vm.expectEmit(true, false, false, true, address(settlement));
        emit ChannelSettlement.FrameWaived(id, 1, AMOUNT, AMOUNT);
        _waive(c, key, _std(1, "wh"));
        assertEq(token.balanceOf(payer), before + AMOUNT, "released to the payer");
        assertEq(_held(id), 2 * AMOUNT, "held");
        assertEq(_balanceOf(id), 2 * AMOUNT, "balance = held");

        _settleOne(c, key, _std(2, "wh"));
        _waive(c, key, _std(3, "wh"));
        assertEq(token.balanceOf(payer), before + 2 * AMOUNT, "the last one too");
        assertEq(_balanceOf(id), 0, "emptied");
        _assertState(id, ChannelSettlement.State.Closed);
        assertEq(settlement.accrued(provider, address(token)), AMOUNT, "one paid");
    }

    function test_waive_while_closing_shrinks_the_hold_without_paying() public {
        _requestClose(c);
        _challenge(c, key, _std(3, "wc"));
        uint256 before = token.balanceOf(payer);
        _waive(c, key, _std(1, "wc"));
        assertEq(_held(id), 2 * AMOUNT, "held");
        assertEq(token.balanceOf(payer), before, "nothing paid before finalization");
        vm.warp(closingAt);
        settlement.finalizeClose(c);
        assertEq(token.balanceOf(payer), before + DEPOSIT - 2 * AMOUNT, "the waived unit came back with the rest");
    }

    function test_waive_after_the_hold_expired_reverts() public {
        _requestClose(c);
        _challenge(c, key, _std(2, "wx"));
        uint256 holdExpiry = _holdExpiry(id);
        vm.warp(closingAt);
        settlement.finalizeClose(c);
        vm.warp(holdExpiry + 1);
        ChannelSettlement.Voucher memory v = _v(1, AMOUNT, AMOUNT, _c("wx", 1), block.timestamp);
        bytes memory sig = _signV(key, id, v);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.HoldExpired.selector, holdExpiry));
        settlement.waive(c, v, sig);
    }

    // ── Closed and unknown channels ─────────────────────────────────────────────────────────────

    function test_a_closed_channel_accepts_nothing() public {
        _settleOne(c, key, _std(1, "cx"));
        _requestClose(c);
        vm.warp(closingAt);
        settlement.finalizeClose(c);
        _assertState(id, ChannelSettlement.State.Closed);
        bytes32 hot = vm.load(address(settlement), _slotOf(id));
        bytes32 cold = vm.load(address(settlement), bytes32(uint256(_slotOf(id)) + 1));

        bytes memory results = new bytes(1);
        results[0] = _code(ChannelSettlement.LaneResult.ChannelNotOpen);
        vm.expectRevert(_nothingSettled(results));
        this.settleOneExternal(c, key, _std(2, "cx"));

        ChannelSettlement.Voucher memory v = _std(2, "cx");
        bytes memory sig = _signV(key, id, v);
        bytes memory closed = _wrongState(ChannelSettlement.State.Closed);
        vm.prank(provider);
        vm.expectRevert(closed);
        settlement.waive(c, v, sig);
        vm.prank(provider);
        vm.expectRevert(closed);
        settlement.challengeClose(c, v, sig);
        vm.prank(payer);
        vm.expectRevert(closed);
        settlement.requestClose(c);
        vm.expectRevert(closed);
        settlement.finalizeClose(c);
        vm.expectRevert(closed);
        settlement.sweepExpiredHold(c);
        bytes memory auth = _authorize(key, payer, DEPOSIT, id);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.ChannelExists.selector, id));
        settlement.openChannel(c, DEPOSIT, VALID_BEFORE, auth);

        assertEq(vm.load(address(settlement), _slotOf(id)), hot, "hot slot unchanged");
        assertEq(vm.load(address(settlement), bytes32(uint256(_slotOf(id)) + 1)), cold, "cold slot unchanged");
    }

    function test_close_calls_on_a_config_that_was_never_opened_revert() public {
        ChannelConfig memory other = c;
        other.salt = "never opened";
        ChannelSettlement.Voucher memory v = _std(1, "no");
        bytes memory sig = _signV(key, _channelId(other), v);
        bytes memory none = _wrongState(ChannelSettlement.State.None);
        vm.prank(payer);
        vm.expectRevert(none);
        settlement.requestClose(other);
        vm.prank(provider);
        vm.expectRevert(none);
        settlement.challengeClose(other, v, sig);
        vm.prank(provider);
        vm.expectRevert(none);
        settlement.waive(other, v, sig);
        vm.expectRevert(none);
        settlement.finalizeClose(other);
        vm.expectRevert(none);
        settlement.sweepExpiredHold(other);
    }

    // ── Edge cases ──────────────────────────────────────────────────────────────────────────────

    /// The provider built and signed a batch, then the payer asked to close before it landed.
    function test_edge_a_batch_pending_when_close_is_requested_still_settles() public {
        bytes memory pending =
            _mockSettleCall(_one(c), _lanes2(_lane(0, key, _std(1, "pe")), _lane(0, key, _std(2, "pe"))));
        _requestClose(c);
        (bool ok,) = address(settlement).call(pending);
        assertTrue(ok, "settled while closing");
        assertEq(_seqOf(id), 2, "seq");
        vm.warp(closingAt);
        uint256 before = token.balanceOf(payer);
        settlement.finalizeClose(c);
        assertEq(token.balanceOf(payer), before + DEPOSIT - 2 * AMOUNT, "the rest returned");
    }

    /// The same batch landing only after finalization: without a challenge it pays nothing and
    /// reverts; with one, it settles out of the hold.
    function test_edge_a_batch_landing_after_finalize_settles_only_against_a_hold() public {
        ChannelConfig memory c2 = _config(payers[1], "pe2");
        _open(c2, payerKeys[1], DEPOSIT);
        bytes memory late = _mockSettleCall(_one(c), _lanes1(_lane(0, key, _std(1, "pl"))));
        bytes memory held = _mockSettleCall(_one(c2), _lanes1(_lane(0, payerKeys[1], _std(1, "ph"))));
        _requestClose(c);
        _requestClose(c2);
        _challenge(c2, payerKeys[1], _std(1, "ph"));
        vm.warp(closingAt);
        settlement.finalizeClose(c);
        settlement.finalizeClose(c2);

        bytes memory results = new bytes(1);
        results[0] = _code(ChannelSettlement.LaneResult.ChannelNotOpen);
        (bool ok, bytes memory ret) = address(settlement).call(late);
        assertFalse(ok, "no hold: refused");
        assertEq(ret, _nothingSettled(results), "ChannelNotOpen");

        (ok,) = address(settlement).call(held);
        assertTrue(ok, "held: settles");
        _assertState(_channelId(c2), ChannelSettlement.State.Closed);
    }

    function test_edge_a_challenge_in_the_last_second_of_the_window_holds() public {
        _requestClose(c);
        vm.warp(closingAt - 1);
        _challenge(c, key, _std(2, "ls"));
        assertEq(_held(id), 2 * AMOUNT, "held");
        assertEq(_holdExpiry(id), closingAt + PROVE_WINDOW, "the same expiry as an early challenge");
        vm.warp(closingAt);
        uint256 before = token.balanceOf(payer);
        settlement.finalizeClose(c);
        assertEq(token.balanceOf(payer), before + DEPOSIT - 2 * AMOUNT, "free part");
        _assertState(id, ChannelSettlement.State.Held);
    }

    function test_edge_at_hold_expiry_a_held_voucher_settles_and_a_second_later_it_does_not() public {
        _requestClose(c);
        _challenge(c, key, _std(2, "hx"));
        uint256 holdExpiry = _holdExpiry(id);
        vm.warp(closingAt);
        settlement.finalizeClose(c);

        vm.warp(holdExpiry);
        _settleOne(c, key, _std(1, "hx"));
        assertEq(_seqOf(id), 1, "settled at the last second");

        vm.warp(holdExpiry + 1);
        bytes memory results = new bytes(1);
        results[0] = _code(ChannelSettlement.LaneResult.ChannelNotOpen);
        vm.expectRevert(_nothingSettled(results));
        this.settleOneExternal(c, key, _std(2, "hx"));
        settlement.sweepExpiredHold(c);
        _assertState(id, ChannelSettlement.State.Closed);
    }

    function test_edge_waive_after_settle_reverts_and_the_next_voucher_can_be_waived() public {
        _settleOne(c, key, _std(1, "ws"));
        ChannelSettlement.Voucher memory v1 = _std(1, "ws");
        bytes memory sig = _signV(key, id, v1);
        vm.prank(provider);
        vm.expectRevert(_refused(ChannelSettlement.LaneResult.WrongSeq));
        settlement.waive(c, v1, sig);
        _waive(c, key, _std(2, "ws"));
        assertEq(_seqOf(id), 2, "next waived");
        assertEq(settlement.accrued(provider, address(token)), AMOUNT, "only the settled one paid");
    }

    function test_edge_finalize_twice_reverts() public {
        // Without a hold the channel is closed by the first call.
        _requestClose(c);
        vm.warp(closingAt);
        settlement.finalizeClose(c);
        vm.expectRevert(_wrongState(ChannelSettlement.State.Closed));
        settlement.finalizeClose(c);

        // With a hold it is held.
        ChannelConfig memory c2 = _config(payers[1], "ft");
        bytes32 id2 = _open(c2, payerKeys[1], DEPOSIT);
        _requestClose(c2);
        _challenge(c2, payerKeys[1], _std(1, "ft"));
        vm.warp(block.timestamp + CHALLENGE_WINDOW);
        uint256 before = token.balanceOf(payers[1]);
        settlement.finalizeClose(c2);
        vm.expectRevert(_wrongState(ChannelSettlement.State.Held));
        settlement.finalizeClose(c2);
        assertEq(token.balanceOf(payers[1]), before + DEPOSIT - AMOUNT, "paid once");
        assertEq(_balanceOf(id2), AMOUNT, "held");
    }

    function test_edge_a_smart_wallet_payer_closes_its_channel() public {
        ChannelConfig memory w = _config(address(wallet), "wallet");
        bytes32 wid = _open(w, walletOwnerKey, DEPOSIT);
        _settleOne(w, walletOwnerKey, _std(1, "sw")); // an ERC-1271 voucher settles

        // The wallet's owner is not the payer; the wallet is, and calls through its account.
        vm.prank(wallet.owner());
        vm.expectRevert(ChannelSettlement.NotPayer.selector);
        settlement.requestClose(w);
        vm.prank(wallet.owner());
        wallet.execute(address(settlement), abi.encodeCall(ChannelSettlement.requestClose, (w)));
        _assertState(wid, ChannelSettlement.State.Closing);

        // The provider's challenge carries an ERC-1271 signature too.
        _challenge(w, walletOwnerKey, _std(3, "sw"));
        assertEq(_held(wid), 2 * AMOUNT, "held");

        vm.warp(block.timestamp + CHALLENGE_WINDOW);
        uint256 before = token.balanceOf(address(wallet));
        settlement.finalizeClose(w);
        assertEq(token.balanceOf(address(wallet)), before + DEPOSIT - 3 * AMOUNT, "free part to the wallet");
        _settleOne(w, walletOwnerKey, _std(2, "sw"));
        vm.warp(_holdExpiry(wid) + 1);
        settlement.sweepExpiredHold(w);
        assertEq(token.balanceOf(address(wallet)), before + DEPOSIT - 2 * AMOUNT, "the rest of the hold");

        // A wallet that stops accepting its owner's signatures cannot be held against.
        ChannelConfig memory w2 = _config(address(wallet), "wallet2");
        _open(w2, walletOwnerKey, DEPOSIT);
        vm.prank(wallet.owner());
        wallet.execute(address(settlement), abi.encodeCall(ChannelSettlement.requestClose, (w2)));
        wallet.setAccepting(false);
        ChannelSettlement.Voucher memory v = _std(1, "sw2");
        bytes memory sig = _signV(walletOwnerKey, _channelId(w2), v);
        vm.prank(provider);
        vm.expectRevert(_refused(ChannelSettlement.LaneResult.BadSignature));
        settlement.challengeClose(w2, v, sig);
    }

    // ── Paying the payer back ───────────────────────────────────────────────────────────────────

    function test_finalize_and_sweep_write_state_before_paying() public {
        ReentrantERC3009 rt = new ReentrantERC3009();
        ChannelConfig memory r = _openIn(address(rt), "rt");
        _requestClose(r);
        _challenge(r, key, _std(1, "rt"));
        vm.warp(closingAt);
        rt.arm(address(settlement), abi.encodeCall(ChannelSettlement.finalizeClose, (r)));
        settlement.finalizeClose(r);
        assertTrue(rt.reentered(), "finalize: re-entered");
        assertFalse(rt.innerCallSucceeded(), "finalize: the inner call failed");
        assertEq(rt.balanceOf(payer), DEPOSIT - AMOUNT, "finalize: paid once");

        vm.warp(closingAt + PROVE_WINDOW + 1);
        rt.arm(address(settlement), abi.encodeCall(ChannelSettlement.sweepExpiredHold, (r)));
        settlement.sweepExpiredHold(r);
        assertTrue(rt.reentered(), "sweep: re-entered");
        assertFalse(rt.innerCallSucceeded(), "sweep: the inner call failed");
        assertEq(rt.balanceOf(payer), DEPOSIT, "sweep: paid once");
    }

    function test_finalize_reverts_when_the_token_reports_failure() public {
        FalseReturningERC3009 f = new FalseReturningERC3009();
        ChannelConfig memory r = _openIn(address(f), "false");
        _requestClose(r);
        vm.warp(closingAt);
        vm.expectRevert(ChannelSettlement.TransferFailed.selector);
        settlement.finalizeClose(r);
        _assertState(_channelId(r), ChannelSettlement.State.Closing);
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────────────────────

    /// External so that `vm.expectRevert` can watch a helper that builds its call first.
    function settleOneExternal(ChannelConfig memory cfg, uint256 k, ChannelSettlement.Voucher memory v) external {
        _settleOne(cfg, k, v);
    }

    function _settleRaw(ChannelConfig[] memory cs, bytes32 commitment, bytes memory frame) internal {
        bytes32[] memory cm = new bytes32[](1);
        cm[0] = commitment;
        settlement.settleBatch(mock1, set, MOCK1_INDEX, cs, frame, cm, new bytes(OUTPUT_SIZE), "");
    }

    /// Storage slot of channel `cid`'s hot word: `_channels` is the contract's first variable.
    function _slotOf(bytes32 cid) internal pure returns (bytes32) {
        return keccak256(abi.encode(cid, uint256(0)));
    }

    /// Open a channel of payer 0 in another ERC-3009 token.
    function _openIn(address asset, bytes32 salt) internal returns (ChannelConfig memory r) {
        MockERC3009(asset).mint(payer, DEPOSIT);
        r = _config(payer, salt);
        r.asset = asset;
        bytes32 rid = _channelId(r);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                MockERC3009(asset).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(RECEIVE_TYPEHASH, payer, address(settlement), DEPOSIT, uint256(0), VALID_BEFORE, rid)
                )
            )
        );
        settlement.openChannel(r, DEPOSIT, VALID_BEFORE, _sign(key, digest));
    }
}
