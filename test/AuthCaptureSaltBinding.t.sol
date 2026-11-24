// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AuthCaptureBase} from "./AuthCaptureBase.sol";
import {AuthCaptureProofOperator} from "../src/AuthCaptureProofOperator.sol";
import {IAuthCaptureEscrow} from "../src/IAuthCaptureEscrow.sol";

/// The binding first proposed for an operator: the client contributes the salt nonce as a hash of
/// the terms and a random value of its own, `saltNonce = keccak256(abi.encode(verifierId,
/// inputCommitment, clientRandom))`, inside the scheme's bound salt. The operator, given the terms and
/// `clientRandom`, recomputes both. Test-only: the operator that was built uses another binding.
contract SaltNonceTermsBinding {
    bytes32 internal constant SALT_BINDING_TYPEHASH =
        keccak256("x402AuthCaptureSaltBinding(address receiverAuthorizer,address policy,uint256 saltNonce)");

    function saltNonceFor(bytes32 verifierId, bytes32 inputCommitment, bytes32 clientRandom)
        public
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encode(verifierId, inputCommitment, clientRandom)));
    }

    function binds(
        IAuthCaptureEscrow.PaymentInfo calldata p,
        address receiverAuthorizer,
        bytes32 verifierId,
        bytes32 inputCommitment,
        bytes32 clientRandom
    ) external pure returns (bool) {
        uint256 nonce = saltNonceFor(verifierId, inputCommitment, clientRandom);
        return p.salt == uint256(keccak256(abi.encode(SALT_BINDING_TYPEHASH, receiverAuthorizer, address(0), nonce)));
    }
}

/// The salt-binding question against the real escrow (base/commerce-payments v1.1.0, from source).
/// What the escrow accepts is tested here, in CI. What x402's own client produces is tested against a
/// payment it signed, in `AuthCaptureStockClient.t.sol` (opt-in).
contract AuthCaptureSaltBindingTest is AuthCaptureBase {
    SaltNonceTermsBinding internal binding;
    address internal serverAuthorizer = makeAddr("the server's receiver authorizer");
    bytes32 internal constant CLIENT_RANDOM = keccak256("the client's own random value");

    function setUp() public override {
        super.setUp();
        binding = new SaltNonceTermsBinding();
    }

    function _salt(uint256 saltNonce) internal view returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(
                    keccak256(
                        "x402AuthCaptureSaltBinding(address receiverAuthorizer,address policy,uint256 saltNonce)"
                    ),
                    serverAuthorizer,
                    address(0),
                    saltNonce
                )
            )
        );
    }

    /// The first proposal fits the escrow: a salt built that way is accepted and held like any other,
    /// and an operator could recognise the terms in it. It needs a client that builds the salt nonce
    /// from the terms; x402's client draws it at random.
    function test_a_salt_nonce_derived_from_the_terms_fits_the_escrow() public {
        uint256 nonce = binding.saltNonceFor(soloId, commitment, CLIENT_RANDOM);
        IAuthCaptureEscrow.PaymentInfo memory p = _paymentWithSalt(_salt(nonce));
        _authorize(p);
        (uint120 capturable,) = _held(p);
        assertEq(capturable, AMOUNT, "the escrow holds it: it never interprets the salt");

        assertTrue(binding.binds(p, serverAuthorizer, soloId, commitment, CLIENT_RANDOM), "the terms are recognisable");
        assertFalse(
            binding.binds(p, serverAuthorizer, soloId, bytes32(uint256(commitment) ^ 1), CLIENT_RANDOM),
            "other terms are not"
        );
        assertFalse(
            binding.binds(p, serverAuthorizer, soloId, commitment, bytes32(0)), "without the client's value, nothing"
        );
    }

    /// With a random salt nonce, as x402's client sends it, that binding recognises nothing: the
    /// operator would need a preimage of the nonce. The binding through `receiverAuthorizer` is
    /// unaffected by the nonce being random, which is why it was built instead.
    function test_a_random_salt_nonce_defeats_that_binding_but_not_the_receiver_authorizer_one() public {
        uint256 randomNonce = uint256(keccak256("drawn at random by the client"));
        IAuthCaptureEscrow.PaymentInfo memory p = _paymentWithSalt(_salt(randomNonce));
        assertFalse(binding.binds(p, serverAuthorizer, soloId, commitment, CLIENT_RANDOM), "no client value matches");
        assertFalse(
            binding.binds(p, serverAuthorizer, soloId, commitment, bytes32(randomNonce)), "not even the nonce itself"
        );

        AuthCaptureProofOperator.Terms memory t = _terms(randomNonce);
        IAuthCaptureEscrow.PaymentInfo memory q = _payment(t);
        _authorize(q);
        op.captureWithProof(q, t, soloEntry, output, proof);
        assertEq(token.balanceOf(receiver), AMOUNT, "bound through receiverAuthorizer, captured with a random nonce");
    }
}
