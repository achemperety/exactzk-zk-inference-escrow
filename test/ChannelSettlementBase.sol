// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {ProofCoreBase} from "./ProofCoreBase.sol";
import {FixturesK8} from "./fixtures/FixturesK8.sol";
import {MockERC3009, MockSmartWallet} from "./mocks/MockERC3009.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";
import {ChannelSettlement, ChannelConfig} from "../src/ChannelSettlement.sol";

/// Shared setup for the channel tests: the proof-system core from `ProofCoreBase`, a test token,
/// the channel contract, eight EOA payers (one per lane of the K=8 proof), a smart-wallet payer,
/// and a third registered entry: the K=8 circuit with lane 7's commitment declared as its padding
/// value, so that lane 7 of the stored proof reads as padding.
///
/// Every channel accepts the set [solo, K=8, K=8 with padding] unless a test says otherwise.
abstract contract ChannelSettlementBase is ProofCoreBase {
    uint256 internal constant T0 = 1_750_000_000;
    uint256 internal constant AMOUNT = 1_000_000; // 1 USDC per request
    uint256 internal constant DEPOSIT = 50_000_000;
    uint40 internal constant PROVE_WINDOW = 3600;
    uint40 internal constant CHALLENGE_WINDOW = 600;
    uint256 internal constant PROVE_BY = T0 + 1800;
    uint256 internal constant VALID_BEFORE = T0 + 7200;

    // Index of each entry in `set`.
    uint256 internal constant SOLO_INDEX = 0;
    uint256 internal constant K8_INDEX = 1;
    uint256 internal constant K8_PADDED_INDEX = 2;

    bytes32 internal constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant CHANNEL_TYPEHASH = keccak256(
        "ProofGatedChannel(uint256 chainId,address settlement,address payer,address payTo,address asset,"
        "bytes32 verifierSetHash,uint40 proveWindow,uint40 challengeWindow,bytes32 salt)"
    );
    bytes32 internal constant VOUCHER_TYPEHASH = keccak256(
        "Voucher(bytes32 channelId,uint48 seq,uint96 amount,uint96 cumAmount,bytes32 inputCommitment,uint40 proveBy)"
    );

    MockERC3009 internal token;
    ChannelSettlement internal settlement;
    bytes32 internal tokenDomain;

    address[8] internal payers;
    uint256[8] internal payerKeys;
    address internal provider = makeAddr("provider");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");

    MockSmartWallet internal wallet;
    uint256 internal walletOwnerKey;

    VerifierEntry internal k8PaddedEntry;
    bytes32 internal k8PaddedId;
    bytes32[] internal set;
    bytes32 internal setHash;

    // The stored K=8 proof, split for the adapter.
    bytes32[] internal k8Commitments;
    bytes internal k8Outputs;
    bytes internal k8Proof;

    // The stored solo proof.
    bytes32[] internal soloCommitments;
    bytes internal soloOutput;
    bytes internal soloProof;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(T0);

        token = new MockERC3009();
        settlement = new ChannelSettlement(registry);
        tokenDomain = token.DOMAIN_SEPARATOR();

        for (uint256 i = 0; i < 8; i++) {
            (payers[i], payerKeys[i]) = makeAddrAndKey(string.concat("payer", vm.toString(i)));
            token.mint(payers[i], 2 * DEPOSIT);
        }
        address walletOwner;
        (walletOwner, walletOwnerKey) = makeAddrAndKey("wallet owner");
        wallet = new MockSmartWallet(walletOwner);
        token.mint(address(wallet), 2 * DEPOSIT);

        k8PaddedEntry = k8Entry;
        k8PaddedEntry.emptyLane = bytes32(FixturesK8.LANE7_COMMITMENT);
        k8PaddedId = registry.register(k8PaddedEntry);

        set = new bytes32[](3);
        (set[SOLO_INDEX], set[K8_INDEX], set[K8_PADDED_INDEX]) = (soloId, k8Id, k8PaddedId);
        setHash = keccak256(abi.encodePacked(set));

        (k8Commitments, k8Outputs, k8Proof) = _k8();
        (soloCommitments, soloOutput, soloProof) = _solo();
    }

    // ── Channels ────────────────────────────────────────────────────────────────────────────────

    function _config(address payer, bytes32 salt) internal view virtual returns (ChannelConfig memory) {
        return ChannelConfig({
            payer: payer,
            payTo: provider,
            asset: address(token),
            verifierSetHash: setHash,
            proveWindow: PROVE_WINDOW,
            challengeWindow: CHALLENGE_WINDOW,
            salt: salt
        });
    }

    /// Channel id as a client computes it, for any chain id and settlement address.
    function _channelIdAt(uint256 chainId, address at, ChannelConfig memory c) internal pure returns (bytes32) {
        return keccak256(abi.encode(CHANNEL_TYPEHASH, chainId, at, c));
    }

    function _channelId(ChannelConfig memory c) internal view returns (bytes32) {
        return _channelIdAt(block.chainid, address(settlement), c);
    }

    /// ERC-3009 ReceiveWithAuthorization signature by `key` for `from`, paying the settlement.
    function _authorize(uint256 key, address from, uint256 value, bytes32 nonce) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                tokenDomain,
                keccak256(
                    abi.encode(RECEIVE_TYPEHASH, from, address(settlement), value, uint256(0), VALID_BEFORE, nonce)
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Open `c` with `deposit`, authorised by `key`, submitted by a relayer.
    function _open(ChannelConfig memory c, uint256 key, uint256 deposit) internal returns (bytes32 id) {
        bytes memory sig = _authorize(key, c.payer, deposit, _channelId(c));
        vm.prank(relayer);
        id = settlement.openChannel(c, deposit, VALID_BEFORE, sig);
    }

    /// Eight channels, one per payer, each with `DEPOSIT`.
    function _openEight(bytes32 saltBase) internal returns (ChannelConfig[] memory cs) {
        cs = new ChannelConfig[](8);
        for (uint256 i = 0; i < 8; i++) {
            cs[i] = _config(payers[i], bytes32(uint256(saltBase) + i));
            _open(cs[i], payerKeys[i], DEPOSIT);
        }
    }

    function _balanceOf(bytes32 id) internal view returns (uint256 balance) {
        (balance,,,) = settlement.channel(id);
    }

    function _seqOf(bytes32 id) internal view returns (uint256 seq) {
        (,, seq,) = settlement.channel(id);
    }

    // ── Vouchers and frames ─────────────────────────────────────────────────────────────────────

    /// The voucher domain as a client computes it, for any chain id and settlement address.
    function _domainAt(uint256 chainId, address at) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ChannelSettlement"),
                keccak256("1"),
                chainId,
                at
            )
        );
    }

    function _voucherDigestAt(
        bytes32 domain,
        bytes32 id,
        uint256 seq,
        uint256 amount,
        uint256 cumAmount,
        bytes32 commitment,
        uint256 proveBy
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(VOUCHER_TYPEHASH, id, seq, amount, cumAmount, commitment, proveBy));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// The payer's signature on a voucher of channel `id`, in this settlement's domain.
    function _voucher(
        uint256 key,
        bytes32 id,
        uint256 seq,
        uint256 amount,
        uint256 cumAmount,
        bytes32 commitment,
        uint256 proveBy
    ) internal view returns (bytes memory) {
        bytes32 domain = _domainAt(block.chainid, address(settlement));
        return _sign(key, _voucherDigestAt(domain, id, seq, amount, cumAmount, commitment, proveBy));
    }

    function _frame(uint256 index, uint256 seq, uint256 amount, uint256 proveBy, bytes memory sig)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(uint16(index), uint48(seq), uint96(amount), uint40(proveBy), uint16(sig.length), sig);
    }

    /// Lane `i` of the K=8 proof against channel `cs[i]`: the `seq`-th voucher of `AMOUNT`, signed
    /// by payer `i`, with every earlier voucher of the channel settled.
    function _k8Frame(ChannelConfig[] memory cs, uint256 i, uint256 seq) internal view returns (bytes memory) {
        bytes memory sig =
            _voucher(payerKeys[i], _channelId(cs[i]), seq, AMOUNT, seq * AMOUNT, k8Commitments[i], PROVE_BY);
        return _frame(i, seq, AMOUNT, PROVE_BY, sig);
    }

    /// All eight lanes, lane `i` against `cs[i]`.
    function _k8Frames(ChannelConfig[] memory cs, uint256 seq) internal view returns (bytes memory frames) {
        for (uint256 i = 0; i < 8; i++) {
            frames = bytes.concat(frames, _k8Frame(cs, i, seq));
        }
    }

    /// Lane `lane` of the K=8 proof as voucher `seq` of channel `c` (channel index 0).
    function _singleChannelLane(ChannelConfig memory c, uint256 lane, uint256 seq)
        internal
        view
        returns (bytes memory)
    {
        bytes memory sig = _voucher(
            payerKeys[0], _channelId(c), seq, AMOUNT, seq * AMOUNT, k8Commitments[lane], PROVE_BY
        );
        return _frame(0, seq, AMOUNT, PROVE_BY, sig);
    }

    /// Eight vouchers of one channel, lane `i` carrying voucher `after + i + 1`.
    function _singleChannelFrames(ChannelConfig memory c, uint256 after_) internal view returns (bytes memory frames) {
        for (uint256 i = 0; i < 8; i++) {
            frames = bytes.concat(frames, _singleChannelLane(c, i, after_ + i + 1));
        }
    }

    // ── Closing ─────────────────────────────────────────────────────────────────────────────────

    uint256 internal constant FIELD = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

    /// A canonical field element, distinct per tag.
    function _c(string memory tag, uint256 n) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(tag, n))) % FIELD);
    }

    function _v(uint256 seq, uint256 amount, uint256 cum, bytes32 commitment, uint256 proveBy)
        internal
        pure
        returns (ChannelSettlement.Voucher memory)
    {
        return ChannelSettlement.Voucher({
            seq: uint48(seq),
            amount: uint96(amount),
            cumAmount: uint96(cum),
            inputCommitment: commitment,
            proveBy: uint40(proveBy)
        });
    }

    function _signV(uint256 key, bytes32 id, ChannelSettlement.Voucher memory v) internal view returns (bytes memory) {
        return _voucher(key, id, v.seq, v.amount, v.cumAmount, v.inputCommitment, v.proveBy);
    }

    /// Voucher `seq` of `AMOUNT` with cumulative `seq * AMOUNT`, the shape every test uses unless
    /// it says otherwise.
    function _std(uint256 seq, string memory tag) internal view returns (ChannelSettlement.Voucher memory) {
        return _v(seq, AMOUNT, seq * AMOUNT, _c(tag, seq), block.timestamp + 1800);
    }

    function _requestClose(ChannelConfig memory c) internal {
        vm.prank(c.payer);
        settlement.requestClose(c);
    }

    function _challenge(ChannelConfig memory c, uint256 key, ChannelSettlement.Voucher memory v) internal {
        bytes memory sig = _signV(key, _channelId(c), v);
        vm.prank(c.payTo);
        settlement.challengeClose(c, v, sig);
    }

    function _waive(ChannelConfig memory c, uint256 key, ChannelSettlement.Voucher memory v) internal {
        bytes memory sig = _signV(key, _channelId(c), v);
        vm.prank(c.payTo);
        settlement.waive(c, v, sig);
    }

    // ── Settling ────────────────────────────────────────────────────────────────────────────────

    function _settleK8(ChannelConfig[] memory cs, bytes memory frames) internal {
        settlement.settleBatch(k8Entry, set, K8_INDEX, cs, frames, k8Commitments, k8Outputs, k8Proof);
    }

    /// Run `settleBatch` with the K=8 proof and return what its `BatchSettled` log says.
    function _settleK8Recorded(ChannelConfig[] memory cs, bytes memory frames)
        internal
        returns (uint256 total, bytes memory results)
    {
        vm.recordLogs();
        _settleK8(cs, frames);
        return _batchSettled();
    }

    function _batchSettled() internal view returns (uint256 total, bytes memory results) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == ChannelSettlement.BatchSettled.selector) {
                (, total, results) = abi.decode(logs[i].data, (address, uint256, bytes));
                found++;
            }
        }
        assertEq(found, 1, "one BatchSettled log");
    }

    /// Count `FrameSettled` logs in `logs` for channel `id`.
    function _frameLogs(Vm.Log[] memory logs, bytes32 id) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == ChannelSettlement.FrameSettled.selector && logs[i].topics[1] == id) n++;
        }
    }

    /// Lane results: every lane `Settled` except those set by the caller.
    function _results(uint256 lanes) internal pure returns (bytes memory) {
        return new bytes(lanes);
    }

    function _code(ChannelSettlement.LaneResult r) internal pure returns (bytes1) {
        return bytes1(uint8(r));
    }
}
