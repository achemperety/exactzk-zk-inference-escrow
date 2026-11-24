// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AuthCaptureBase} from "./AuthCaptureBase.sol";
import {IAuthCaptureEscrow} from "../src/IAuthCaptureEscrow.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";
import {PolicyCaptureOperator} from "../src/PolicyCaptureOperator.sol";
import {ProofCapturePolicy} from "../src/ProofCapturePolicy.sol";

/// Shared setup for the reason-returning proof policy on the `"custom"` route: x402's escrow and
/// collector built from base/commerce-payments v1.1.0 at the canonical addresses (`AuthCaptureBase`),
/// `ProofCapturePolicy` and a `PolicyCaptureOperator` fixed to it.
///
/// A payment is bound as the `"custom"` type binds it: `extra.policy` zero, a non-zero
/// `extra.receiverAuthorizer` (the server's, not derived from the terms), and the client's salt nonce
/// derived from the terms.
abstract contract ProofCapturePolicyBase is AuthCaptureBase {
    ProofCapturePolicy internal policy;
    PolicyCaptureOperator internal pop;
    address internal serverAuthorizer = makeAddr("the server's receiver authorizer");

    function setUp() public virtual override {
        super.setUp();
        policy = new ProofCapturePolicy(registry);
        pop = new PolicyCaptureOperator(escrow, policy);
    }

    function _proofData(
        address authorizer,
        address boundPolicy,
        bytes32 verifierId,
        bytes32 inputCommitment,
        VerifierEntry memory e,
        bytes memory out,
        bytes memory prf
    ) internal pure returns (bytes memory) {
        return abi.encode(
            ProofCapturePolicy.ProofData({
                receiverAuthorizer: authorizer,
                policy: boundPolicy,
                verifierId: verifierId,
                inputCommitment: inputCommitment,
                entry: e,
                output: out,
                proof: prf
            })
        );
    }

    /// The real solo proof for the payment bound with `authorizer` on the `"custom"` route.
    function _goodData(address authorizer) internal view returns (bytes memory) {
        return _proofData(authorizer, address(0), soloId, commitment, soloEntry, output, proof);
    }

    function _goodData() internal view returns (bytes memory) {
        return _goodData(serverAuthorizer);
    }

    /// A payment to `pop` whose salt binds these terms, as a proof-aware client derives it.
    function _policyPayment(address authorizer, address boundPolicy, bytes32 verifierId, bytes32 inputCommitment)
        internal
        view
        returns (IAuthCaptureEscrow.PaymentInfo memory p)
    {
        p = _paymentWithSalt(policy.boundSalt(authorizer, boundPolicy, verifierId, inputCommitment));
        p.operator = address(pop);
    }

    function _policyPayment() internal view returns (IAuthCaptureEscrow.PaymentInfo memory) {
        return _policyPayment(serverAuthorizer, address(0), soloId, commitment);
    }

    function _policyAuthorize(IAuthCaptureEscrow.PaymentInfo memory p) internal {
        pop.authorize(p, p.maxAmount, COLLECTOR, _sign(p, payerKey));
    }
}
