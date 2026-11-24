// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChannelSettlementBase} from "./ChannelSettlementBase.sol";
import {AcceptAllTarget} from "./mocks/Mocks.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";
import {ChannelSettlement, ChannelConfig} from "../src/ChannelSettlement.sol";

/// Shared setup for the close tests. On top of `ChannelSettlementBase`, two registered entries whose
/// target accepts every proof, behind the real EZKL adapter: one lane (`mock1`) and four lanes with
/// a padding value (`mock4`). With them a test chooses its own commitments, so it can settle any
/// voucher of any channel without a stored proof. Every channel's verifier set is
/// [solo, K=8, K=8 with padding, mock1, mock4], so the stored proofs settle here too.
abstract contract ChannelCloseBase is ChannelSettlementBase {
    uint256 internal constant MOCK1_INDEX = 3;
    uint256 internal constant MOCK4_INDEX = 4;
    uint32 internal constant MOCK_VERIFY_GAS = 400_000;
    bytes32 internal constant PAD = bytes32(uint256(0xE0)); // mock4's padding value

    VerifierEntry internal mock1;
    VerifierEntry internal mock4;

    function setUp() public virtual override {
        super.setUp();
        address acceptAll = address(new AcceptAllTarget());
        mock1 = _entry(address(adapter), acceptAll, 1, OUTPUT_SIZE, MOCK_VERIFY_GAS, keccak256("mock1"));
        mock4 = _entry(address(adapter), acceptAll, 4, OUTPUT_SIZE, MOCK_VERIFY_GAS, keccak256("mock4"));
        mock4.emptyLane = PAD;
        bytes32 id1 = registry.register(mock1);
        bytes32 id4 = registry.register(mock4);
        bytes32[] memory s = new bytes32[](5);
        (s[0], s[1], s[2], s[3], s[4]) = (set[0], set[1], set[2], id1, id4);
        set = s;
        setHash = keccak256(abi.encodePacked(s));
    }

    // ── Settling with the accept-everything entries ─────────────────────────────────────────────

    /// One lane of a mock batch: voucher `v` of `cs[index]`, signed with `key`.
    struct Lane {
        uint256 index;
        uint256 key;
        ChannelSettlement.Voucher v;
    }

    function _lane(uint256 index, uint256 key, ChannelSettlement.Voucher memory v) internal pure returns (Lane memory) {
        return Lane(index, key, v);
    }

    /// Settle `lanes` (one or up to four; four-lane batches are padded) against `cs`.
    function _mockSettleCall(ChannelConfig[] memory cs, Lane[] memory lanes) internal view returns (bytes memory) {
        bool one = lanes.length == 1;
        uint256 k = one ? 1 : 4;
        bytes32[] memory commitments = new bytes32[](k);
        bytes memory frames;
        for (uint256 i = 0; i < k; i++) {
            if (i >= lanes.length) {
                commitments[i] = PAD;
                continue;
            }
            Lane memory l = lanes[i];
            commitments[i] = l.v.inputCommitment;
            bytes memory sig = _signV(l.key, _channelId(cs[l.index]), l.v);
            frames = bytes.concat(frames, _frame(l.index, l.v.seq, l.v.amount, l.v.proveBy, sig));
        }
        return abi.encodeCall(
            ChannelSettlement.settleBatch,
            (
                one ? mock1 : mock4,
                set,
                one ? MOCK1_INDEX : MOCK4_INDEX,
                cs,
                frames,
                commitments,
                new bytes(k * OUTPUT_SIZE),
                ""
            )
        );
    }

    function _mockSettle(ChannelConfig[] memory cs, Lane[] memory lanes) internal {
        (bool ok, bytes memory ret) = address(settlement).call(_mockSettleCall(cs, lanes));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// Settle voucher `v` of channel `c` alone, with `mock1`.
    function _settleOne(ChannelConfig memory c, uint256 key, ChannelSettlement.Voucher memory v) internal {
        ChannelConfig[] memory cs = new ChannelConfig[](1);
        cs[0] = c;
        Lane[] memory lanes = new Lane[](1);
        lanes[0] = _lane(0, key, v);
        _mockSettle(cs, lanes);
    }

    /// Settle vouchers `from..to` of `c` (the standard shape), up to three per batch.
    function _settleRange(ChannelConfig memory c, uint256 key, uint256 from, uint256 to, string memory tag) internal {
        ChannelConfig[] memory cs = new ChannelConfig[](1);
        cs[0] = c;
        for (uint256 seq = from; seq <= to; seq += 3) {
            uint256 n = to - seq + 1 < 3 ? to - seq + 1 : 3;
            Lane[] memory lanes = new Lane[](n);
            for (uint256 i = 0; i < n; i++) {
                lanes[i] = _lane(0, key, _std(seq + i, tag));
            }
            _mockSettle(cs, lanes);
        }
    }

    function _one(ChannelConfig memory c) internal pure returns (ChannelConfig[] memory cs) {
        cs = new ChannelConfig[](1);
        cs[0] = c;
    }

    function _lanes1(Lane memory a) internal pure returns (Lane[] memory l) {
        l = new Lane[](1);
        l[0] = a;
    }

    function _lanes2(Lane memory a, Lane memory b) internal pure returns (Lane[] memory l) {
        l = new Lane[](2);
        (l[0], l[1]) = (a, b);
    }

    // ── Closing ─────────────────────────────────────────────────────────────────────────────────

    function _stateOf(bytes32 id) internal view returns (ChannelSettlement.State state) {
        (,,, state) = settlement.channel(id);
    }

    function _accountedOf(bytes32 id) internal view returns (uint256 accounted) {
        (, accounted,,) = settlement.channel(id);
    }

    function _closingAt(bytes32 id) internal view returns (uint256 closingAt) {
        (closingAt,,,) = settlement.closeState(id);
    }

    function _holdExpiry(bytes32 id) internal view returns (uint256 holdExpiry) {
        (,, holdExpiry,) = settlement.closeState(id);
    }

    function _held(bytes32 id) internal view returns (uint256 held) {
        (,,, held) = settlement.closeState(id);
    }

    function _assertState(bytes32 id, ChannelSettlement.State expected) internal view {
        assertEq(uint8(_stateOf(id)), uint8(expected), "state");
    }

    function _wrongState(ChannelSettlement.State s) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ChannelSettlement.WrongState.selector, s);
    }

    function _refused(ChannelSettlement.LaneResult r) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ChannelSettlement.VoucherRefused.selector, r);
    }

    function _nothingSettled(bytes memory results) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ChannelSettlement.NothingSettled.selector, results);
    }
}
