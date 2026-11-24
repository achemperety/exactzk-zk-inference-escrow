// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC3009} from "./IERC3009.sol";
import {IVerifierRegistry, VerifierEntry} from "./IVerifierRegistry.sol";
import {ProofCheck, ProofStatus} from "./ProofCheck.sol";

/// @notice A channel's fixed terms. Never stored: every call that needs them passes them in, and
/// the contract recomputes the channel id from them, so terms that were not opened name no channel.
struct ChannelConfig {
    address payer; // deposits, and signs one voucher per request
    address payTo; // the provider: what valid proofs settle accrues to it
    address asset; // an ERC-3009 token that moves exact amounts (USDC)
    bytes32 verifierSetHash; // keccak256(abi.encodePacked(ids)) of the registry entries the channel accepts
    uint40 proveWindow; // seconds: a voucher's proveBy may be at most this far ahead when it settles
    uint40 challengeWindow; // seconds the provider has to answer a close request (close functions)
    bytes32 salt; // makes otherwise equal configs distinct
}

/// @title ChannelSettlement
/// @notice Prepaid channels between one payer and one provider. The payer deposits once and signs a
/// voucher per request; the provider settles vouchers in batches, one proof per batch, and is paid
/// only for lanes the proof covers. Payments accrue to the provider, who withdraws them.
/// @dev Storage per channel is one hot slot, read and written by every settlement:
///   balance (bits 0-95) | accounted (96-191) | seq (192-239) | state (240-247) | spare (248-255)
/// `balance` is what is left of the deposit, `accounted` the cumulative amount of the vouchers
/// settled or waived so far, `seq` the last of them. A second, cold slot is written only by
/// `requestClose` and `challengeClose`, and read only while the channel is closing:
///   closingAt (bits 0-63) | claimed (64-159) | holdExpiry (160-223)
/// `claimed` is the cumulative amount of the voucher the provider presented in its challenge.
/// The amount held for the provider is not stored: it is `claimed - accounted`, capped at the
/// balance, so a voucher that settles or is waived shrinks the hold without a write to this slot.
///
/// Closing: the payer calls `requestClose`; for `challengeWindow` seconds the provider may present
/// the latest voucher it holds (`challengeClose`). After that, anyone calls `finalizeClose`, which
/// returns to the payer everything not held. What is held stays for the provider to settle until
/// `closingAt + proveWindow`; then anyone may return the rest to the payer (`sweepExpiredHold`).
/// Settlement goes on throughout. The provider may give up any voucher (`waive`), so that a
/// voucher it cannot prove does not block the ones after it.
///
/// The payer signs two things: the ERC-3009 authorization that pulls the deposit, whose nonce is
/// the channel id (an ERC-712 struct hash of the config, the chain id and this contract's address),
/// and an ERC-712 voucher per request in this contract's domain. A voucher binds the channel, its
/// sequence number, the amount, the cumulative amount through this voucher, the input commitment
/// and the deadline. Settlement takes the commitment from the proof's public inputs and the
/// cumulative amount from storage, so neither travels in the frame: if either differs from what
/// the payer signed, the signature does not verify.
///
/// The proof is not bound to a voucher, by design: a proof for a verifier in the channel's set
/// and the voucher's input commitment settles it. Clients make each commitment unique by including
/// random nonce values in the committed input.
///
/// No owner, no upgrade, no fee. The asset must move exact amounts.
contract ChannelSettlement {
    enum State {
        None,
        Open, // settles vouchers
        Closing, // close requested: settles vouchers, and the provider may challenge until closingAt
        Held, // finalized with a hold: settles vouchers out of the held balance until holdExpiry
        Closed // nothing left; accepts nothing
    }

    /// @notice What happened to one lane of a batch; `BatchSettled` carries one byte per lane.
    enum LaneResult {
        Settled, // the voucher settled and its amount accrued to the provider
        Padding, // the lane's commitment is the entry's `emptyLane`; there is no voucher
        OtherProvider, // the channel pays another provider or in another asset than the batch's
        VerifierNotAllowed, // the channel's verifier set is not the batch's set
        ChannelNotOpen, // no channel with this config accepts vouchers: never opened, closed, or its hold expired
        WrongSeq, // the voucher is not the channel's next one
        Expired, // the voucher's proveBy has passed
        BeyondProveWindow, // the voucher's proveBy is further ahead than the channel's proveWindow
        InsufficientBalance, // the channel's balance is below the voucher's amount
        BadSignature // not the payer's signature over this voucher (channel, commitment, amounts...)
    }

    /// @notice ERC-712 type of the channel id, which is also the nonce of the deposit authorization.
    bytes32 public constant CHANNEL_TYPEHASH = keccak256(
        "ProofGatedChannel(uint256 chainId,address settlement,address payer,address payTo,address asset,"
        "bytes32 verifierSetHash,uint40 proveWindow,uint40 challengeWindow,bytes32 salt)"
    );

    /// @notice ERC-712 type the payer signs for each request, in this contract's domain.
    bytes32 public constant VOUCHER_TYPEHASH = keccak256(
        "Voucher(bytes32 channelId,uint48 seq,uint96 amount,uint96 cumAmount,bytes32 inputCommitment,uint40 proveBy)"
    );

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("ChannelSettlement");
    bytes32 private constant VERSION_HASH = keccak256("1");

    /// @notice Smallest windows a channel may be opened with.
    uint40 public constant MIN_PROVE_WINDOW = 60;
    uint40 public constant MIN_CHALLENGE_WINDOW = 300;

    /// @dev Bytes of a frame before its signature: channel index (2), seq (6), amount (12),
    /// proveBy (5), signature length (2).
    uint256 private constant FRAME_HEADER = 27;

    uint256 private constant MASK40 = (1 << 40) - 1;
    uint256 private constant MASK48 = (1 << 48) - 1;
    uint256 private constant MASK64 = (1 << 64) - 1;
    uint256 private constant MASK96 = (1 << 96) - 1;
    /// @dev `accounted` and `seq` in the hot slot.
    uint256 private constant SEQ_AND_ACCOUNTED = ((1 << 144) - 1) << 96;

    IVerifierRegistry public immutable registry;

    uint256 private immutable _cachedChainId;
    bytes32 private immutable _cachedDomainSeparator;

    struct ChannelSlots {
        uint256 hot; // balance | accounted | seq | state, see the contract notes
        uint256 cold; // closingAt | claimed | holdExpiry, see the contract notes
    }

    mapping(bytes32 channelId => ChannelSlots) private _channels;

    /// @notice Settled amounts not yet withdrawn, by provider and asset.
    mapping(address payTo => mapping(address asset => uint256)) public accrued;

    event ChannelOpened(
        bytes32 indexed channelId, address indexed payer, address indexed payTo, ChannelConfig config, uint256 deposit
    );
    /// @notice One per settled lane, so a client can find its voucher by channel.
    event FrameSettled(bytes32 indexed channelId, uint48 seq);
    /// @notice One per batch. `laneResults[i]` is lane `i`'s `LaneResult`.
    event BatchSettled(
        bytes32 indexed verifierId, address indexed payTo, address asset, uint256 total, bytes laneResults
    );
    event Withdrawn(address indexed payTo, address indexed asset, uint256 amount);
    event CloseRequested(bytes32 indexed channelId, uint256 closingAt);
    /// @notice The provider presented voucher `seq`; up to `claimed - accounted` stays held when the
    /// channel is finalized, until `holdExpiry`.
    event CloseChallenged(bytes32 indexed channelId, uint48 seq, uint256 claimed, uint256 holdExpiry);
    /// @notice `returned` went back to the payer; `held` stays for the provider until the hold expires.
    event ChannelFinalized(bytes32 indexed channelId, uint256 returned, uint256 held);
    event HoldSwept(bytes32 indexed channelId, uint256 returned);
    /// @notice The provider gave up voucher `seq`. `returned` is what that released to the payer,
    /// which is non-zero only after the channel was finalized with a hold.
    event FrameWaived(bytes32 indexed channelId, uint48 seq, uint256 amount, uint256 returned);

    /// @notice The verifier ran and did not accept, or the commitments or outputs do not fit the entry.
    error ProofInvalid();
    /// @notice The batch names an unknown verifier, the supplied entry is not its registered entry,
    /// or the adapter or verifier no longer has the registered code.
    error VerifierUnavailable(bytes32 verifierId);
    /// @notice `setIndex` is outside `verifierSet`.
    error VerifierNotInSet();
    /// @notice The frames do not parse: a frame is cut short, names a channel index outside
    /// `channels`, or bytes are left over; or `channels` is empty.
    error MalformedFrames();
    /// @notice No lane settled. `laneResults` says why, lane by lane.
    error NothingSettled(bytes laneResults);
    error WindowTooShort();
    error BadDeposit();
    error ZeroPayTo();
    error ChannelExists(bytes32 channelId);
    error AmountUnavailable(uint256 available);
    error TransferFailed();
    error NotPayer();
    error NotProvider();
    /// @notice The channel is not in a state that allows this call (`None`: no channel has this config).
    error WrongState(State state);
    error ChallengeWindowClosed(uint256 closingAt);
    error ChallengeWindowOpen(uint256 closingAt);
    error HoldNotExpired(uint256 holdExpiry);
    error HoldExpired(uint256 holdExpiry);
    /// @notice A voucher presented to `challengeClose` or `waive` fails the check a batch lane
    /// would report as `reason`.
    error VoucherRefused(LaneResult reason);
    /// @notice The challenge's cumulative amount is not above both what is accounted and what an
    /// earlier challenge claimed.
    error NoNewClaim();
    /// @notice A waived voucher's cumulative amount must be `accounted + amount`.
    error CumAmountMismatch(uint256 expected);

    constructor(IVerifierRegistry registry_) {
        registry = registry_;
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
    }

    // ── Opening ─────────────────────────────────────────────────────────────────────────────────

    /// @notice Open a channel and pull `deposit` from the payer with its ERC-3009 authorization,
    /// whose nonce must be the channel id. Anyone may submit.
    function openChannel(ChannelConfig calldata c, uint256 deposit, uint256 validBefore, bytes calldata paymentSig)
        external
        returns (bytes32 id)
    {
        if (c.proveWindow < MIN_PROVE_WINDOW || c.challengeWindow < MIN_CHALLENGE_WINDOW) revert WindowTooShort();
        if (deposit == 0 || deposit > MASK96) revert BadDeposit();
        if (c.payTo == address(0)) revert ZeroPayTo();
        id = _channelId(c);
        ChannelSlots storage s = _channels[id];
        if (s.hot != 0) revert ChannelExists(id);
        s.hot = (uint256(State.Open) << 240) | deposit;
        IERC3009(c.asset).receiveWithAuthorization(c.payer, address(this), deposit, 0, validBefore, id, paymentSig);
        emit ChannelOpened(id, c.payer, c.payTo, c, deposit);
    }

    // ── Settling ────────────────────────────────────────────────────────────────────────────────

    /// @dev Values shared by every lane of one batch.
    struct Batch {
        address payTo;
        address asset;
        bytes32 setHash;
        bytes32 emptyLane;
        bytes32 domainSeparator;
        uint256 total;
        uint256 settled;
    }

    /// @notice Settle up to `e.lanes` vouchers with one proof. Anyone may submit; what settles
    /// accrues to the provider of `channels[0]`.
    /// @param e The registered entry of `verifierSet[setIndex]`, checked against the registry's hash.
    /// @param verifierSet The ids whose hash every channel in the batch signed as its verifier set.
    /// @param channels Configs of the channels the frames name, by index. `channels[0]` sets the
    /// batch's provider and asset; a lane whose channel has another is skipped.
    /// @param frames One frame per lane that is not padding, in lane order, packed:
    /// channel index (uint16), seq (uint48), amount (uint96), proveBy (uint40), signature length
    /// (uint16), signature (65 bytes `r, s, v` for an EOA payer; any length for ERC-1271).
    /// @param commitments One input commitment per lane; lane `i`'s voucher must name `commitments[i]`.
    /// @param outputs Every lane's output, lane after lane. Read by the proof check only; a client
    /// finds its output in this transaction's input.
    /// @dev Reverts if the proof is not valid, if the frames do not parse, and if no lane settles.
    /// Otherwise every lane's result is in `BatchSettled`.
    function settleBatch(
        VerifierEntry calldata e,
        bytes32[] calldata verifierSet,
        uint256 setIndex,
        ChannelConfig[] calldata channels,
        bytes calldata frames,
        bytes32[] calldata commitments,
        bytes calldata outputs,
        bytes calldata proof
    ) external {
        if (setIndex >= verifierSet.length) revert VerifierNotInSet();
        bytes32 verifierId = verifierSet[setIndex];
        ProofStatus status = ProofCheck.check(registry, verifierId, e, commitments, outputs, proof);
        if (status != ProofStatus.Valid) {
            if (status == ProofStatus.Unverifiable) revert VerifierUnavailable(verifierId);
            revert ProofInvalid();
        }
        if (channels.length == 0) revert MalformedFrames();

        Batch memory b = Batch({
            payTo: channels[0].payTo,
            asset: channels[0].asset,
            setHash: keccak256(abi.encodePacked(verifierSet)),
            emptyLane: e.emptyLane,
            domainSeparator: _domainSeparator(),
            total: 0,
            settled: 0
        });
        bytes memory results = _walk(b, channels, frames, commitments);
        if (b.settled == 0) revert NothingSettled(results);

        if (b.total != 0) accrued[b.payTo][b.asset] += b.total;
        emit BatchSettled(verifierId, b.payTo, b.asset, b.total, results);
    }

    /// @dev One pass over the lanes. The proof check has made the number of commitments equal to
    /// the entry's lanes. Returns one result byte per lane; zero is `Settled`.
    function _walk(
        Batch memory b,
        ChannelConfig[] calldata channels,
        bytes calldata frames,
        bytes32[] calldata commitments
    ) private returns (bytes memory results) {
        uint256 lanes = commitments.length;
        results = new bytes(lanes);
        uint256 cursor;
        for (uint256 i; i < lanes; ++i) {
            bytes32 commitment = commitments[i];
            if (b.emptyLane != 0 && commitment == b.emptyLane) {
                results[i] = bytes1(uint8(LaneResult.Padding));
                continue;
            }
            uint256 header;
            uint256 sigStart;
            (header, sigStart, cursor) = _frameAt(frames, cursor);
            uint256 index = header >> 240;
            if (index >= channels.length) revert MalformedFrames();
            LaneResult r = _settleLane(channels[index], b, commitment, header, frames[sigStart:cursor]);
            if (r != LaneResult.Settled) results[i] = bytes1(uint8(r));
        }
        if (cursor != frames.length) revert MalformedFrames();
    }

    /// @dev `header` is the frame's first 32 bytes, see `_frameAt`. Checks run cheapest first, so
    /// a lane that would fail anyway costs no signature check.
    function _settleLane(
        ChannelConfig calldata c,
        Batch memory b,
        bytes32 commitment,
        uint256 header,
        bytes calldata sig
    ) private returns (LaneResult) {
        if (c.payTo != b.payTo || c.asset != b.asset) return LaneResult.OtherProvider;
        if (c.verifierSetHash != b.setHash) return LaneResult.VerifierNotAllowed;

        bytes32 id = _channelId(c);
        ChannelSlots storage s = _channels[id];
        uint256 hot = s.hot;
        uint256 top = hot >> 240; // state (the spare bits are zero); kept unless a hold runs out
        if (top != uint256(State.Open)) {
            if (top == uint256(State.Held)) {
                if (block.timestamp > s.cold >> 160) return LaneResult.ChannelNotOpen;
                // Settling the whole held balance leaves nothing to hold.
                if ((header >> 96) & MASK96 == hot & MASK96) top = uint256(State.Closed);
            } else if (top != uint256(State.Closing)) {
                return LaneResult.ChannelNotOpen;
            }
        }
        uint256 seq = (header >> 192) & MASK48;
        if (seq != ((hot >> 192) & MASK48) + 1) return LaneResult.WrongSeq;
        uint256 proveBy = (header >> 56) & MASK40;
        if (block.timestamp > proveBy) return LaneResult.Expired;
        if (proveBy > block.timestamp + c.proveWindow) return LaneResult.BeyondProveWindow;
        uint256 amount = (header >> 96) & MASK96;
        uint256 balance = hot & MASK96;
        if (amount > balance) return LaneResult.InsufficientBalance;

        // A cumulative amount that does not fit 96 bits cannot be in a voucher of this type.
        uint256 cumAmount = ((hot >> 96) & MASK96) + amount;
        if (cumAmount > MASK96) return LaneResult.BadSignature;
        bytes32 digest = _voucherDigest(b.domainSeparator, id, seq, amount, cumAmount, commitment, proveBy);
        if (!_signedBy(c.payer, digest, sig)) return LaneResult.BadSignature;

        s.hot = (top << 240) | (seq << 192) | (cumAmount << 96) | (balance - amount);
        b.total += amount;
        ++b.settled;
        emit FrameSettled(id, uint48(seq));
        return LaneResult.Settled;
    }

    /// @dev ECDSA first, then ERC-1271. Asking the payer's code size first, as
    /// `SignatureChecker.isValidSignatureNow` does, would cost 2,600 gas for every payer not yet
    /// touched in the transaction; an ECDSA signature that recovers to the payer is accepted
    /// without that. Anything else goes to the payer's `isValidSignature`.
    function _signedBy(address payer, bytes32 digest, bytes calldata sig) private view returns (bool) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, sig);
        if (err == ECDSA.RecoverError.NoError && recovered == payer) return true;
        return SignatureChecker.isValidERC1271SignatureNowCalldata(payer, digest, sig);
    }

    /// @dev Reads the frame at `cursor`: `header` is the 32 bytes from `cursor`, of which the first
    /// 27 are the frame's header (bits 255-240 channel index, 239-192 seq, 191-96 amount, 95-56
    /// proveBy, 55-40 signature length) and the rest is not used. The signature is
    /// `frames[sigStart:next]`. Reverts if the frame runs past the end of `frames`; that includes a
    /// header cut short, since `next` is never before the header's end.
    function _frameAt(bytes calldata frames, uint256 cursor)
        private
        pure
        returns (uint256 header, uint256 sigStart, uint256 next)
    {
        sigStart = cursor + FRAME_HEADER;
        assembly ("memory-safe") {
            header := calldataload(add(frames.offset, cursor))
        }
        next = sigStart + ((header >> 40) & 0xffff);
        if (next > frames.length) revert MalformedFrames();
    }

    // ── Withdrawing ─────────────────────────────────────────────────────────────────────────────

    /// @notice Pay `amount` of the caller's accrued `asset` to the caller. A provider that leaves a
    /// small amount accrued keeps its next batch's accrual a non-zero to non-zero write.
    function withdraw(address asset, uint256 amount) external {
        uint256 available = accrued[msg.sender][asset];
        if (amount == 0 || amount > available) revert AmountUnavailable(available);
        accrued[msg.sender][asset] = available - amount;
        _pay(asset, msg.sender, amount);
        emit Withdrawn(msg.sender, asset, amount);
    }

    // ── Closing ─────────────────────────────────────────────────────────────────────────────────

    /// @notice A voucher presented outside a batch, to `challengeClose` or `waive`. The payer signed
    /// it as the ERC-712 `Voucher` of the channel the call names.
    struct Voucher {
        uint48 seq;
        uint96 amount;
        uint96 cumAmount;
        bytes32 inputCommitment;
        uint40 proveBy;
    }

    /// @notice Start closing an open channel. For `challengeWindow` seconds the provider may answer
    /// with the latest voucher it holds; settlement goes on meanwhile. Only the payer may call.
    function requestClose(ChannelConfig calldata c) external {
        if (msg.sender != c.payer) revert NotPayer();
        bytes32 id = _channelId(c);
        ChannelSlots storage s = _channels[id];
        uint256 hot = s.hot;
        _requireState(hot, State.Open);
        uint256 closingAt = block.timestamp + c.challengeWindow;
        s.hot = (uint256(State.Closing) << 240) | (hot & (SEQ_AND_ACCOUNTED | MASK96));
        s.cold = closingAt;
        emit CloseRequested(id, closingAt);
    }

    /// @notice Answer a close request with a voucher the provider holds and has not settled. When
    /// the channel is finalized, the voucher's cumulative amount less what is accounted by then,
    /// capped at the balance, stays held for the provider to settle until `closingAt + proveWindow`.
    /// The hold's end depends only on the channel's terms, never on the voucher. A later challenge
    /// with a higher cumulative amount raises the claim. Only the provider may call, before
    /// `closingAt`, with a voucher that a batch could still settle in time.
    function challengeClose(ChannelConfig calldata c, Voucher calldata v, bytes calldata sig) external {
        if (msg.sender != c.payTo) revert NotProvider();
        bytes32 id = _channelId(c);
        ChannelSlots storage s = _channels[id];
        uint256 hot = s.hot;
        _requireState(hot, State.Closing);
        uint256 cold = s.cold;
        uint256 closingAt = cold & MASK64;
        if (block.timestamp >= closingAt) revert ChallengeWindowClosed(closingAt);
        if (v.seq <= (hot >> 192) & MASK48) revert VoucherRefused(LaneResult.WrongSeq);
        if (block.timestamp > v.proveBy) revert VoucherRefused(LaneResult.Expired);
        if (v.proveBy > block.timestamp + c.proveWindow) revert VoucherRefused(LaneResult.BeyondProveWindow);
        if (v.cumAmount <= (cold >> 64) & MASK96 || v.cumAmount <= (hot >> 96) & MASK96) revert NoNewClaim();
        bytes32 digest =
            _voucherDigest(_domainSeparator(), id, v.seq, v.amount, v.cumAmount, v.inputCommitment, v.proveBy);
        if (!_signedBy(c.payer, digest, sig)) revert VoucherRefused(LaneResult.BadSignature);
        uint256 holdExpiry = closingAt + c.proveWindow;
        s.cold = (holdExpiry << 160) | (uint256(v.cumAmount) << 64) | closingAt;
        emit CloseChallenged(id, v.seq, v.cumAmount, holdExpiry);
    }

    /// @notice After the challenge window, return to the payer everything not held. With nothing
    /// held the channel is closed; otherwise it keeps the held amount for the provider until the
    /// hold expires. Anyone may call.
    function finalizeClose(ChannelConfig calldata c) external {
        bytes32 id = _channelId(c);
        ChannelSlots storage s = _channels[id];
        uint256 hot = s.hot;
        _requireState(hot, State.Closing);
        uint256 cold = s.cold;
        uint256 closingAt = cold & MASK64;
        if (block.timestamp < closingAt) revert ChallengeWindowOpen(closingAt);
        uint256 held = _held(hot, cold);
        uint256 returned = (hot & MASK96) - held;
        s.hot = (uint256(held == 0 ? State.Closed : State.Held) << 240) | (hot & SEQ_AND_ACCOUNTED) | held;
        if (returned != 0) _pay(c.asset, c.payer, returned);
        emit ChannelFinalized(id, returned, held);
    }

    /// @notice After the hold expires, return what is left of it to the payer and close the
    /// channel. Anyone may call.
    function sweepExpiredHold(ChannelConfig calldata c) external {
        bytes32 id = _channelId(c);
        ChannelSlots storage s = _channels[id];
        uint256 hot = s.hot;
        _requireState(hot, State.Held);
        uint256 holdExpiry = s.cold >> 160;
        if (block.timestamp <= holdExpiry) revert HoldNotExpired(holdExpiry);
        uint256 returned = hot & MASK96;
        s.hot = (uint256(State.Closed) << 240) | (hot & SEQ_AND_ACCOUNTED);
        if (returned != 0) _pay(c.asset, c.payer, returned);
        emit HoldSwept(id, returned);
    }

    /// @notice Give up the channel's next voucher without payment, so that the vouchers after it
    /// can settle. Its amount is accounted and the balance is kept; a hold shrinks by it, and
    /// after finalization what it releases goes back to the payer. Works for a voucher that has
    /// expired or that the balance does not cover. Only the provider may call.
    function waive(ChannelConfig calldata c, Voucher calldata v, bytes calldata sig) external {
        if (msg.sender != c.payTo) revert NotProvider();
        bytes32 id = _channelId(c);
        ChannelSlots storage s = _channels[id];
        uint256 hot = s.hot;
        uint256 state = (hot >> 240) & 0xff;
        uint256 cold;
        if (state == uint256(State.Held)) {
            cold = s.cold;
            if (block.timestamp > cold >> 160) revert HoldExpired(cold >> 160);
        } else if (state != uint256(State.Open) && state != uint256(State.Closing)) {
            revert WrongState(State(state));
        }
        if (v.seq != ((hot >> 192) & MASK48) + 1) revert VoucherRefused(LaneResult.WrongSeq);
        uint256 expected = ((hot >> 96) & MASK96) + v.amount;
        if (v.cumAmount != expected) revert CumAmountMismatch(expected);
        bytes32 digest =
            _voucherDigest(_domainSeparator(), id, v.seq, v.amount, v.cumAmount, v.inputCommitment, v.proveBy);
        if (!_signedBy(c.payer, digest, sig)) revert VoucherRefused(LaneResult.BadSignature);

        hot = (state << 240) | (uint256(v.seq) << 192) | (expected << 96) | (hot & MASK96);
        uint256 returned;
        if (state == uint256(State.Held)) {
            uint256 held = _held(hot, cold);
            returned = (hot & MASK96) - held;
            hot = (uint256(held == 0 ? State.Closed : State.Held) << 240) | (hot & SEQ_AND_ACCOUNTED) | held;
        }
        s.hot = hot;
        if (returned != 0) _pay(c.asset, c.payer, returned);
        emit FrameWaived(id, v.seq, v.amount, returned);
    }

    // ── Views ───────────────────────────────────────────────────────────────────────────────────

    function channelId(ChannelConfig calldata c) external view returns (bytes32) {
        return _channelId(c);
    }

    function channel(bytes32 id) external view returns (uint256 balance, uint256 accounted, uint256 seq, State state) {
        uint256 hot = _channels[id].hot;
        return (hot & MASK96, (hot >> 96) & MASK96, (hot >> 192) & MASK48, State((hot >> 240) & 0xff));
    }

    /// @notice A closing channel's figures: when the challenge window ends, the cumulative amount
    /// the provider's challenge claims, when the hold ends, and the amount held now (zero unless
    /// the channel is closing or held and the hold has not expired).
    function closeState(bytes32 id)
        external
        view
        returns (uint256 closingAt, uint256 claimed, uint256 holdExpiry, uint256 held)
    {
        ChannelSlots storage s = _channels[id];
        uint256 hot = s.hot;
        uint256 cold = s.cold;
        uint256 state = (hot >> 240) & 0xff;
        if (state == uint256(State.Closing) || state == uint256(State.Held)) held = _held(hot, cold);
        return (cold & MASK64, (cold >> 64) & MASK96, cold >> 160, held);
    }

    /// @notice The value a channel config carries as `verifierSetHash` for these ids.
    function verifierSetHash(bytes32[] calldata ids) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(ids));
    }

    /// @notice The ERC-712 digest a payer signs for a voucher.
    function voucherDigest(
        bytes32 id,
        uint48 seq,
        uint96 amount,
        uint96 cumAmount,
        bytes32 inputCommitment,
        uint40 proveBy
    ) external view returns (bytes32) {
        return _voucherDigest(_domainSeparator(), id, seq, amount, cumAmount, inputCommitment, proveBy);
    }

    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ── Internals ───────────────────────────────────────────────────────────────────────────────

    function _requireState(uint256 hot, State expected) private pure {
        uint256 state = (hot >> 240) & 0xff;
        if (state != uint256(expected)) revert WrongState(State(state));
    }

    /// @dev What a challenge holds now: the claimed cumulative amount less what is accounted,
    /// capped at the balance; zero without a challenge or once the hold has expired.
    function _held(uint256 hot, uint256 cold) private view returns (uint256) {
        if (block.timestamp > cold >> 160) return 0;
        uint256 claimed = (cold >> 64) & MASK96;
        uint256 accounted = (hot >> 96) & MASK96;
        if (claimed <= accounted) return 0;
        uint256 balance = hot & MASK96;
        uint256 open = claimed - accounted;
        return open < balance ? open : balance;
    }

    /// @dev The ERC-712 struct hash of `ProofGatedChannel` with `chainId` and `settlement` first:
    /// `keccak256(abi.encode(CHANNEL_TYPEHASH, block.chainid, address(this), c))`. The config's
    /// seven words are hashed as they are in calldata, in scratch memory, so settling a lane does
    /// not grow memory. A config whose words are not canonically encoded hashes to an id no channel
    /// has: `openChannel` reads every narrow field through the ABI decoder, which rejects such
    /// encodings, so every open channel's id comes from a canonical config.
    function _channelId(ChannelConfig calldata c) private view returns (bytes32 id) {
        bytes32 typehash = CHANNEL_TYPEHASH;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, typehash)
            mstore(add(p, 0x20), chainid())
            mstore(add(p, 0x40), address())
            calldatacopy(add(p, 0x60), c, 0xe0)
            id := keccak256(p, 0x140)
        }
    }

    /// @dev `toTypedDataHash(domainSeparator, keccak256(abi.encode(VOUCHER_TYPEHASH, id, seq, amount,
    /// cumAmount, commitment, proveBy)))`, computed in scratch memory.
    function _voucherDigest(
        bytes32 domainSeparator,
        bytes32 id,
        uint256 seq,
        uint256 amount,
        uint256 cumAmount,
        bytes32 commitment,
        uint256 proveBy
    ) private pure returns (bytes32 digest) {
        bytes32 typehash = VOUCHER_TYPEHASH;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, typehash)
            mstore(add(p, 0x20), id)
            mstore(add(p, 0x40), seq)
            mstore(add(p, 0x60), amount)
            mstore(add(p, 0x80), cumAmount)
            mstore(add(p, 0xa0), commitment)
            mstore(add(p, 0xc0), proveBy)
            let structHash := keccak256(p, 0xe0)
            mstore(p, shl(240, 0x1901))
            mstore(add(p, 0x02), domainSeparator)
            mstore(add(p, 0x22), structHash)
            digest := keccak256(p, 0x42)
        }
    }

    function _domainSeparator() private view returns (bytes32) {
        return block.chainid == _cachedChainId ? _cachedDomainSeparator : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    /// @dev ERC-20 `transfer` that accepts a token returning `true` or nothing, and reverts otherwise.
    /// The asset has code: an earlier `receiveWithAuthorization` on it moved the deposit.
    function _pay(address asset, address to, uint256 amount) private {
        bool ok;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, 0xa9059cbb)) // transfer(address,uint256)
            mstore(add(p, 0x04), to)
            mstore(add(p, 0x24), amount)
            mstore(0x00, 0)
            ok := call(gas(), asset, 0, p, 0x44, 0x00, 0x20)
            ok := and(ok, or(iszero(returndatasize()), and(gt(returndatasize(), 0x1f), eq(mload(0x00), 1))))
        }
        if (!ok) revert TransferFailed();
    }
}
