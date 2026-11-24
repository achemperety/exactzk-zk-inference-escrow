// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StandardsBase} from "./StandardsBase.sol";
import {AgenticCommerce} from "./external/erc8183/AgenticCommerce.sol";
import {ValidationRegistryUpgradeable} from "lib/erc-8004-contracts/contracts/ValidationRegistryUpgradeable.sol";
import {FixturesK8} from "./fixtures/FixturesK8.sol";
import {ProofValidator8004} from "../src/ProofValidator8004.sol";
import {IValidationRegistry} from "../src/IValidationRegistry.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";

/// `ProofValidator8004` against the ERC-8004 reference Identity and Validation registries
/// (erc-8004/erc-8004-contracts, built from source; test/external/README.md), with the real solo
/// proof throughout.
contract ProofValidator8004Test is StandardsBase {
    uint256 internal otherAgent; // registered first: agent 0
    uint256 internal agentId; // agent 1
    bytes32 internal outputHash;
    bytes32 internal wrongHash = keccak256("an output the circuit does not give for this input");
    uint256 internal requestedAt;

    function setUp() public override {
        super.setUp();
        otherAgent = _agent(otherOwner);
        agentId = _agent(agentOwner);
        outputHash = keccak256(output);
    }

    function _validators() internal view returns (address[] memory v) {
        v = new address[](1);
        v[0] = address(validator);
    }

    function _summary(string memory tag) internal view returns (uint64 count, uint8 average) {
        return validation.getSummary(agentId, _validators(), tag);
    }

    /// The registry's record of a request that has not been answered: no response hash, no tag,
    /// and the time of the request.
    function _assertUnanswered(bytes32 h) internal view {
        (address v, uint256 a, uint8 r, bytes32 rh, string memory tag, uint256 t) = validation.getValidationStatus(h);
        assertEq(v, address(validator), "validator");
        assertEq(a, agentId, "agent");
        assertEq(r, 0, "response");
        assertEq(rh, bytes32(0), "response hash");
        assertEq(tag, "", "tag");
        assertEq(t, requestedAt, "last update is the request");
    }

    function _openAt(bytes32 claimed, bytes32 salt) internal returns (bytes32 h) {
        requestedAt = block.timestamp;
        h = _request(agentOwner, agentId, claimed, salt);
        vm.warp(block.timestamp + 60); // so that any write would move lastUpdate
    }

    // ── Identity ────────────────────────────────────────────────────────────────────────────────

    function test_agents_are_identity_registry_tokens() public view {
        assertEq(otherAgent, 0, "the registry numbers agents from 0");
        assertEq(agentId, 1, "second agent");
        assertEq(identity.ownerOf(agentId), agentOwner, "owner");
        assertEq(validation.getIdentityRegistry(), address(identity), "validation registry points to identity");
    }

    // ── Acceptance: 100 on a match ──────────────────────────────────────────────────────────────

    function test_a_valid_proof_of_the_claimed_output_is_answered_100() public {
        bytes32 h = _openAt(outputHash, "a");
        bytes32 digest = _digest(soloId, commitment, output);

        vm.expectEmit(address(validation));
        emit ValidationRegistryUpgradeable.ValidationResponse(
            address(validator), agentId, h, 100, "", digest, "zk-proof/passed"
        );
        vm.expectEmit(address(validator));
        emit ProofValidator8004.Responded(h, agentId, 100, digest);
        vm.prank(stranger);
        _respond(agentId, outputHash, "a");

        (address v, uint256 a, uint8 r, bytes32 rh, string memory tag, uint256 t) = validation.getValidationStatus(h);
        assertEq(v, address(validator), "validator");
        assertEq(a, agentId, "agent");
        assertEq(r, 100, "response");
        assertEq(rh, digest, "response hash is the claim digest");
        assertEq(tag, "zk-proof/passed", "tag");
        assertEq(t, block.timestamp, "last update");
        (uint64 count, uint8 average) = _summary("");
        assertEq(count, 1, "count");
        assertEq(average, 100, "average");
    }

    // ── Acceptance: 0 only on a contradiction ───────────────────────────────────────────────────

    function test_a_valid_proof_of_another_output_is_answered_0() public {
        bytes32 h = _openAt(wrongHash, "b");
        bytes32 digest = _digest(soloId, commitment, output); // the claim the proof establishes

        vm.expectEmit(address(validation));
        emit ValidationRegistryUpgradeable.ValidationResponse(
            address(validator), agentId, h, 0, "", digest, "zk-proof/contradicted"
        );
        vm.expectEmit(address(validator));
        emit ProofValidator8004.Responded(h, agentId, 0, digest);
        _respond(agentId, wrongHash, "b");

        (,, uint8 r, bytes32 rh, string memory tag, uint256 t) = validation.getValidationStatus(h);
        assertEq(r, 0, "response");
        assertEq(rh, digest, "response hash: the digest of what the proof shows");
        assertEq(tag, "zk-proof/contradicted", "tag");
        assertEq(t, block.timestamp, "written");
    }

    // ── Acceptance: nothing written otherwise ───────────────────────────────────────────────────

    function test_an_invalid_proof_writes_nothing_whatever_the_claim() public {
        bytes32[2] memory claims = [outputHash, wrongHash];
        for (uint256 i = 0; i < 2; i++) {
            bytes32 salt = bytes32(i);
            bytes32 h = _openAt(claims[i], salt);

            bytes memory bad = bytes.concat(proof);
            bad[100] = bytes1(uint8(bad[100]) ^ 0x01);
            vm.expectRevert(ProofValidator8004.ProofInvalid.selector);
            validator.respond(agentId, soloId, commitment, claims[i], salt, soloEntry, output, bad);

            bytes memory other = bytes.concat(output);
            _setWord(other, 0, _word(other, 0) + 1);
            vm.expectRevert(ProofValidator8004.ProofInvalid.selector);
            validator.respond(agentId, soloId, commitment, claims[i], salt, soloEntry, other, proof);

            vm.expectRevert(ProofValidator8004.ProofInvalid.selector);
            validator.respond(agentId, soloId, commitment, claims[i], salt, soloEntry, output, "");

            _assertUnanswered(h);
        }
        (uint64 count,) = _summary("");
        assertEq(count, 0, "nothing counted");
    }

    function test_a_check_that_cannot_run_writes_nothing() public {
        // Unknown verifier.
        bytes32 unknown = keccak256("no such verifier");
        bytes32 hUnknown = validator.requestHashOf(agentId, unknown, commitment, outputHash, "u");
        requestedAt = block.timestamp;
        vm.prank(agentOwner);
        validation.validationRequest(address(validator), agentId, "ipfs://request", hUnknown);
        vm.expectRevert(abi.encodeWithSelector(ProofValidator8004.VerifierUnavailable.selector, unknown));
        validator.respond(agentId, unknown, commitment, outputHash, "u", soloEntry, output, proof);
        _assertUnanswered(hUnknown);

        // A known verifier with an entry that is not its registered entry.
        bytes32 h = _openAt(outputHash, "c");
        VerifierEntry memory e = soloEntry;
        e.verifyGas += 1;
        vm.expectRevert(abi.encodeWithSelector(ProofValidator8004.VerifierUnavailable.selector, soloId));
        validator.respond(agentId, soloId, commitment, outputHash, "c", e, output, proof);

        // A known verifier whose code changed.
        vm.etch(SOLO, FixturesK8.verifierBytecode());
        vm.expectRevert(abi.encodeWithSelector(ProofValidator8004.VerifierUnavailable.selector, soloId));
        _respond(agentId, outputHash, "c");
        _assertUnanswered(h);

        (uint64 count,) = _summary("");
        assertEq(count, 0, "nothing counted");
    }

    // ── Acceptance: the registry's caller rules ─────────────────────────────────────────────────

    function test_a_request_opened_by_anyone_but_the_owner_or_an_operator_is_rejected_by_the_registry() public {
        bytes32 h = validator.requestHashOf(agentId, soloId, commitment, outputHash, "d");
        address[4] memory others = [stranger, otherOwner, address(validator), address(this)];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(bytes("Not authorized"));
            validation.validationRequest(address(validator), agentId, "ipfs://request", h);
        }

        // The ERC: "MUST be called by the owner or operator of agentId".
        vm.prank(agentOwner);
        identity.setApprovalForAll(relayer, true);
        vm.prank(relayer);
        validation.validationRequest(address(validator), agentId, "ipfs://request", h);

        bytes32 h2 = validator.requestHashOf(agentId, soloId, commitment, outputHash, "e");
        vm.prank(agentOwner);
        identity.approve(stranger, agentId);
        vm.prank(stranger);
        validation.validationRequest(address(validator), agentId, "ipfs://request", h2);

        _respond(agentId, outputHash, "d");
        _respond(agentId, outputHash, "e");
        (uint64 count, uint8 average) = _summary("");
        assertEq(count, 2, "both answered");
        assertEq(average, 100, "average");
    }

    function test_a_request_for_an_agent_that_does_not_exist_is_rejected_by_the_registry() public {
        bytes32 h = validator.requestHashOf(99, soloId, commitment, outputHash, "f");
        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", 99));
        validation.validationRequest(address(validator), 99, "ipfs://request", h);
    }

    function test_a_request_naming_another_validator_is_not_answered_by_this_one() public {
        bytes32 h = validator.requestHashOf(agentId, soloId, commitment, outputHash, "g");
        vm.prank(agentOwner);
        validation.validationRequest(stranger, agentId, "ipfs://request", h);
        vm.expectRevert(bytes("not validator"));
        _respond(agentId, outputHash, "g");
    }

    // ── The request hash ────────────────────────────────────────────────────────────────────────

    function test_the_request_hash_is_the_typed_hash_of_the_request() public {
        bytes32 typehash = keccak256(
            "ProofValidationRequest(uint256 chainId,address validator,uint256 agentId,bytes32 verifierId,"
            "bytes32 inputCommitment,bytes32 claimedOutputHash,bytes32 salt)"
        );
        assertEq(validator.REQUEST_TYPEHASH(), typehash, "typehash");
        bytes32 expected = keccak256(
            abi.encode(
                typehash, block.chainid, address(validator), agentId, soloId, commitment, outputHash, bytes32("h")
            )
        );
        assertEq(validator.requestHashOf(agentId, soloId, commitment, outputHash, "h"), expected, "hash");

        ProofValidator8004 twin = new ProofValidator8004(registry, IValidationRegistry(address(validation)));
        assertTrue(
            twin.requestHashOf(agentId, soloId, commitment, outputHash, "h") != expected, "bound to the validator"
        );
        vm.chainId(8453);
        assertTrue(
            validator.requestHashOf(agentId, soloId, commitment, outputHash, "h") != expected, "bound to the chain"
        );
    }

    function test_respond_without_an_open_request_reverts() public {
        vm.expectRevert(bytes("unknown"));
        _respond(agentId, outputHash, "never opened");
    }

    function test_every_argument_is_part_of_the_request_hash() public {
        bytes32 h = _openAt(outputHash, "i");
        // Each call changes one argument; the recomputed hash names no open request.
        vm.expectRevert(bytes("unknown"));
        validator.respond(agentId, soloId, commitment, outputHash, "j", soloEntry, output, proof);
        vm.expectRevert(bytes("unknown"));
        validator.respond(otherAgent, soloId, commitment, outputHash, "i", soloEntry, output, proof);
        vm.expectRevert(bytes("unknown"));
        validator.respond(agentId, k8Id, commitment, outputHash, "i", soloEntry, output, proof);
        vm.expectRevert(bytes("unknown"));
        validator.respond(agentId, soloId, bytes32(uint256(commitment) ^ 1), outputHash, "i", soloEntry, output, proof);
        vm.expectRevert(bytes("unknown"));
        validator.respond(agentId, soloId, commitment, wrongHash, "i", soloEntry, output, proof);
        _assertUnanswered(h);

        _respond(agentId, outputHash, "i");
        (,, uint8 r,,,) = validation.getValidationStatus(h);
        assertEq(r, 100, "the matching arguments answer it");
    }

    function test_a_request_recorded_for_another_agent_is_not_answered() public {
        // The registry has recorded another agent for a hash that commits to this one.
        bytes32 h = validator.requestHashOf(agentId, soloId, commitment, outputHash, "k");
        vm.prank(otherOwner);
        validation.validationRequest(address(validator), otherAgent, "ipfs://request", h);

        vm.expectRevert(abi.encodeWithSelector(ProofValidator8004.AgentMismatch.selector, agentId, otherAgent));
        _respond(agentId, outputHash, "k");
        (uint64 count,) = validation.getSummary(otherAgent, _validators(), "");
        assertEq(count, 0, "no answer is recorded for the other agent");
    }

    // ── Acceptance: the summary over our answers ────────────────────────────────────────────────

    function test_the_summary_is_pulled_down_only_by_a_proven_contradiction() public {
        _openAt(outputHash, "passed");
        _respond(agentId, outputHash, "passed");

        // Could not check (the entry given is not the registered one): reverts, nothing is written.
        _openAt(outputHash, "could not check");
        VerifierEntry memory e = soloEntry;
        e.verifyGas += 1;
        vm.expectRevert(abi.encodeWithSelector(ProofValidator8004.VerifierUnavailable.selector, soloId));
        validator.respond(agentId, soloId, commitment, outputHash, "could not check", e, output, proof);

        // An invalid proof against a false claim: still nothing.
        _openAt(wrongHash, "invalid");
        vm.expectRevert(ProofValidator8004.ProofInvalid.selector);
        validator.respond(agentId, soloId, commitment, wrongHash, "invalid", soloEntry, output, new bytes(proof.length));

        // No answer: nobody ever responds.
        _openAt(outputHash, "no answer");
        vm.warp(block.timestamp + 365 days);

        (uint64 count, uint8 average) = _summary("");
        assertEq(count, 1, "only the proven answer counts");
        assertEq(average, 100, "not pulled down");
        (count, average) = validation.getSummary(agentId, new address[](0), "");
        assertEq(count, 1, "no validator filter");
        assertEq(average, 100, "no validator filter");
        (count, average) = _summary("zk-proof/passed");
        assertEq(count, 1, "tag filter");
        assertEq(validation.getAgentValidations(agentId).length, 4, "four requests open");

        // A proven contradiction is the only thing that lowers it.
        _openAt(wrongHash, "contradicted");
        _respond(agentId, wrongHash, "contradicted");
        (count, average) = _summary("");
        assertEq(count, 2, "count");
        assertEq(average, 50, "average");
        (count, average) = _summary("zk-proof/contradicted");
        assertEq(count, 1, "contradictions");
        assertEq(average, 0, "contradictions average");
    }

    function test_a_summary_filtered_to_this_validator_ignores_other_validators() public {
        _openAt(outputHash, "ours");
        _respond(agentId, outputHash, "ours");

        // The agent's owner also asks someone else, who answers 0 with no proof at all.
        address other = makeAddr("other validator");
        bytes32 h = keccak256("a request to another validator");
        vm.prank(agentOwner);
        validation.validationRequest(other, agentId, "ipfs://other", h);
        vm.prank(other);
        validation.validationResponse(h, 0, "", bytes32(0), "zk-proof/passed");

        (uint64 count, uint8 average) = _summary("");
        assertEq(count, 1, "only this validator's answers");
        assertEq(average, 100, "unaffected by the other validator");
        (count, average) = validation.getSummary(agentId, new address[](0), "zk-proof/passed");
        assertEq(count, 2, "unfiltered, a tag is no protection: anyone can use it");
        assertEq(average, 50, "unfiltered average");
    }

    function test_respond_is_open_to_anyone_and_repeatable() public {
        bytes32 h = _openAt(outputHash, "l");
        vm.prank(stranger);
        _respond(agentId, outputHash, "l");
        vm.warp(block.timestamp + 1);
        vm.prank(relayer);
        _respond(agentId, outputHash, "l");

        (,, uint8 r,,, uint256 t) = validation.getValidationStatus(h);
        assertEq(r, 100, "same answer");
        assertEq(t, block.timestamp, "rewritten");
        (uint64 count,) = _summary("");
        assertEq(count, 1, "one request, counted once");
    }

    // ── One claim, one digest ───────────────────────────────────────────────────────────────────

    function test_the_evaluator_and_the_validator_record_the_same_digest_for_one_claim() public {
        uint256 jobId = _submittedJob();
        bytes32 digest = _digest(soloId, commitment, output);
        vm.expectEmit(address(acp));
        emit AgenticCommerce.JobCompleted(jobId, address(evaluator), digest);
        evaluator.evaluate(address(acp), jobId, soloEntry, output, proof);

        bytes32 h = _openAt(outputHash, "m");
        _respond(agentId, outputHash, "m");
        (,,, bytes32 rh,,) = validation.getValidationStatus(h);
        assertEq(rh, digest, "same digest");
    }
}
