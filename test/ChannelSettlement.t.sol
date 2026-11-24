// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {ChannelSettlementBase} from "./ChannelSettlementBase.sol";
import {FalseReturningERC3009, MockERC3009, ReentrantERC3009} from "./mocks/MockERC3009.sol";
import {AlwaysTrueAdapter} from "./mocks/Mocks.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";
import {ProofCheck} from "../src/ProofCheck.sol";
import {ChannelSettlement, ChannelConfig} from "../src/ChannelSettlement.sol";

/// Channels with the stored K=8 and solo proofs. Tests named `test_v1_NN_…` port case NN of the
/// previous version's batch suite (see `test/PORTED.md`); the rest are new.
contract ChannelSettlementTest is ChannelSettlementBase {
    // ── Ported V1 cases ─────────────────────────────────────────────────────────────────────────

    function test_v1_01_open_stores_the_deposit_in_one_slot_and_pulls_it() public {
        ChannelConfig memory c = _config(payers[0], "a");
        vm.record();
        bytes32 id = _open(c, payerKeys[0], DEPOSIT);
        (, bytes32[] memory writes) = vm.accesses(address(settlement));

        assertEq(id, _channelId(c), "id is the struct hash of the config, chain and contract");
        assertEq(writes.length, 1, "one storage write");
        (uint256 balance, uint256 accounted, uint256 seq, ChannelSettlement.State state) = settlement.channel(id);
        assertEq(balance, DEPOSIT, "balance");
        assertEq(accounted, 0, "accounted");
        assertEq(seq, 0, "seq");
        assertEq(uint8(state), uint8(ChannelSettlement.State.Open), "state");
        assertEq(token.balanceOf(address(settlement)), DEPOSIT, "deposit held");
        assertEq(token.balanceOf(payers[0]), DEPOSIT, "deposit pulled from the payer");
    }

    function test_v1_02_opening_the_same_config_twice_reverts() public {
        ChannelConfig memory c = _config(payers[0], "a");
        bytes32 id = _open(c, payerKeys[0], DEPOSIT);
        bytes memory sig = _authorize(payerKeys[0], c.payer, DEPOSIT, id);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.ChannelExists.selector, id));
        settlement.openChannel(c, DEPOSIT, VALID_BEFORE, sig);
    }

    function test_v1_04_a_k8_batch_settles_all_eight_lanes() public {
        ChannelConfig[] memory cs = _openEight("k8");
        (uint256 total, bytes memory results) = _settleK8Recorded(cs, _k8Frames(cs, 1));

        assertEq(results, _results(8), "every lane settled");
        assertEq(total, 8 * AMOUNT, "total");
        assertEq(settlement.accrued(provider, address(token)), 8 * AMOUNT, "accrued to the provider");
        assertEq(token.balanceOf(address(settlement)), 8 * DEPOSIT, "no token moved");
        for (uint256 i = 0; i < 8; i++) {
            (uint256 balance, uint256 accounted, uint256 seq,) = settlement.channel(_channelId(cs[i]));
            assertEq(balance, DEPOSIT - AMOUNT, "balance");
            assertEq(accounted, AMOUNT, "accounted");
            assertEq(seq, 1, "seq");
        }
    }

    function test_v1_05_a_padding_lane_is_reported_and_not_paid() public {
        ChannelConfig[] memory cs = _openEight("pad");
        bytes memory frames;
        for (uint256 i = 0; i < 7; i++) {
            frames = bytes.concat(frames, _k8Frame(cs, i, 1));
        }
        vm.recordLogs();
        settlement.settleBatch(k8PaddedEntry, set, K8_PADDED_INDEX, cs, frames, k8Commitments, k8Outputs, k8Proof);
        (uint256 total, bytes memory results) = _batchSettled();

        bytes memory expected = _results(8);
        expected[7] = _code(ChannelSettlement.LaneResult.Padding);
        assertEq(results, expected, "lane 7 is padding");
        assertEq(total, 7 * AMOUNT, "seven lanes paid");
        assertEq(_balanceOf(_channelId(cs[7])), DEPOSIT, "lane 7's channel untouched");
        assertEq(_seqOf(_channelId(cs[7])), 0, "lane 7's seq untouched");
    }

    function test_v1_06_a_voucher_signed_for_another_commitment_is_skipped() public {
        ChannelConfig[] memory cs = _openEight("commitment");
        bytes memory frames;
        for (uint256 i = 0; i < 8; i++) {
            if (i == 3) {
                bytes32 other = k8Commitments[3] ^ bytes32(uint256(1));
                bytes memory sig = _voucher(payerKeys[3], _channelId(cs[3]), 1, AMOUNT, AMOUNT, other, PROVE_BY);
                frames = bytes.concat(frames, _frame(3, 1, AMOUNT, PROVE_BY, sig));
            } else {
                frames = bytes.concat(frames, _k8Frame(cs, i, 1));
            }
        }
        (uint256 total, bytes memory results) = _settleK8Recorded(cs, frames);

        bytes memory expected = _results(8);
        expected[3] = _code(ChannelSettlement.LaneResult.BadSignature);
        assertEq(results, expected, "lane 3 skipped");
        assertEq(total, 7 * AMOUNT, "seven lanes paid");
        assertEq(_balanceOf(_channelId(cs[3])), DEPOSIT, "lane 3's channel untouched");
        assertEq(_seqOf(_channelId(cs[3])), 0, "lane 3's seq untouched");
    }

    function test_v1_07_a_corrupted_voucher_signature_is_skipped() public {
        ChannelConfig[] memory cs = _openEight("sig");
        bytes memory frames;
        for (uint256 i = 0; i < 8; i++) {
            bytes memory f = _k8Frame(cs, i, 1);
            if (i == 5) f[27 + 63] = bytes1(uint8(f[27 + 63]) ^ 0x01); // last byte of s
            frames = bytes.concat(frames, f);
        }
        (uint256 total, bytes memory results) = _settleK8Recorded(cs, frames);

        bytes memory expected = _results(8);
        expected[5] = _code(ChannelSettlement.LaneResult.BadSignature);
        assertEq(results, expected, "lane 5 skipped");
        assertEq(total, 7 * AMOUNT, "seven lanes paid");
    }

    function test_v1_08_resubmitting_a_settled_batch_reverts_and_names_every_lane() public {
        ChannelConfig[] memory cs = _openEight("replay");
        bytes memory frames = _k8Frames(cs, 1);
        _settleK8(cs, frames);

        bytes memory expected = new bytes(8);
        for (uint256 i = 0; i < 8; i++) {
            expected[i] = _code(ChannelSettlement.LaneResult.WrongSeq);
        }
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.NothingSettled.selector, expected));
        _settleK8(cs, frames);
        assertEq(settlement.accrued(provider, address(token)), 8 * AMOUNT, "paid once");
    }

    function test_v1_09_an_invalid_proof_reverts() public {
        ChannelConfig[] memory cs = _openEight("bad proof");
        bytes memory p = bytes.concat(k8Proof);
        p[100] = bytes1(uint8(p[100]) ^ 0xff);
        bytes memory frames = _k8Frames(cs, 1);
        vm.expectRevert(ChannelSettlement.ProofInvalid.selector);
        settlement.settleBatch(k8Entry, set, K8_INDEX, cs, frames, k8Commitments, k8Outputs, p);
    }

    function test_v1_10_the_solo_proof_settles_one_voucher_through_the_channels_solo_entry() public {
        (ChannelConfig[] memory cs, bytes memory frame) = _soloChannel(payers[0], payerKeys[0], "escape");
        _settleSolo(cs, frame);

        bytes32 id = _channelId(cs[0]);
        assertEq(settlement.accrued(provider, address(token)), AMOUNT, "accrued");
        assertEq(_balanceOf(id), DEPOSIT - AMOUNT, "balance");
        assertEq(_seqOf(id), 1, "seq");
    }

    function test_v1_11_resubmitting_the_solo_settlement_reverts() public {
        (ChannelConfig[] memory cs, bytes memory frame) = _soloChannel(payers[0], payerKeys[0], "escape");
        _settleSolo(cs, frame);

        bytes memory expected = abi.encodePacked(_code(ChannelSettlement.LaneResult.WrongSeq));
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.NothingSettled.selector, expected));
        _settleSolo(cs, frame);
    }

    function test_v1_12_an_expired_voucher_is_skipped() public {
        ChannelConfig[] memory cs = _openEight("expired");
        bytes memory frames;
        for (uint256 i = 0; i < 8; i++) {
            if (i == 2) {
                uint256 past = block.timestamp - 1;
                bytes memory sig = _voucher(payerKeys[2], _channelId(cs[2]), 1, AMOUNT, AMOUNT, k8Commitments[2], past);
                frames = bytes.concat(frames, _frame(2, 1, AMOUNT, past, sig));
            } else {
                frames = bytes.concat(frames, _k8Frame(cs, i, 1));
            }
        }
        (uint256 total, bytes memory results) = _settleK8Recorded(cs, frames);

        bytes memory expected = _results(8);
        expected[2] = _code(ChannelSettlement.LaneResult.Expired);
        assertEq(results, expected, "lane 2 skipped");
        assertEq(total, 7 * AMOUNT, "seven lanes paid");
    }

    function test_v1_13_a_voucher_above_the_balance_is_skipped() public {
        ChannelConfig[] memory cs = new ChannelConfig[](8);
        for (uint256 i = 0; i < 8; i++) {
            cs[i] = _config(payers[i], bytes32(i));
            _open(cs[i], payerKeys[i], i == 4 ? AMOUNT - 1 : DEPOSIT);
        }
        (uint256 total, bytes memory results) = _settleK8Recorded(cs, _k8Frames(cs, 1));

        bytes memory expected = _results(8);
        expected[4] = _code(ChannelSettlement.LaneResult.InsufficientBalance);
        assertEq(results, expected, "lane 4 skipped");
        assertEq(total, 7 * AMOUNT, "seven lanes paid");
        assertEq(_balanceOf(_channelId(cs[4])), AMOUNT - 1, "lane 4's balance untouched");
    }

    function test_v1_14_a_verifier_that_is_not_registered_settles_nothing_until_anyone_registers_it() public {
        // The solo circuit under another gas allowance: a different entry, so a different id.
        VerifierEntry memory e = soloEntry;
        e.verifyGas = SOLO_VERIFY_GAS + 1;
        bytes32 id = registry.computeId(adapter.proofSystem(), e);
        bytes32[] memory s = new bytes32[](1);
        s[0] = id;

        ChannelConfig memory c = _config(payers[0], "later");
        c.verifierSetHash = keccak256(abi.encodePacked(s));
        ChannelConfig[] memory cs = new ChannelConfig[](1);
        cs[0] = c;
        _open(c, payerKeys[0], DEPOSIT); // opening does not look the ids up
        bytes memory frame = _frame(
            0,
            1,
            AMOUNT,
            PROVE_BY,
            _voucher(payerKeys[0], _channelId(c), 1, AMOUNT, AMOUNT, soloCommitments[0], PROVE_BY)
        );

        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.VerifierUnavailable.selector, id));
        settlement.settleBatch(e, s, 0, cs, frame, soloCommitments, soloOutput, soloProof);

        vm.prank(stranger);
        assertEq(registry.register(e), id, "anyone registers the same content under the same id");
        settlement.settleBatch(e, s, 0, cs, frame, soloCommitments, soloOutput, soloProof);
        assertEq(_seqOf(_channelId(c)), 1, "settled once registered");
    }

    // ── New: the four cases the plan names ──────────────────────────────────────────────────────

    function test_a_voucher_for_one_channel_cannot_settle_in_another() public {
        (ChannelConfig[] memory a, bytes memory frameForA) = _soloChannel(payers[0], payerKeys[0], "a");
        (ChannelConfig[] memory b,) = _soloChannel(payers[0], payerKeys[0], "b");

        bytes memory expected = abi.encodePacked(_code(ChannelSettlement.LaneResult.BadSignature));
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.NothingSettled.selector, expected));
        _settleSolo(b, frameForA);

        _settleSolo(a, frameForA);
        assertEq(_seqOf(_channelId(a[0])), 1, "settles in its own channel");
        assertEq(_seqOf(_channelId(b[0])), 0, "not in the other");
    }

    function test_a_lane_whose_channel_pays_in_another_asset_is_skipped() public {
        (ChannelConfig[] memory cs,) = _soloChannel(payers[0], payerKeys[0], "batch asset");
        MockERC3009 other = new MockERC3009();
        other.mint(payers[1], DEPOSIT);
        ChannelConfig memory c = _config(payers[1], "other asset");
        c.asset = address(other);
        bytes32 id = _channelId(c);
        bytes32 auth = keccak256(
            abi.encodePacked(
                "\x19\x01",
                other.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(RECEIVE_TYPEHASH, payers[1], address(settlement), DEPOSIT, uint256(0), VALID_BEFORE, id)
                )
            )
        );
        settlement.openChannel(c, DEPOSIT, VALID_BEFORE, _sign(payerKeys[1], auth));
        bytes memory sig = _voucher(payerKeys[1], id, 1, AMOUNT, AMOUNT, soloCommitments[0], PROVE_BY);

        // Same provider, but the batch's asset is the first channel's.
        ChannelConfig[] memory both = new ChannelConfig[](2);
        (both[0], both[1]) = (cs[0], c);
        bytes memory expected = abi.encodePacked(_code(ChannelSettlement.LaneResult.OtherProvider));
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.NothingSettled.selector, expected));
        _settleSolo(both, _frame(1, 1, AMOUNT, PROVE_BY, sig));

        // In a batch of its own asset it settles, and accrues in that asset.
        ChannelConfig[] memory own = new ChannelConfig[](1);
        own[0] = c;
        _settleSolo(own, _frame(0, 1, AMOUNT, PROVE_BY, sig));
        assertEq(settlement.accrued(provider, address(other)), AMOUNT, "accrued in its asset");
        assertEq(settlement.accrued(provider, address(token)), 0, "nothing in the other");
    }

    function test_a_frame_against_an_entry_outside_the_channels_set_is_skipped() public {
        ChannelConfig[] memory cs = new ChannelConfig[](8);
        bytes32[] memory soloOnly = new bytes32[](1);
        soloOnly[0] = soloId;
        for (uint256 i = 0; i < 8; i++) {
            cs[i] = _config(payers[i], bytes32(i));
            if (i == 2) cs[i].verifierSetHash = keccak256(abi.encodePacked(soloOnly));
            _open(cs[i], payerKeys[i], DEPOSIT);
        }
        (uint256 total, bytes memory results) = _settleK8Recorded(cs, _k8Frames(cs, 1));

        bytes memory expected = _results(8);
        expected[2] = _code(ChannelSettlement.LaneResult.VerifierNotAllowed);
        assertEq(results, expected, "lane 2 skipped");
        assertEq(total, 7 * AMOUNT, "seven lanes paid");
        assertEq(_seqOf(_channelId(cs[2])), 0, "lane 2's channel untouched");
    }

    function test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane() public {
        ChannelConfig[] memory cs = new ChannelConfig[](8);
        for (uint256 i = 0; i < 8; i++) {
            cs[i] = _config(payers[i], bytes32(i));
        }
        cs[1].payTo = stranger; // another provider
        cs[2].verifierSetHash = bytes32("another set");
        for (uint256 i = 0; i < 8; i++) {
            if (i != 3) _open(cs[i], payerKeys[i], DEPOSIT); // lane 3's channel is never opened
        }

        // First batch, lane 7 padding: settled, other provider, not allowed, not open, wrong seq.
        bytes memory frames;
        for (uint256 i = 0; i < 7; i++) {
            frames = bytes.concat(frames, i == 4 ? _k8Frame(cs, 4, 2) : _k8Frame(cs, i, 1));
        }
        vm.recordLogs();
        settlement.settleBatch(k8PaddedEntry, set, K8_PADDED_INDEX, cs, frames, k8Commitments, k8Outputs, k8Proof);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 total, bytes memory results) = _resultsIn(logs);

        bytes memory expected = abi.encodePacked(
            _code(ChannelSettlement.LaneResult.Settled),
            _code(ChannelSettlement.LaneResult.OtherProvider),
            _code(ChannelSettlement.LaneResult.VerifierNotAllowed),
            _code(ChannelSettlement.LaneResult.ChannelNotOpen),
            _code(ChannelSettlement.LaneResult.WrongSeq),
            _code(ChannelSettlement.LaneResult.Settled),
            _code(ChannelSettlement.LaneResult.Settled),
            _code(ChannelSettlement.LaneResult.Padding)
        );
        assertEq(results, expected, "first batch, lane by lane");
        assertEq(total, 3 * AMOUNT, "three lanes paid");
        assertEq(_frameLogs(logs, _channelId(cs[0])), 1, "frame log for lane 0");
        assertEq(_frameLogs(logs, _channelId(cs[1])), 0, "no frame log for a skipped lane");

        // Second batch: expired, beyond the window, above the balance, bad signature.
        bytes memory frames2;
        for (uint256 i = 0; i < 8; i++) {
            bytes memory f;
            bytes32 id = _channelId(cs[i]);
            if (i == 0) {
                f = _k8Frame(cs, 0, 2);
            } else if (i == 4) {
                uint256 past = block.timestamp - 1;
                f = _frame(4, 1, AMOUNT, past, _voucher(payerKeys[4], id, 1, AMOUNT, AMOUNT, k8Commitments[4], past));
            } else if (i == 5) {
                uint256 far = block.timestamp + PROVE_WINDOW + 1;
                f = _frame(5, 2, AMOUNT, far, _voucher(payerKeys[5], id, 2, AMOUNT, 2 * AMOUNT, k8Commitments[5], far));
            } else if (i == 6) {
                uint256 a = DEPOSIT;
                f = _frame(6, 2, a, PROVE_BY, _voucher(payerKeys[6], id, 2, a, AMOUNT + a, k8Commitments[6], PROVE_BY));
            } else if (i == 7) {
                f = _frame(
                    7, 1, AMOUNT, PROVE_BY, _voucher(walletOwnerKey, id, 1, AMOUNT, AMOUNT, k8Commitments[7], PROVE_BY)
                );
            } else {
                f = _frame(i, 9, AMOUNT, PROVE_BY, ""); // lanes 1-3 fail before seq or signature are read
            }
            frames2 = bytes.concat(frames2, f);
        }
        (total, results) = _settleK8Recorded(cs, frames2);
        expected = abi.encodePacked(
            _code(ChannelSettlement.LaneResult.Settled),
            _code(ChannelSettlement.LaneResult.OtherProvider),
            _code(ChannelSettlement.LaneResult.VerifierNotAllowed),
            _code(ChannelSettlement.LaneResult.ChannelNotOpen),
            _code(ChannelSettlement.LaneResult.Expired),
            _code(ChannelSettlement.LaneResult.BeyondProveWindow),
            _code(ChannelSettlement.LaneResult.InsufficientBalance),
            _code(ChannelSettlement.LaneResult.BadSignature)
        );
        assertEq(results, expected, "second batch, lane by lane");
        assertEq(total, AMOUNT, "one lane paid");
        assertEq(settlement.accrued(provider, address(token)), 4 * AMOUNT, "accrued over both batches");
    }

    function test_an_erc1271_payer_voucher_is_accepted() public {
        (ChannelConfig[] memory cs, bytes memory frame) = _soloChannelOf(address(wallet), walletOwnerKey, "wallet");
        _settleSolo(cs, frame);
        assertEq(_seqOf(_channelId(cs[0])), 1, "settled");
        assertEq(settlement.accrued(provider, address(token)), AMOUNT, "accrued");
    }

    function test_an_erc1271_payer_refuses_a_wrong_signature() public {
        (ChannelConfig[] memory cs, bytes memory frame) = _soloChannelOf(address(wallet), walletOwnerKey, "wallet");
        bytes memory expected = abi.encodePacked(_code(ChannelSettlement.LaneResult.BadSignature));

        // Signed by someone who is not the wallet's owner.
        bytes32 id = _channelId(cs[0]);
        bytes memory byStranger =
            _frame(0, 1, AMOUNT, PROVE_BY, _voucher(payerKeys[1], id, 1, AMOUNT, AMOUNT, soloCommitments[0], PROVE_BY));
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.NothingSettled.selector, expected));
        _settleSolo(cs, byStranger);

        // The owner's signature, but the wallet now says no.
        wallet.setAccepting(false);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.NothingSettled.selector, expected));
        _settleSolo(cs, frame);
    }

    // ── New: vouchers ───────────────────────────────────────────────────────────────────────────

    function test_a_single_channel_batch_settles_eight_vouchers_in_order() public {
        ChannelConfig[] memory cs = new ChannelConfig[](1);
        cs[0] = _config(payers[0], "single");
        bytes32 id = _open(cs[0], payerKeys[0], DEPOSIT);
        vm.recordLogs();
        settlement.settleBatch(
            k8Entry, set, K8_INDEX, cs, _singleChannelFrames(cs[0], 0), k8Commitments, k8Outputs, k8Proof
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 total, bytes memory results) = _resultsIn(logs);

        assertEq(results, _results(8), "every lane settled");
        assertEq(total, 8 * AMOUNT, "total");
        assertEq(_frameLogs(logs, id), 8, "eight frame logs");
        (uint256 balance, uint256 accounted, uint256 seq,) = settlement.channel(id);
        assertEq(balance, DEPOSIT - 8 * AMOUNT, "balance");
        assertEq(accounted, 8 * AMOUNT, "accounted");
        assertEq(seq, 8, "seq");
    }

    function test_vouchers_of_one_channel_settle_only_in_sequence() public {
        ChannelConfig[] memory cs = new ChannelConfig[](1);
        cs[0] = _config(payers[0], "order");
        _open(cs[0], payerKeys[0], DEPOSIT);
        // Lane 0 carries voucher 2 and lane 1 voucher 1; the rest follow on from 3.
        bytes memory frames = bytes.concat(_singleChannelLane(cs[0], 0, 2), _singleChannelLane(cs[0], 1, 1));
        for (uint256 i = 2; i < 8; i++) {
            frames = bytes.concat(frames, _singleChannelLane(cs[0], i, i + 1));
        }
        (, bytes memory results) = _settleK8Recorded(cs, frames);

        bytes memory expected = new bytes(8);
        for (uint256 i = 0; i < 8; i++) {
            if (i != 1) expected[i] = _code(ChannelSettlement.LaneResult.WrongSeq);
        }
        assertEq(results, expected, "only voucher 1 settles; 2 was not next when its lane came");
        assertEq(_seqOf(_channelId(cs[0])), 1, "seq");
    }

    function test_the_cumulative_amount_must_continue_from_the_accounted_total() public {
        (ChannelConfig[] memory cs,) = _soloChannel(payers[0], payerKeys[0], "cum");
        bytes32 id = _channelId(cs[0]);
        // Voucher 1 claiming that an earlier amount was already accounted.
        bytes memory frame = _frame(
            0, 1, AMOUNT, PROVE_BY, _voucher(payerKeys[0], id, 1, AMOUNT, 2 * AMOUNT, soloCommitments[0], PROVE_BY)
        );
        bytes memory expected = abi.encodePacked(_code(ChannelSettlement.LaneResult.BadSignature));
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.NothingSettled.selector, expected));
        _settleSolo(cs, frame);
    }

    function test_prove_by_is_inclusive_and_bounded_by_the_channels_window() public {
        ChannelConfig[] memory cs = _openEight("window");
        uint256[8] memory proveBys = [
            block.timestamp, // the last second: settles
            block.timestamp + PROVE_WINDOW, // the window's edge: settles
            block.timestamp + PROVE_WINDOW + 1, // one second beyond
            block.timestamp - 1, // one second late
            PROVE_BY,
            PROVE_BY,
            PROVE_BY,
            PROVE_BY
        ];
        bytes memory frames;
        for (uint256 i = 0; i < 8; i++) {
            bytes memory sig =
                _voucher(payerKeys[i], _channelId(cs[i]), 1, AMOUNT, AMOUNT, k8Commitments[i], proveBys[i]);
            frames = bytes.concat(frames, _frame(i, 1, AMOUNT, proveBys[i], sig));
        }
        (, bytes memory results) = _settleK8Recorded(cs, frames);

        bytes memory expected = _results(8);
        expected[2] = _code(ChannelSettlement.LaneResult.BeyondProveWindow);
        expected[3] = _code(ChannelSettlement.LaneResult.Expired);
        assertEq(results, expected, "boundaries");
    }

    function test_a_voucher_signed_for_another_chain_or_contract_is_skipped() public {
        (ChannelConfig[] memory cs,) = _soloChannel(payers[0], payerKeys[0], "domain");
        bytes32 id = _channelId(cs[0]);
        bytes memory expected = abi.encodePacked(_code(ChannelSettlement.LaneResult.BadSignature));

        bytes32[2] memory domains =
            [_domainAt(block.chainid + 1, address(settlement)), _domainAt(block.chainid, address(registry))];
        for (uint256 i = 0; i < 2; i++) {
            bytes32 digest = _voucherDigestAt(domains[i], id, 1, AMOUNT, AMOUNT, soloCommitments[0], PROVE_BY);
            bytes memory frame = _frame(0, 1, AMOUNT, PROVE_BY, _sign(payerKeys[0], digest));
            vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.NothingSettled.selector, expected));
            _settleSolo(cs, frame);
        }
    }

    function test_the_same_proof_settles_later_vouchers_that_name_the_same_commitments() public {
        ChannelConfig[] memory cs = _openEight("again");
        _settleK8(cs, _k8Frames(cs, 1));
        (uint256 total, bytes memory results) = _settleK8Recorded(cs, _k8Frames(cs, 2));
        assertEq(results, _results(8), "by design: the proof is not bound to a voucher");
        assertEq(total, 8 * AMOUNT, "second vouchers paid");
    }

    // ── New: opening ────────────────────────────────────────────────────────────────────────────

    function test_open_refuses_windows_below_the_minimums() public {
        ChannelConfig memory c = _config(payers[0], "w");
        c.proveWindow = settlement.MIN_PROVE_WINDOW() - 1;
        bytes memory sig = _authorize(payerKeys[0], c.payer, DEPOSIT, _channelId(c));
        vm.expectRevert(ChannelSettlement.WindowTooShort.selector);
        settlement.openChannel(c, DEPOSIT, VALID_BEFORE, sig);

        c.proveWindow = settlement.MIN_PROVE_WINDOW();
        c.challengeWindow = settlement.MIN_CHALLENGE_WINDOW() - 1;
        sig = _authorize(payerKeys[0], c.payer, DEPOSIT, _channelId(c));
        vm.expectRevert(ChannelSettlement.WindowTooShort.selector);
        settlement.openChannel(c, DEPOSIT, VALID_BEFORE, sig);

        c.challengeWindow = settlement.MIN_CHALLENGE_WINDOW();
        _open(c, payerKeys[0], DEPOSIT);
        assertEq(_balanceOf(_channelId(c)), DEPOSIT, "the minimums themselves are accepted");
    }

    function test_open_refuses_a_zero_or_oversized_deposit_and_a_zero_provider() public {
        ChannelConfig memory c = _config(payers[0], "d");
        bytes32 id = _channelId(c);
        uint256 tooBig = uint256(type(uint96).max) + 1;

        vm.expectRevert(ChannelSettlement.BadDeposit.selector);
        settlement.openChannel(c, 0, VALID_BEFORE, _authorize(payerKeys[0], c.payer, 0, id));
        vm.expectRevert(ChannelSettlement.BadDeposit.selector);
        settlement.openChannel(c, tooBig, VALID_BEFORE, _authorize(payerKeys[0], c.payer, tooBig, id));

        c.payTo = address(0);
        bytes memory sig = _authorize(payerKeys[0], c.payer, DEPOSIT, _channelId(c));
        vm.expectRevert(ChannelSettlement.ZeroPayTo.selector);
        settlement.openChannel(c, DEPOSIT, VALID_BEFORE, sig);
    }

    function test_the_deposit_authorization_binds_the_config_the_chain_and_the_contract() public {
        ChannelConfig memory c = _config(payers[0], "bind");
        ChannelConfig memory changed = _config(payers[0], "bind");
        changed.proveWindow = PROVE_WINDOW + 1;

        bytes32[3] memory wrongIds = [
            _channelIdAt(block.chainid + 1, address(settlement), c),
            _channelIdAt(block.chainid, address(registry), c),
            _channelId(changed)
        ];
        for (uint256 i = 0; i < 3; i++) {
            bytes memory wrong = _authorize(payerKeys[0], c.payer, DEPOSIT, wrongIds[i]);
            vm.expectRevert(bytes("invalid signature"));
            settlement.openChannel(c, DEPOSIT, VALID_BEFORE, wrong);
        }

        // The authorization for this config does not open the changed one, and does open its own.
        bytes memory sig = _authorize(payerKeys[0], c.payer, DEPOSIT, _channelId(c));
        vm.expectRevert(bytes("invalid signature"));
        settlement.openChannel(changed, DEPOSIT, VALID_BEFORE, sig);
        settlement.openChannel(c, DEPOSIT, VALID_BEFORE, sig);
        assertEq(_balanceOf(_channelId(c)), DEPOSIT, "opened with its own authorization");
    }

    function test_an_erc1271_payer_opens_through_the_token_and_a_refusing_wallet_cannot() public {
        ChannelConfig memory c = _config(address(wallet), "w");
        bytes32 id = _channelId(c);
        bytes memory sig = _authorize(walletOwnerKey, c.payer, DEPOSIT, id);
        wallet.setAccepting(false);
        vm.expectRevert(bytes("invalid signature"));
        settlement.openChannel(c, DEPOSIT, VALID_BEFORE, sig);

        wallet.setAccepting(true);
        settlement.openChannel(c, DEPOSIT, VALID_BEFORE, sig);
        assertEq(_balanceOf(id), DEPOSIT, "opened");
    }

    // ── New: the batch call ─────────────────────────────────────────────────────────────────────

    function test_a_set_index_outside_the_set_reverts() public {
        ChannelConfig[] memory cs = _openEight("idx");
        bytes memory frames = _k8Frames(cs, 1);
        vm.expectRevert(ChannelSettlement.VerifierNotInSet.selector);
        settlement.settleBatch(k8Entry, set, set.length, cs, frames, k8Commitments, k8Outputs, k8Proof);
    }

    function test_an_entry_that_is_not_the_named_verifiers_reverts() public {
        ChannelConfig[] memory cs = _openEight("entry");
        bytes memory frames = _k8Frames(cs, 1);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.VerifierUnavailable.selector, k8Id));
        settlement.settleBatch(k8PaddedEntry, set, K8_INDEX, cs, frames, k8Commitments, k8Outputs, k8Proof);
    }

    function test_frames_that_do_not_parse_revert() public {
        ChannelConfig[] memory cs = _openEight("parse");
        bytes memory frames = _k8Frames(cs, 1);
        uint256 n = frames.length;

        bytes[4] memory bad;
        bad[0] = _slice(frames, n - 27 - 65 + 20); // the last frame's header cut short
        bad[1] = _slice(frames, n - 1); // the last signature cut short
        bad[2] = bytes.concat(frames, hex"00"); // a byte left over
        bad[3] = bytes.concat(_slice(frames, n - 92), _frame(8, 1, AMOUNT, PROVE_BY, "")); // channel index 8 of 8
        for (uint256 i = 0; i < 4; i++) {
            vm.expectRevert(ChannelSettlement.MalformedFrames.selector);
            _settleK8(cs, bad[i]);
        }
        vm.expectRevert(ChannelSettlement.MalformedFrames.selector);
        _settleK8(new ChannelConfig[](0), frames);
    }

    function test_too_little_gas_for_the_verifier_is_a_typed_error() public {
        ChannelConfig[] memory cs = _openEight("gas");
        bytes memory frames = _k8Frames(cs, 1);
        vm.expectPartialRevert(ProofCheck.InsufficientGasForVerifier.selector);
        settlement.settleBatch{gas: 600_000}(k8Entry, set, K8_INDEX, cs, frames, k8Commitments, k8Outputs, k8Proof);
    }

    function test_a_settled_lane_writes_only_its_channel_slot_and_the_batch_one_accrual() public {
        ChannelConfig[] memory cs = _openEight("slots");
        bytes memory frames = _k8Frames(cs, 1);
        vm.record();
        _settleK8(cs, frames);
        (, bytes32[] memory writes) = vm.accesses(address(settlement));
        assertEq(writes.length, 9, "eight channel slots and one accrual");
    }

    function test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain() public {
        (ChannelConfig[] memory cs,) = _soloChannel(payers[0], payerKeys[0], "here");
        bytes32 idHere = _channelId(cs[0]);
        uint256 other = block.chainid + 1;
        vm.chainId(other);

        // The same config names another id there, and no channel has it.
        bytes32 idThere = _channelIdAt(other, address(settlement), cs[0]);
        assertTrue(idThere != idHere, "the id binds the chain");
        bytes32 digest = _voucherDigestAt(
            _domainAt(other, address(settlement)), idThere, 1, AMOUNT, AMOUNT, soloCommitments[0], PROVE_BY
        );
        bytes memory expected = abi.encodePacked(_code(ChannelSettlement.LaneResult.ChannelNotOpen));
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.NothingSettled.selector, expected));
        _settleSolo(cs, _frame(0, 1, AMOUNT, PROVE_BY, _sign(payerKeys[0], digest)));

        // A channel opened there settles a voucher signed in that chain's domain.
        (ChannelConfig[] memory there, bytes memory frame) = _soloChannel(payers[0], payerKeys[0], "there");
        _settleSolo(there, frame);
        assertEq(_seqOf(_channelId(there[0])), 1, "settled on the other chain");
    }

    function test_a_zero_commitment_is_not_padding_when_the_entry_declares_none() public {
        VerifierEntry memory e =
            _entry(address(new AlwaysTrueAdapter()), address(0), 1, OUTPUT_SIZE, SOLO_VERIFY_GAS, SOLO_VK_HASH);
        bytes32[] memory s = new bytes32[](1);
        s[0] = registry.register(e);
        ChannelConfig[] memory cs = new ChannelConfig[](1);
        cs[0] = _config(payers[0], "zero");
        cs[0].verifierSetHash = keccak256(abi.encodePacked(s));
        bytes32 id = _open(cs[0], payerKeys[0], DEPOSIT);

        bytes32[] memory zero = new bytes32[](1);
        bytes memory frame =
            _frame(0, 1, AMOUNT, PROVE_BY, _voucher(payerKeys[0], id, 1, AMOUNT, AMOUNT, bytes32(0), PROVE_BY));
        vm.recordLogs();
        settlement.settleBatch(e, s, 0, cs, frame, zero, new bytes(OUTPUT_SIZE), "");
        (uint256 total, bytes memory results) = _batchSettled();
        assertEq(results, _results(1), "settled, not padding");
        assertEq(total, AMOUNT, "paid");
    }

    // ── New: views ──────────────────────────────────────────────────────────────────────────────

    function test_views_agree_with_what_a_client_computes() public view {
        ChannelConfig memory c = _config(payers[0], "views");
        bytes32 id = _channelId(c);
        bytes32 domain = _domainAt(block.chainid, address(settlement));
        assertEq(settlement.channelId(c), id, "channel id");
        assertEq(settlement.DOMAIN_SEPARATOR(), domain, "domain");
        assertEq(settlement.verifierSetHash(set), setHash, "set hash");
        assertEq(
            settlement.voucherDigest(id, 3, 5, 15, bytes32("c"), 77),
            _voucherDigestAt(domain, id, 3, 5, 15, bytes32("c"), 77),
            "voucher digest"
        );
    }

    // ── New: withdrawing ────────────────────────────────────────────────────────────────────────

    function test_the_provider_withdraws_what_accrued_and_no_more() public {
        ChannelConfig[] memory cs = _openEight("withdraw");
        _settleK8(cs, _k8Frames(cs, 1));

        vm.prank(provider);
        settlement.withdraw(address(token), 3 * AMOUNT);
        assertEq(token.balanceOf(provider), 3 * AMOUNT, "paid");
        assertEq(settlement.accrued(provider, address(token)), 5 * AMOUNT, "rest accrued");
        assertEq(token.balanceOf(address(settlement)), 8 * DEPOSIT - 3 * AMOUNT, "contract holds balances + accrued");

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.AmountUnavailable.selector, 5 * AMOUNT));
        settlement.withdraw(address(token), 5 * AMOUNT + 1);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.AmountUnavailable.selector, 5 * AMOUNT));
        settlement.withdraw(address(token), 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.AmountUnavailable.selector, 0));
        settlement.withdraw(address(token), 1);
    }

    function test_withdraw_reverts_when_the_token_reports_failure() public {
        FalseReturningERC3009 f = new FalseReturningERC3009();
        uint256 accruedBefore = _accrueIn(address(f), provider);
        vm.prank(provider);
        vm.expectRevert(ChannelSettlement.TransferFailed.selector);
        settlement.withdraw(address(f), AMOUNT);
        assertEq(settlement.accrued(provider, address(f)), accruedBefore, "still accrued");
    }

    function test_a_reentering_token_cannot_withdraw_twice() public {
        // The token is also the provider, so the call it makes from inside `transfer` is a
        // withdrawal of the same accrued amount.
        ReentrantERC3009 rt = new ReentrantERC3009();
        _accrueIn(address(rt), address(rt));
        rt.arm(address(settlement), abi.encodeCall(ChannelSettlement.withdraw, (address(rt), AMOUNT)));
        vm.prank(address(rt));
        settlement.withdraw(address(rt), AMOUNT);

        assertTrue(rt.reentered(), "re-entered");
        assertFalse(rt.innerCallSucceeded(), "the inner withdrawal failed");
        assertEq(rt.balanceOf(address(rt)), AMOUNT, "paid once");
        assertEq(rt.balanceOf(address(settlement)), DEPOSIT - AMOUNT, "the channel's balance is intact");
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────────────────────

    /// A channel of `payer` with its first voucher for the solo proof's commitment.
    function _soloChannelOf(address payer, uint256 key, bytes32 salt)
        internal
        returns (ChannelConfig[] memory cs, bytes memory frame)
    {
        cs = new ChannelConfig[](1);
        cs[0] = _config(payer, salt);
        bytes32 id = _channelId(cs[0]);
        bytes memory auth = _authorize(key, payer, DEPOSIT, id);
        settlement.openChannel(cs[0], DEPOSIT, VALID_BEFORE, auth);
        frame = _frame(0, 1, AMOUNT, PROVE_BY, _voucher(key, id, 1, AMOUNT, AMOUNT, soloCommitments[0], PROVE_BY));
    }

    function _soloChannel(address payer, uint256 key, bytes32 salt)
        internal
        returns (ChannelConfig[] memory, bytes memory)
    {
        return _soloChannelOf(payer, key, salt);
    }

    function _settleSolo(ChannelConfig[] memory cs, bytes memory frame) internal {
        settlement.settleBatch(soloEntry, set, SOLO_INDEX, cs, frame, soloCommitments, soloOutput, soloProof);
    }

    function _resultsIn(Vm.Log[] memory logs) internal pure returns (uint256 total, bytes memory results) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == ChannelSettlement.BatchSettled.selector) {
                (, total, results) = abi.decode(logs[i].data, (address, uint256, bytes));
            }
        }
    }

    /// Open a channel in `asset` paying `payTo`, settle one solo voucher; returns the accrual.
    function _accrueIn(address asset, address payTo) internal returns (uint256) {
        (bool ok,) = asset.call(abi.encodeWithSignature("mint(address,uint256)", payers[0], DEPOSIT));
        assertTrue(ok, "mint");
        ChannelConfig[] memory cs = new ChannelConfig[](1);
        cs[0] = _config(payers[0], "asset");
        cs[0].asset = asset;
        cs[0].payTo = payTo;
        bytes32 id = _channelId(cs[0]);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                FalseReturningERC3009(asset).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(RECEIVE_TYPEHASH, payers[0], address(settlement), DEPOSIT, uint256(0), VALID_BEFORE, id)
                )
            )
        );
        settlement.openChannel(cs[0], DEPOSIT, VALID_BEFORE, _sign(payerKeys[0], digest));
        bytes memory frame =
            _frame(0, 1, AMOUNT, PROVE_BY, _voucher(payerKeys[0], id, 1, AMOUNT, AMOUNT, soloCommitments[0], PROVE_BY));
        _settleSolo(cs, frame);
        return settlement.accrued(payTo, asset);
    }

    function _slice(bytes memory data, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = data[i];
        }
    }
}
