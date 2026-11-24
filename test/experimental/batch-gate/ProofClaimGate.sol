// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {x402BatchSettlement} from "../../external/x402/src/x402BatchSettlement.sol";
import {IVerifierRegistry, VerifierEntry} from "../../../src/IVerifierRegistry.sol";
import {ProofCheck, ProofStatus} from "../../../src/ProofCheck.sol";

/// @title ProofClaimGate (PROTOTYPE, not for deployment)
/// @notice A claim condition for x402's `batch-settlement` channels: a voucher's value is claimed only
/// for requests whose input commitments the payer signed and a valid proof covers. The gate is the
/// channel's `receiverAuthorizer` and its `receiver`; the voucher format is unchanged.
///
/// - The payer signs once per batch an EIP-712 `CommitmentRoot` in this gate's domain: the channel, the
///   verifier, the root of a Merkle tree over the batch's ordered input commitments, the count, the
///   price per proven request and the amount already claimed before the batch.
/// - A claim presents one commitment with its position and an inclusion path, and a proof for it. The
///   gate checks the root signature, the inclusion at that position, and the proof against that very
///   commitment, then claims the payer's voucher up to `baseClaimed + proven * unitPrice`.
///
/// The gate must also be the channel's `receiver`: `x402BatchSettlement.claim` admits the receiver as
/// well as the receiver authorizer, so a receiver other than the gate could claim without a proof. The
/// gate therefore receives the settled funds and forwards them to `payee`. It implements no ERC-1271,
/// so `claimWithSignature` and `refundWithSignature` cannot be authorized for its channels; the payer
/// leaves through the timed withdrawal.
///
/// Tree: leaf `i` is `keccak256(abi.encode(LEAF_TAG, i, commitment_i))`; leaves past `count` are zero
/// up to the next power of two; a node is `keccak256(left ‖ right)`; the path goes from the leaf up,
/// and bit `j` of the position says whether the node at height `j` is a right child.
contract ProofClaimGate is EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant COMMITMENT_ROOT_TYPEHASH = keccak256(
        "CommitmentRoot(bytes32 channelId,bytes32 verifierId,bytes32 root,uint32 count,uint128 unitPrice,uint128 baseClaimed)"
    );
    bytes32 public constant LEAF_TAG = keccak256("x402.proof-claim-gate.leaf.v0");

    x402BatchSettlement public immutable settlement;
    IVerifierRegistry public immutable registry;
    address public immutable payee;

    /// @notice What the payer signs once per batch, apart from the channel id the gate computes.
    struct RootTerms {
        bytes32 verifierId;
        bytes32 root;
        uint32 count;
        uint128 unitPrice;
        uint128 baseClaimed;
    }

    /// @notice One commitment, where it sits in the batch, and the path to the root.
    struct Inclusion {
        uint32 position;
        bytes32 commitment;
        bytes32[] path;
    }

    mapping(bytes32 rootDigest => mapping(uint256 position => bool)) public proven;
    mapping(bytes32 rootDigest => uint32) public provenCount;

    event ClaimProven(
        bytes32 indexed channelId, bytes32 indexed rootDigest, uint32 position, bytes32 commitment, bytes output
    );

    error NotThisGate();
    error RootSignatureInvalid();
    error PositionOutOfRange(uint32 position, uint32 count);
    error InclusionInvalid();
    error AlreadyProven(uint32 position);
    error ProofInvalid();
    error VerifierUnavailable(bytes32 verifierId);
    error ClaimExceedsProven(uint128 totalClaimed, uint256 ceiling);

    constructor(x402BatchSettlement settlement_, IVerifierRegistry registry_, address payee_)
        EIP712("x402 proof claim gate", "0")
    {
        settlement = settlement_;
        registry = registry_;
        payee = payee_;
    }

    /// @notice Claim a voucher for one more proven request of a signed batch. Anyone may call this.
    function claimWithProof(
        x402BatchSettlement.VoucherClaim calldata vc,
        RootTerms calldata r,
        bytes calldata rootSignature,
        Inclusion calldata inc,
        VerifierEntry calldata e,
        bytes calldata output,
        bytes calldata proof
    ) external {
        x402BatchSettlement.ChannelConfig calldata c = vc.voucher.channel;
        if (c.receiverAuthorizer != address(this) || c.receiver != address(this)) revert NotThisGate();
        bytes32 channelId = settlement.getChannelId(c);
        bytes32 rootDigest = rootDigestOf(channelId, r);
        address signer = c.payerAuthorizer != address(0) ? c.payerAuthorizer : c.payer;
        if (!SignatureChecker.isValidSignatureNow(signer, rootDigest, rootSignature)) revert RootSignatureInvalid();

        if (inc.position >= r.count) revert PositionOutOfRange(inc.position, r.count);
        if (!includes(r.root, r.count, inc)) revert InclusionInvalid();
        if (proven[rootDigest][inc.position]) revert AlreadyProven(inc.position);

        ProofStatus s = ProofCheck.checkOne(registry, r.verifierId, e, inc.commitment, output, proof);
        if (s == ProofStatus.Unverifiable) revert VerifierUnavailable(r.verifierId);
        if (s != ProofStatus.Valid) revert ProofInvalid();

        proven[rootDigest][inc.position] = true;
        uint32 n = ++provenCount[rootDigest];
        uint256 ceiling = uint256(r.baseClaimed) + uint256(n) * r.unitPrice;
        if (vc.totalClaimed > ceiling) revert ClaimExceedsProven(vc.totalClaimed, ceiling);

        x402BatchSettlement.VoucherClaim[] memory claims = new x402BatchSettlement.VoucherClaim[](1);
        claims[0] = vc;
        settlement.claim(claims);
        emit ClaimProven(channelId, rootDigest, inc.position, inc.commitment, output);
    }

    /// @notice Sweep what the channel contract owes this gate for `token` and forward it to the payee.
    function payout(address token) external {
        settlement.settle(address(this), token);
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) IERC20(token).safeTransfer(payee, balance);
    }

    // ── Views ───────────────────────────────────────────────────────────────────────────────────

    function rootDigestOf(bytes32 channelId, RootTerms calldata r) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    COMMITMENT_ROOT_TYPEHASH, channelId, r.verifierId, r.root, r.count, r.unitPrice, r.baseClaimed
                )
            )
        );
    }

    function leafHash(uint32 position, bytes32 commitment) public pure returns (bytes32) {
        return keccak256(abi.encode(LEAF_TAG, position, commitment));
    }

    /// @notice Whether `inc` opens `root` at its position, for a tree over `count` leaves.
    function includes(bytes32 root, uint32 count, Inclusion calldata inc) public pure returns (bool) {
        uint256 depth;
        while ((uint256(1) << depth) < count) depth++;
        if (inc.path.length != depth) return false;
        bytes32 node = leafHash(inc.position, inc.commitment);
        uint256 index = inc.position;
        for (uint256 i = 0; i < depth; i++) {
            bytes32 sibling = inc.path[i];
            node = index & 1 == 0
                ? keccak256(abi.encodePacked(node, sibling))
                : keccak256(abi.encodePacked(sibling, node));
            index >>= 1;
        }
        return node == root;
    }
}
