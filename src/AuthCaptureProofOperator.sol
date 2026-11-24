// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ClaimDigest} from "./ClaimDigest.sol";
import {IAuthCaptureEscrow} from "./IAuthCaptureEscrow.sol";
import {IVerifierRegistry, VerifierEntry} from "./IVerifierRegistry.sol";
import {ProofCheck, ProofStatus} from "./ProofCheck.sol";

/// @title AuthCaptureProofOperator
/// @notice A `"custom"` operator for x402's `auth-capture` scheme on EVM: held funds are paid out only
/// against a valid proof that the circuit of a registered verifier maps the payer's committed input
/// to some output.
///
/// The payer signs one ERC-3009 authorization, as for any `auth-capture` payment. Its nonce commits
/// to the whole `PaymentInfo`, including `salt`. The server publishes the payment's terms (a verifier
/// id and an input commitment) as `extra.receiverAuthorizer = termsAuthorizer(verifierId,
/// inputCommitment)`, an address derived from the terms that no one holds a key for. A client binds
/// it into the salt exactly as the scheme prescribes:
/// `salt = keccak256(abi.encode(SALT_BINDING_TYPEHASH, receiverAuthorizer, policy, saltNonce))`,
/// with `policy` zero. So the payer's signature commits to the terms without any change to the
/// scheme, the escrow, the facilitator or a client.
///
/// - `authorize`: the escrow's own collect call, open to anyone (the facilitator relays it). It
///   collects the full maximum, as the scheme requires.
/// - `charge`: always reverts. The escrow's `charge` pays out at once, so it must not be reachable
///   without a proof; use `chargeWithProof`.
/// - `captureWithProof`, `chargeWithProof`: anyone may call them with the terms, the client's
///   `saltNonce` and a valid proof. The whole held (or authorized) amount goes to the payment's
///   receiver, less the minimum fee the payer agreed to.
/// - `voidByReceiver`: the payment's receiver may give the hold back to the payer before the capture
///   deadline. After it, the payer reclaims the hold from the escrow itself.
///
/// A proof that does not verify, or a verifier that cannot be run, reverts and changes nothing. No
/// owner, no fee of its own, no storage.
contract AuthCaptureProofOperator {
    /// @notice The scheme's salt-binding tag (x402 `auth-capture` EVM binding, "Payment identity").
    bytes32 public constant SALT_BINDING_TYPEHASH =
        keccak256("x402AuthCaptureSaltBinding(address receiverAuthorizer,address policy,uint256 saltNonce)");

    /// @notice Tag of the terms an authorizer address is derived from.
    bytes32 public constant PROOF_TERMS_TYPEHASH =
        keccak256("ProofGatedTerms(bytes32 verifierId,bytes32 inputCommitment)");

    uint256 internal constant MAX_FEE_BPS = 10_000;

    IAuthCaptureEscrow public immutable escrow;
    IVerifierRegistry public immutable registry;

    /// @notice The terms of a payment and the client's contribution to its salt.
    struct Terms {
        bytes32 verifierId;
        bytes32 inputCommitment;
        uint256 saltNonce; // `payload.saltNonce` of the client's payment payload
    }

    event CapturedWithProof(bytes32 indexed paymentInfoHash, bytes32 indexed claimDigest, uint256 amount, bytes output);
    event ChargedWithProof(bytes32 indexed paymentInfoHash, bytes32 indexed claimDigest, uint256 amount, bytes output);
    event VoidedByReceiver(bytes32 indexed paymentInfoHash);

    /// @notice The verifier ran and did not accept, or the output does not fit the entry.
    error ProofInvalid();
    /// @notice Unknown verifier, an entry that is not its registered entry, or code that is not the
    /// registered code.
    error VerifierUnavailable(bytes32 verifierId);
    /// @notice The payment's salt is not bound to these terms and this salt nonce.
    error TermsMismatch();
    error WrongOperator();
    error NotReceiver();
    /// @notice `authorize` must collect the full maximum: the payer's authorization is single-use.
    error PartialAuthorization(uint256 amount, uint256 maxAmount);
    /// @notice The escrow's `charge` is not available here; use `chargeWithProof`.
    error ProofRequired();

    constructor(IAuthCaptureEscrow escrow_, IVerifierRegistry registry_) {
        escrow = escrow_;
        registry = registry_;
    }

    // ── Collect, with the escrow's ABI ──────────────────────────────────────────────────────────

    /// @notice Place the hold the payer authorized. Anyone may call this.
    function authorize(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        uint256 amount,
        address tokenCollector,
        bytes calldata collectorData
    ) external {
        if (amount != paymentInfo.maxAmount) {
            revert PartialAuthorization(amount, paymentInfo.maxAmount);
        }
        escrow.authorize(paymentInfo, amount, tokenCollector, collectorData);
    }

    /// @notice Not available: paying out needs a proof. Reverts.
    function charge(IAuthCaptureEscrow.PaymentInfo calldata, uint256, address, bytes calldata, uint256, address)
        external
        pure
    {
        revert ProofRequired();
    }

    // ── Pay out against a proof ─────────────────────────────────────────────────────────────────

    /// @notice Capture the whole hold for the receiver with a valid proof for the payment's terms.
    /// Anyone may call this.
    /// @param e The registered entry of `t.verifierId`, checked against the registry's hash of it.
    /// @param output The circuit's public output, `e.outputSize` bytes.
    function captureWithProof(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        Terms calldata t,
        VerifierEntry calldata e,
        bytes calldata output,
        bytes calldata proof
    ) external {
        bytes32 digest = _requireProof(paymentInfo, t, e, output, proof);
        bytes32 paymentInfoHash = escrow.getHash(paymentInfo);
        (, uint120 capturable,) = escrow.paymentState(paymentInfoHash);
        escrow.capture(paymentInfo, capturable, _minFee(paymentInfo, capturable), paymentInfo.feeReceiver);
        emit CapturedWithProof(paymentInfoHash, digest, capturable, output);
    }

    /// @notice Collect and pay out in one step with a valid proof for the payment's terms: the payer's
    /// authorization goes straight to the receiver, with no hold. Anyone may call this.
    function chargeWithProof(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        address tokenCollector,
        bytes calldata collectorData,
        Terms calldata t,
        VerifierEntry calldata e,
        bytes calldata output,
        bytes calldata proof
    ) external {
        bytes32 digest = _requireProof(paymentInfo, t, e, output, proof);
        uint256 amount = paymentInfo.maxAmount;
        escrow.charge(
            paymentInfo, amount, tokenCollector, collectorData, _minFee(paymentInfo, amount), paymentInfo.feeReceiver
        );
        emit ChargedWithProof(escrow.getHash(paymentInfo), digest, amount, output);
    }

    /// @notice The receiver gives the hold back to the payer, before the capture deadline.
    function voidByReceiver(IAuthCaptureEscrow.PaymentInfo calldata paymentInfo) external {
        if (msg.sender != paymentInfo.receiver) revert NotReceiver();
        escrow.void(paymentInfo);
        emit VoidedByReceiver(escrow.getHash(paymentInfo));
    }

    // ── Terms ───────────────────────────────────────────────────────────────────────────────────

    /// @notice The `extra.receiverAuthorizer` a server publishes for these terms.
    function termsAuthorizer(bytes32 verifierId, bytes32 inputCommitment) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(PROOF_TERMS_TYPEHASH, verifierId, inputCommitment)))));
    }

    /// @notice The salt a client derives for these terms and its salt nonce.
    function boundSalt(bytes32 verifierId, bytes32 inputCommitment, uint256 saltNonce) public pure returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(SALT_BINDING_TYPEHASH, termsAuthorizer(verifierId, inputCommitment), address(0), saltNonce)
            )
        );
    }

    // ── Internals ───────────────────────────────────────────────────────────────────────────────

    function _requireProof(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        Terms calldata t,
        VerifierEntry calldata e,
        bytes calldata output,
        bytes calldata proof
    ) private view returns (bytes32) {
        if (paymentInfo.operator != address(this)) revert WrongOperator();
        if (paymentInfo.salt != boundSalt(t.verifierId, t.inputCommitment, t.saltNonce)) revert TermsMismatch();
        ProofStatus status = ProofCheck.checkOne(registry, t.verifierId, e, t.inputCommitment, output, proof);
        if (status == ProofStatus.Unverifiable) revert VerifierUnavailable(t.verifierId);
        if (status != ProofStatus.Valid) revert ProofInvalid();
        return ClaimDigest.compute(t.verifierId, t.inputCommitment, keccak256(output));
    }

    /// @dev The lowest fee the escrow accepts: the payer's minimum. A caller cannot choose more.
    function _minFee(IAuthCaptureEscrow.PaymentInfo calldata paymentInfo, uint256 amount)
        private
        pure
        returns (uint256)
    {
        return amount * paymentInfo.minFeeBps / MAX_FEE_BPS;
    }
}
