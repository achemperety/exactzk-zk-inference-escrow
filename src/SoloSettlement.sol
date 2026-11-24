// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC3009} from "./IERC3009.sol";
import {IVerifierRegistry, VerifierEntry} from "./IVerifierRegistry.sol";
import {ProofCheck, ProofStatus} from "./ProofCheck.sol";

/// @notice What a payer agrees to for one inference. Every field is covered by the payer's
/// signature, through the request id (see `SoloSettlement`).
struct Terms {
    address payer; // pays, and signs the ERC-3009 authorization
    address payTo; // receives the payment when a valid proof is presented
    address asset; // an ERC-3009 token that moves exact amounts (USDC)
    uint256 amount;
    bytes32 verifierId; // the registry entry whose circuit must produce the proof
    bytes32 inputCommitment; // the proof's public commitment to the payer's input
    uint64 proveBy; // last second at which a proof is accepted
    bytes32 salt; // makes otherwise equal terms distinct
}

/// @title SoloSettlement
/// @notice Payment for one inference, released only by a valid proof that the circuit named in the
/// terms maps the committed input to the posted output. Two flows:
/// - one transaction: `settle` checks the proof, pulls the payment from the payer and pays the
///   provider; nothing is stored;
/// - escrow: `open` locks the payment and stores one slot; `release` pays the provider on a valid
///   proof up to `proveBy`; after `proveBy` anyone can `refund` the payer.
/// @dev The payer signs one message: an ERC-3009 `ReceiveWithAuthorization` in the token's domain
/// whose nonce is the request id. The id is an ERC-712 struct hash of the terms together with the
/// chain id, this contract's address and the flow, so the signature binds all of them, and the
/// token's nonce check makes each authorization usable once. ERC-1271 payers work because the
/// token checks the signature (USDC v2.2 does, for any payer with code).
///
/// The proof is not bound to the request, by design: a proof for the same verifier and the
/// same input commitment settles any request that names them. Clients make commitments unique by
/// including random nonce values in the committed input.
///
/// No owner, no upgrade, no fee. The asset must move exact amounts; a token that charges a fee on
/// transfer would make releases and refunds pay out more than was locked for them.
contract SoloSettlement {
    enum EscrowState {
        None,
        Open,
        Released,
        Refunded
    }

    /// @notice ERC-712 type of the request id in the one-transaction flow.
    bytes32 public constant PAYMENT_TYPEHASH = keccak256(
        "ProofGatedPayment(uint256 chainId,address settlement,address payer,address payTo,address asset,"
        "uint256 amount,bytes32 verifierId,bytes32 inputCommitment,uint64 proveBy,bytes32 salt)"
    );

    /// @notice ERC-712 type of the request id in the escrow flow. A different type, so an
    /// authorization signed for one flow cannot be used in the other.
    bytes32 public constant ESCROW_TYPEHASH = keccak256(
        "ProofGatedEscrow(uint256 chainId,address settlement,address payer,address payTo,address asset,"
        "uint256 amount,bytes32 verifierId,bytes32 inputCommitment,uint64 proveBy,bytes32 salt)"
    );

    IVerifierRegistry public immutable registry;

    /// @notice Escrow flow only. Never reset, so a request id can be opened once.
    mapping(bytes32 requestId => EscrowState) public escrowState;

    event Settled(bytes32 indexed requestId, bytes32 indexed verifierId, address indexed payTo, bytes output);
    event Opened(bytes32 indexed requestId, address indexed payer, uint256 amount, uint64 proveBy);
    event Refunded(bytes32 indexed requestId);

    /// @notice The verifier ran and did not accept, or the output does not fit the entry.
    error ProofInvalid();
    /// @notice The terms name an unknown verifier, the supplied entry is not its registered entry,
    /// or the adapter or verifier no longer has the registered code.
    error VerifierUnavailable(bytes32 verifierId);
    /// @notice `proveBy` has passed (or, for `open`, is not in the future).
    error Expired();
    /// @notice `refund` before `proveBy` has passed.
    error NotExpired();
    error AlreadyOpened(bytes32 requestId);
    error NotOpen(bytes32 requestId);
    error TransferFailed();

    constructor(IVerifierRegistry registry_) {
        registry = registry_;
    }

    // ── One-transaction flow ────────────────────────────────────────────────────────────────────

    /// @notice Check the proof, pull `t.amount` from the payer with its authorization, pay `t.payTo`.
    /// @param e The registered entry of `t.verifierId`, supplied to save reading it from storage;
    /// it is checked against the registry's hash of the entry.
    /// @param validBefore The `validBefore` of the payer's authorization (its `validAfter` is 0).
    /// @param paymentSig The payer's signature over the authorization, as the token expects it.
    /// @param output The circuit's public output, `e.outputSize` bytes.
    function settle(
        Terms calldata t,
        VerifierEntry calldata e,
        uint256 validBefore,
        bytes calldata paymentSig,
        bytes calldata output,
        bytes calldata proof
    ) external {
        if (block.timestamp > t.proveBy) revert Expired();
        bytes32 id = _requestId(PAYMENT_TYPEHASH, t);
        _requireValidProof(t, e, output, proof);
        IERC3009(t.asset).receiveWithAuthorization(t.payer, address(this), t.amount, 0, validBefore, id, paymentSig);
        _pay(t.asset, t.payTo, t.amount);
        emit Settled(id, t.verifierId, t.payTo, output);
    }

    // ── Escrow flow ─────────────────────────────────────────────────────────────────────────────

    /// @notice Lock `t.amount` from the payer until a valid proof or `t.proveBy`. Anyone may submit.
    function open(Terms calldata t, uint256 validBefore, bytes calldata paymentSig) external returns (bytes32 id) {
        if (block.timestamp >= t.proveBy) revert Expired();
        id = _requestId(ESCROW_TYPEHASH, t);
        if (escrowState[id] != EscrowState.None) revert AlreadyOpened(id);
        escrowState[id] = EscrowState.Open;
        IERC3009(t.asset).receiveWithAuthorization(t.payer, address(this), t.amount, 0, validBefore, id, paymentSig);
        emit Opened(id, t.payer, t.amount, t.proveBy);
    }

    /// @notice Pay the locked amount to `t.payTo` on a valid proof, up to and including `t.proveBy`.
    /// Anyone may submit; the payment always goes to `t.payTo`.
    function release(Terms calldata t, VerifierEntry calldata e, bytes calldata output, bytes calldata proof) external {
        bytes32 id = _requestId(ESCROW_TYPEHASH, t);
        if (escrowState[id] != EscrowState.Open) revert NotOpen(id);
        if (block.timestamp > t.proveBy) revert Expired();
        _requireValidProof(t, e, output, proof);
        escrowState[id] = EscrowState.Released;
        _pay(t.asset, t.payTo, t.amount);
        emit Settled(id, t.verifierId, t.payTo, output);
    }

    /// @notice Return the locked amount to the payer once `t.proveBy` has passed. Anyone may submit.
    function refund(Terms calldata t) external {
        bytes32 id = _requestId(ESCROW_TYPEHASH, t);
        if (escrowState[id] != EscrowState.Open) revert NotOpen(id);
        if (block.timestamp <= t.proveBy) revert NotExpired();
        escrowState[id] = EscrowState.Refunded;
        _pay(t.asset, t.payer, t.amount);
        emit Refunded(id);
    }

    // ── Request ids ─────────────────────────────────────────────────────────────────────────────

    /// @notice The nonce the payer signs for the one-transaction flow.
    function paymentRequestId(Terms calldata t) external view returns (bytes32) {
        return _requestId(PAYMENT_TYPEHASH, t);
    }

    /// @notice The nonce the payer signs for the escrow flow; also the key of `escrowState`.
    function escrowRequestId(Terms calldata t) external view returns (bytes32) {
        return _requestId(ESCROW_TYPEHASH, t);
    }

    // ── Internals ───────────────────────────────────────────────────────────────────────────────

    /// @dev `abi.encode` of the static struct is its fields in order, so this is the ERC-712 struct
    /// hash of the flow's type with `chainId` and `settlement` first.
    function _requestId(bytes32 typehash, Terms calldata t) private view returns (bytes32) {
        return keccak256(abi.encode(typehash, block.chainid, address(this), t));
    }

    function _requireValidProof(Terms calldata t, VerifierEntry calldata e, bytes calldata output, bytes calldata proof)
        private
        view
    {
        ProofStatus status = ProofCheck.checkOne(registry, t.verifierId, e, t.inputCommitment, output, proof);
        if (status == ProofStatus.Valid) return;
        if (status == ProofStatus.Unverifiable) revert VerifierUnavailable(t.verifierId);
        revert ProofInvalid();
    }

    /// @dev ERC-20 `transfer` that accepts a token returning `true` or nothing, and reverts otherwise.
    /// The asset has code: the same asset's `receiveWithAuthorization` succeeded earlier.
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
