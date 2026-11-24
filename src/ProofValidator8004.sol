// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ClaimDigest} from "./ClaimDigest.sol";
import {IValidationRegistry} from "./IValidationRegistry.sol";
import {IVerifierRegistry, VerifierEntry} from "./IVerifierRegistry.sol";
import {ProofCheck, ProofStatus} from "./ProofCheck.sol";

/// @title ProofValidator8004
/// @notice An ERC-8004 validator that answers only what a proof establishes. An agent's owner or
/// operator opens a request in the Validation Registry naming this contract, with a request hash
/// from `requestHashOf`: it commits to the agent, a registry entry, an input commitment and the
/// hash of the output the agent claims. Anyone may then present a proof for that entry and input:
/// - a valid proof of the claimed output is answered 100, tag `zk-proof/passed`;
/// - a valid proof of a different output is answered 0, tag `zk-proof/contradicted`. Only this
///   writes 0: the circuit maps one input to one output, so the claim is shown to be false;
/// - a proof that does not verify, or a verifier that cannot be run, reverts and writes nothing.
/// No answer is ever written for a request nobody proves. The registry averages answers and has no
/// value for "could not check", so writing one would read as a verdict.
/// @dev The response hash is the claim's digest (`ClaimDigest`), the same value an ERC-8183 job
/// completed by `ProofEvaluator8183` records as its reason.
///
/// A proof does not name an agent: a valid "passed" says that the claimed output is what the circuit
/// gives for that input, not who computed it. Proofs are public, so any agent can obtain a "passed"
/// for any published proof.
///
/// No owner, no fee, no storage.
contract ProofValidator8004 {
    /// @notice ERC-712 type of the request hash.
    bytes32 public constant REQUEST_TYPEHASH = keccak256(
        "ProofValidationRequest(uint256 chainId,address validator,uint256 agentId,bytes32 verifierId,"
        "bytes32 inputCommitment,bytes32 claimedOutputHash,bytes32 salt)"
    );

    uint8 public constant PASSED = 100;
    uint8 public constant CONTRADICTED = 0;
    string public constant TAG_PASSED = "zk-proof/passed";
    string public constant TAG_CONTRADICTED = "zk-proof/contradicted";

    IVerifierRegistry public immutable registry;
    IValidationRegistry public immutable validationRegistry;

    /// @notice A valid proof answered a request. `response` is `PASSED` or `CONTRADICTED`.
    event Responded(bytes32 indexed requestHash, uint256 indexed agentId, uint8 response, bytes32 claimDigest);

    /// @notice The verifier ran and did not accept, or the output does not fit the entry.
    error ProofInvalid();
    /// @notice Unknown verifier, an entry that is not its registered entry, or code that is not the
    /// registered code.
    error VerifierUnavailable(bytes32 verifierId);
    /// @notice The request with this hash was opened for another agent than the one it commits to.
    error AgentMismatch(uint256 committed, uint256 recorded);

    constructor(IVerifierRegistry registry_, IValidationRegistry validationRegistry_) {
        registry = registry_;
        validationRegistry = validationRegistry_;
    }

    /// @notice The request hash an agent's owner uses to open a request with this validator:
    /// `keccak256(abi.encode(REQUEST_TYPEHASH, block.chainid, address(this), agentId, verifierId,
    /// inputCommitment, claimedOutputHash, salt))`, the ERC-712 struct hash of the request.
    function requestHashOf(
        uint256 agentId,
        bytes32 verifierId,
        bytes32 inputCommitment,
        bytes32 claimedOutputHash,
        bytes32 salt
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                REQUEST_TYPEHASH,
                block.chainid,
                address(this),
                agentId,
                verifierId,
                inputCommitment,
                claimedOutputHash,
                salt
            )
        );
    }

    /// @notice Answer a request with a proof. Anyone may call this. The request hash is recomputed
    /// from the arguments, so a proof can only answer the request it matches.
    /// @param e The registered entry of `verifierId`, checked against the registry's hash of it.
    /// @param output The circuit's public output, `e.outputSize` bytes.
    function respond(
        uint256 agentId,
        bytes32 verifierId,
        bytes32 inputCommitment,
        bytes32 claimedOutputHash,
        bytes32 salt,
        VerifierEntry calldata e,
        bytes calldata output,
        bytes calldata proof
    ) external {
        bytes32 requestHash = requestHashOf(agentId, verifierId, inputCommitment, claimedOutputHash, salt);

        // The registry keys requests by hash alone and records the agent its opener named. The
        // answer goes only to a request whose recorded agent is the agent this hash commits to.
        // Reverts if no request has this hash.
        (, uint256 recordedAgent,,,,) = validationRegistry.getValidationStatus(requestHash);
        if (recordedAgent != agentId) revert AgentMismatch(agentId, recordedAgent);

        ProofStatus status = ProofCheck.checkOne(registry, verifierId, e, inputCommitment, output, proof);
        if (status == ProofStatus.Unverifiable) revert VerifierUnavailable(verifierId);
        if (status != ProofStatus.Valid) revert ProofInvalid();

        bytes32 outputHash = keccak256(output);
        bytes32 digest = ClaimDigest.compute(verifierId, inputCommitment, outputHash);
        if (outputHash == claimedOutputHash) {
            validationRegistry.validationResponse(requestHash, PASSED, "", digest, TAG_PASSED);
            emit Responded(requestHash, agentId, PASSED, digest);
        } else {
            validationRegistry.validationResponse(requestHash, CONTRADICTED, "", digest, TAG_CONTRADICTED);
            emit Responded(requestHash, agentId, CONTRADICTED, digest);
        }
    }
}
