// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProofCoreBase} from "./ProofCoreBase.sol";
import {MockERC3009} from "./mocks/MockERC3009.sol";
import {AuthCaptureProofOperator} from "../src/AuthCaptureProofOperator.sol";
import {IAuthCaptureEscrow} from "../src/IAuthCaptureEscrow.sol";
// Imported so that Forge compiles them; they are placed with `deployCodeTo` below.
import {AuthCaptureEscrow} from "lib/commerce-payments/src/AuthCaptureEscrow.sol";
import {ERC3009PaymentCollector} from "lib/commerce-payments/src/collectors/ERC3009PaymentCollector.sol";

/// The escrow's payer-only exit, which the operator never calls.
interface IEscrowReclaim {
    function reclaim(IAuthCaptureEscrow.PaymentInfo calldata paymentInfo) external;
}

/// Shared setup for the `auth-capture` operator: x402's escrow and its ERC-3009 token collector built
/// from base/commerce-payments v1.1.0 (lib/commerce-payments) and placed at the canonical v1.1
/// addresses the x402 EVM binding names, on chain id 84532, so that a payment signed by x402's own
/// client for Base Sepolia is valid here. The token is the test token placed at the address of the
/// testnet's USDC, with the EIP-712 name "USD Coin" and version "2".
abstract contract AuthCaptureBase is ProofCoreBase {
    // From the x402 auth-capture EVM binding, "Commerce-payments deployments", v1.1.
    address internal constant ESCROW = 0xf96815976523E00e65Be8f34cA5e64b4f41EB19c;
    address internal constant COLLECTOR = 0x8612dfdc421f80336cd14E8EF9cb1E765dB5ab88;
    // Canonical Multicall3; the collector calls it only for ERC-6492 signatures.
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    address internal constant TOKEN = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    uint256 internal constant CHAIN_ID = 84532;

    uint256 internal constant T0 = 1_750_000_000;
    uint120 internal constant AMOUNT = 1_000_000; // 1 USDC
    uint48 internal constant PRE_APPROVAL_EXPIRY = uint48(T0 + 600);
    uint48 internal constant CAPTURE_DEADLINE = uint48(T0 + 3600);
    uint48 internal constant REFUND_DEADLINE = uint48(T0 + 86_400);

    bytes32 internal constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    IAuthCaptureEscrow internal escrow = IAuthCaptureEscrow(ESCROW);
    AuthCaptureProofOperator internal op;
    MockERC3009 internal token;

    address internal payer;
    uint256 internal payerKey;
    address internal receiver = makeAddr("receiver");
    address internal relayer = makeAddr("relayer");
    address internal feeRecipient = makeAddr("fee recipient");
    address internal stranger = makeAddr("stranger");

    bytes32 internal commitment; // the solo proof's input commitment
    bytes internal output; // its 320-byte output
    bytes internal proof;

    function setUp() public virtual override {
        super.setUp();
        vm.chainId(CHAIN_ID);
        vm.warp(T0);

        deployCodeTo("AuthCaptureEscrow.sol:AuthCaptureEscrow", ESCROW);
        deployCodeTo("ERC3009PaymentCollector.sol:ERC3009PaymentCollector", abi.encode(ESCROW, MULTICALL3), COLLECTOR);
        _placeToken();
        token = MockERC3009(TOKEN);
        op = new AuthCaptureProofOperator(escrow, registry);

        (payer, payerKey) = makeAddrAndKey("payer");
        _fund(payer, 10 * AMOUNT);

        bytes32[] memory c;
        (c, output, proof) = _solo();
        commitment = c[0];
    }

    /// The test token at the USDC address. A fork test keeps the real USDC instead.
    function _placeToken() internal virtual {
        deployCodeTo("MockERC3009.sol:MockERC3009", TOKEN);
    }

    function _fund(address to, uint256 amount) internal virtual {
        MockERC3009(TOKEN).mint(to, amount);
    }

    // ── Payments as an x402 auth-capture client builds them ─────────────────────────────────────

    function _terms(uint256 saltNonce) internal view returns (AuthCaptureProofOperator.Terms memory) {
        return AuthCaptureProofOperator.Terms({verifierId: soloId, inputCommitment: commitment, saltNonce: saltNonce});
    }

    /// The PaymentInfo for `t`, with the salt bound to the terms as a client derives it from
    /// `extra.receiverAuthorizer = op.termsAuthorizer(...)`, `extra.policy = 0` and its salt nonce.
    function _payment(AuthCaptureProofOperator.Terms memory t)
        internal
        view
        returns (IAuthCaptureEscrow.PaymentInfo memory p)
    {
        p = _paymentWithSalt(op.boundSalt(t.verifierId, t.inputCommitment, t.saltNonce));
    }

    function _paymentWithSalt(uint256 salt) internal view returns (IAuthCaptureEscrow.PaymentInfo memory) {
        return IAuthCaptureEscrow.PaymentInfo({
            operator: address(op),
            payer: payer,
            receiver: receiver,
            token: TOKEN,
            maxAmount: AMOUNT,
            preApprovalExpiry: PRE_APPROVAL_EXPIRY,
            authorizationExpiry: CAPTURE_DEADLINE,
            refundExpiry: REFUND_DEADLINE,
            minFeeBps: 0,
            maxFeeBps: 0,
            feeReceiver: address(0),
            salt: salt
        });
    }

    /// The ERC-3009 nonce: the escrow's hash of the payment with the payer set to zero.
    function _signatureNonce(IAuthCaptureEscrow.PaymentInfo memory p) internal view returns (bytes32) {
        IAuthCaptureEscrow.PaymentInfo memory q = p;
        address who = q.payer;
        q.payer = address(0);
        bytes32 nonce = escrow.getHash(q);
        q.payer = who;
        return nonce;
    }

    /// The payer's one signature: ReceiveWithAuthorization to the collector, for the maximum.
    function _sign(IAuthCaptureEscrow.PaymentInfo memory p, uint256 key) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_TYPEHASH, p.payer, COLLECTOR, p.maxAmount, 0, p.preApprovalExpiry, _signatureNonce(p))
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _authorize(IAuthCaptureEscrow.PaymentInfo memory p) internal {
        op.authorize(p, p.maxAmount, COLLECTOR, _sign(p, payerKey));
    }

    function _held(IAuthCaptureEscrow.PaymentInfo memory p)
        internal
        view
        returns (uint120 capturable, uint120 refundable)
    {
        (, capturable, refundable) = escrow.paymentState(escrow.getHash(p));
    }
}
