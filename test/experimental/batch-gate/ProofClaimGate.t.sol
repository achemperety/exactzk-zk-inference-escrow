// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProofCoreBase} from "../../ProofCoreBase.sol";
import {GasMeter} from "../../GasMeter.sol";
import {FixturesK8} from "../../fixtures/FixturesK8.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {x402BatchSettlement} from "../../external/x402/src/x402BatchSettlement.sol";
import {VerifierEntry} from "../../../src/IVerifierRegistry.sol";
import {ProofClaimGate} from "./ProofClaimGate.sol";

/// Pulls an approved deposit from the payer into the channel contract. Test-only.
contract PullCollector {
    function collect(address payer, address token, uint256 amount, bytes32, bytes calldata) external {
        require(IERC20(token).transferFrom(payer, msg.sender, amount), "pull failed");
    }
}

/// PROTOTYPE: the batch-settlement claim condition, against x402's own channel contract
/// (`x402BatchSettlement`, copied unchanged from x402-foundation/x402, built here), with the real solo
/// proof as the request a claim gates.
contract ProofClaimGateTest is ProofCoreBase, GasMeter {
    uint128 internal constant UNIT = 10_000; // 0.01 of a six-decimal token per request
    uint40 internal constant WITHDRAW_DELAY = 15 minutes;

    x402BatchSettlement internal settlement;
    ProofClaimGate internal gate;
    PullCollector internal collector;
    MockERC20 internal token;

    address internal payer;
    uint256 internal payerKey;
    address internal payee = makeAddr("payee"); // the committed payee of the request the real proof covers
    address internal payee0 = makeAddr("payee 0");
    address internal payee2 = makeAddr("payee 2");
    address internal stranger = makeAddr("stranger");

    bytes32 internal solo; // the real proof's input commitment
    bytes internal output;
    bytes internal proof;

    x402BatchSettlement.ChannelConfig internal config;
    bytes32 internal channelId;
    bytes32[] internal batch; // the ordered input commitments of one batch
    address[] internal payees; // and each request's committed payee
    ProofClaimGate.RootTerms internal terms;

    function setUp() public override {
        super.setUp();
        settlement = new x402BatchSettlement();
        gate = new ProofClaimGate(settlement, registry);
        collector = new PullCollector();
        token = new MockERC20();
        (payer, payerKey) = makeAddrAndKey("payer");

        bytes32[] memory c;
        (c, output, proof) = _solo();
        solo = c[0];

        config = x402BatchSettlement.ChannelConfig({
            payer: payer,
            payerAuthorizer: address(0),
            receiver: address(gate),
            receiverAuthorizer: address(gate),
            token: address(token),
            withdrawDelay: WITHDRAW_DELAY,
            salt: bytes32(0)
        });
        channelId = settlement.getChannelId(config);
        _deposit(config, 3 * UNIT);

        // Three requests, each for its own payee; the real proof's commitment is the second.
        _request(keccak256("request 0"), payee0);
        _request(solo, payee);
        _request(keccak256("request 2"), payee2);
        _signTerms(0);
    }

    function _request(bytes32 commitment, address to) internal {
        batch.push(commitment);
        payees.push(to);
    }

    function _signTerms(uint128 baseClaimed) internal {
        terms = ProofClaimGate.RootTerms({
            verifierId: soloId,
            root: _root(batch, payees),
            count: uint32(batch.length),
            unitPrice: UNIT,
            baseClaimed: baseClaimed
        });
    }

    // ── Client side: deposit, root, voucher ─────────────────────────────────────────────────────

    function _deposit(x402BatchSettlement.ChannelConfig memory cfg, uint128 amount) internal {
        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(collector), amount);
        settlement.deposit(cfg, amount, address(collector), "");
    }

    function _signDigest(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// The gate's EIP-712 digest, derived here independently of the gate.
    function _rootDigest(address g, bytes32 cid, ProofClaimGate.RootTerms memory r) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("x402 proof claim gate"),
                keccak256("0"),
                block.chainid,
                g
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "CommitmentRoot(bytes32 channelId,bytes32 verifierId,bytes32 root,uint32 count,uint128 unitPrice,uint128 baseClaimed)"
                ),
                cid,
                r.verifierId,
                r.root,
                r.count,
                r.unitPrice,
                r.baseClaimed
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _rootSig(bytes32 cid, ProofClaimGate.RootTerms memory r, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        return _signDigest(key, _rootDigest(address(gate), cid, r));
    }

    /// Leaf `i`, derived here independently of the gate.
    function _leaf(uint256 position, bytes32 commitment, address to) internal pure returns (bytes32) {
        return keccak256(abi.encode(keccak256("x402.proof-claim-gate.leaf.v1"), position, commitment, to));
    }

    function _voucher(x402BatchSettlement.ChannelConfig memory cfg, uint128 maxClaimable, uint128 totalClaimed)
        internal
        view
        returns (x402BatchSettlement.VoucherClaim memory vc)
    {
        vc.voucher = x402BatchSettlement.Voucher({channel: cfg, maxClaimableAmount: maxClaimable});
        vc.signature = _signDigest(payerKey, settlement.getVoucherDigest(settlement.getChannelId(cfg), maxClaimable));
        vc.totalClaimed = totalClaimed;
    }

    // ── The tree, as a client builds it ─────────────────────────────────────────────────────────

    function _level(bytes32[] memory commitments, address[] memory to) internal pure returns (bytes32[] memory nodes) {
        uint256 width = 1;
        while (width < commitments.length) width <<= 1;
        nodes = new bytes32[](width); // padding leaves stay zero
        for (uint256 i = 0; i < commitments.length; i++) {
            nodes[i] = _leaf(i, commitments[i], to[i]);
        }
    }

    function _up(bytes32[] memory nodes) internal pure returns (bytes32[] memory parent) {
        parent = new bytes32[](nodes.length / 2);
        for (uint256 i = 0; i < parent.length; i++) {
            parent[i] = keccak256(abi.encodePacked(nodes[2 * i], nodes[2 * i + 1]));
        }
    }

    function _root(bytes32[] memory commitments, address[] memory to) internal pure returns (bytes32) {
        bytes32[] memory nodes = _level(commitments, to);
        while (nodes.length > 1) nodes = _up(nodes);
        return nodes[0];
    }

    function _path(bytes32[] memory commitments, address[] memory to, uint256 position)
        internal
        pure
        returns (bytes32[] memory path)
    {
        bytes32[] memory nodes = _level(commitments, to);
        uint256 depth;
        while ((uint256(1) << depth) < nodes.length) depth++;
        path = new bytes32[](depth);
        for (uint256 j = 0; j < depth; j++) {
            path[j] = nodes[position ^ 1];
            nodes = _up(nodes);
            position >>= 1;
        }
    }

    /// What a presenter sends for one request: the signed leaf, and where it sits.
    struct Request {
        ProofClaimGate.Leaf leaf;
        ProofClaimGate.Inclusion inc;
    }

    /// `commitment` presented at `position`, with the payee and the path of the request at `pathOf`.
    function _inclusion(uint32 position, bytes32 commitment, uint256 pathOf) internal view returns (Request memory) {
        return Request({
            leaf: ProofClaimGate.Leaf({inputCommitment: commitment, payee: payees[pathOf]}),
            inc: ProofClaimGate.Inclusion({position: position, path: _path(batch, payees, pathOf)})
        });
    }

    function _includes(bytes32 root, uint32 count, Request memory q) internal view returns (bool) {
        return gate.includes(root, count, q.leaf, q.inc);
    }

    function _claim(x402BatchSettlement.VoucherClaim memory vc, Request memory q) internal {
        gate.claimWithProof(vc, terms, _rootSig(channelId, terms, payerKey), q.leaf, q.inc, soloEntry, output, proof);
    }

    function _claimed() internal view returns (uint128 totalClaimed) {
        (, totalClaimed) = settlement.channels(channelId);
    }

    /// Nothing stays with the gate: no tokens, and nothing the channel contract still owes it.
    function _gateHoldsNothing() internal view {
        assertEq(token.balanceOf(address(gate)), 0, "the gate holds no tokens");
        (uint128 owed, uint128 settled) = settlement.receivers(address(gate), address(token));
        assertEq(owed, settled, "the channel contract owes the gate nothing");
    }

    function _flip(bytes memory data, uint256 index) internal pure returns (bytes memory c) {
        c = bytes.concat(data);
        c[index] = bytes1(uint8(c[index]) ^ 0x01);
    }

    // ── (a) Anyone may present a proof; the committed payee is paid ─────────────────────────────

    function test_a_proof_presented_by_a_third_party_pays_the_committed_payee() public {
        x402BatchSettlement.VoucherClaim memory vc = _voucher(config, 2 * UNIT, UNIT);
        Request memory inc = _inclusion(1, solo, 1);
        bytes32 digest = gate.rootDigestOf(channelId, terms);
        assertEq(digest, _rootDigest(address(gate), channelId, terms), "the gate's digest is the EIP-712 one");
        assertEq(gate.leafHash(1, ProofClaimGate.Leaf(solo, payee)), _leaf(1, solo, payee), "the gate's leaf");

        vm.expectEmit(address(gate));
        emit ProofClaimGate.ClaimProven(channelId, digest, 1, solo, payee, output);
        vm.prank(stranger); // neither the payer, nor a payee, nor the gate
        _claim(vc, inc);

        assertEq(_claimed(), UNIT, "one request claimed");
        assertTrue(gate.proven(digest, 1), "position 1 proven");
        assertEq(gate.provenCount(digest), 1, "count");
        assertEq(token.balanceOf(payee), UNIT, "the committed payee is paid, in the same call");
        assertEq(token.balanceOf(stranger), 0, "the caller gets nothing");
        assertEq(token.balanceOf(payee0) + token.balanceOf(payee2), 0, "the batch's other payees get nothing");
        _gateHoldsNothing();
    }

    function test_any_caller_presenting_the_same_proof_pays_the_same_payee() public {
        address[4] memory callers = [stranger, payer, payee0, address(this)];
        for (uint256 i = 0; i < callers.length; i++) {
            uint256 snap = vm.snapshotState();
            vm.prank(callers[i]);
            _claim(_voucher(config, 2 * UNIT, UNIT), _inclusion(1, solo, 1));
            assertEq(token.balanceOf(payee), UNIT, "the committed payee is paid");
            assertEq(token.balanceOf(callers[i]), 0, "the caller is not");
            _gateHoldsNothing();
            vm.revertToState(snap);
        }
    }

    // ── (b) A claim cannot send the unit anywhere else ──────────────────────────────────────────

    /// The claim has no payout argument; the only payee in it is the signed leaf's. A presenter who
    /// alters that payee presents a leaf the payer did not sign.
    function test_a_presenter_cannot_name_the_payout() public {
        x402BatchSettlement.VoucherClaim memory vc = _voucher(config, 2 * UNIT, UNIT);
        address[7] memory others = [stranger, payer, payee0, payee2, address(gate), address(settlement), address(0)];
        for (uint256 i = 0; i < others.length; i++) {
            Request memory inc = _inclusion(1, solo, 1);
            inc.leaf.payee = others[i];
            vm.prank(others[i] == address(0) ? stranger : others[i]);
            vm.expectRevert(ProofClaimGate.InclusionInvalid.selector);
            _claim(vc, inc);
        }
        assertEq(_claimed(), 0, "nothing claimed");
        assertEq(token.balanceOf(payee), 0, "nothing paid");
    }

    function testFuzz_a_presenter_cannot_name_the_payout(address other) public view {
        vm.assume(other != payee);
        Request memory inc = _inclusion(1, solo, 1);
        assertTrue(gate.includes(terms.root, terms.count, inc.leaf, inc.inc), "the committed payee opens it");
        inc.leaf.payee = other;
        assertFalse(gate.includes(terms.root, terms.count, inc.leaf, inc.inc), "no other payee does");
    }

    /// Two requests with the same commitment, for two payees. A claim that moved less than one unit
    /// for the first would leave that unit for the second request's claim to collect.
    function test_a_claim_cannot_shift_a_unit_from_one_payee_to_another() public {
        delete batch;
        delete payees;
        _request(solo, payee0);
        _request(solo, payee);
        _signTerms(0);

        // Under-claiming the first request: refused, so its unit cannot move to the second.
        x402BatchSettlement.VoucherClaim memory none = _voucher(config, 2 * UNIT, 0);
        x402BatchSettlement.VoucherClaim memory half = _voucher(config, 2 * UNIT, UNIT / 2);
        Request memory first = _inclusion(0, solo, 0);
        bytes memory sig = _rootSig(channelId, terms, payerKey);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ProofClaimGate.ClaimNotOneUnit.selector, 0, UNIT));
        gate.claimWithProof(none, terms, sig, first.leaf, first.inc, soloEntry, output, proof);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ProofClaimGate.ClaimNotOneUnit.selector, UNIT / 2, UNIT));
        gate.claimWithProof(half, terms, sig, first.leaf, first.inc, soloEntry, output, proof);

        vm.prank(stranger);
        _claim(_voucher(config, 2 * UNIT, UNIT), _inclusion(0, solo, 0));
        vm.prank(stranger);
        _claim(_voucher(config, 2 * UNIT, 2 * UNIT), _inclusion(1, solo, 1));

        assertEq(token.balanceOf(payee0), UNIT, "the first payee, one unit");
        assertEq(token.balanceOf(payee), UNIT, "the second payee, one unit");
        assertEq(token.balanceOf(stranger), 0, "the caller, nothing");
        _gateHoldsNothing();
    }

    /// A root whose base overstates what was claimed before it raises the ceiling, but one proof
    /// still moves one unit to its payee and no more.
    function test_a_claim_cannot_take_more_than_one_unit_for_its_payee() public {
        _claim(_voucher(config, 3 * UNIT, UNIT), _inclusion(1, solo, 1)); // an earlier batch: one unit
        delete batch;
        delete payees;
        _request(solo, payee0);
        _request(solo, payee2);
        _signTerms(2 * UNIT); // overstated: the ceiling alone would let one proof take two units
        x402BatchSettlement.VoucherClaim memory two = _voucher(config, 3 * UNIT, 3 * UNIT);
        Request memory inc = _inclusion(0, solo, 0);
        bytes memory sig = _rootSig(channelId, terms, payerKey);
        vm.expectRevert(abi.encodeWithSelector(ProofClaimGate.ClaimNotOneUnit.selector, 3 * UNIT, 2 * UNIT));
        gate.claimWithProof(two, terms, sig, inc.leaf, inc.inc, soloEntry, output, proof);
        assertEq(token.balanceOf(payee0), 0, "nothing paid");
        assertEq(_claimed(), UNIT, "nothing more claimed");
    }

    // ── A wrong position is refused ─────────────────────────────────────────────────────────────

    function test_a_commitment_claimed_at_a_position_it_does_not_hold_is_refused() public {
        x402BatchSettlement.VoucherClaim memory vc = _voucher(config, 2 * UNIT, UNIT);
        // The real proof's commitment, presented at positions 0 and 2 with its own path, and with the
        // path of the position claimed.
        uint32[2] memory wrong = [uint32(0), 2];
        for (uint256 i = 0; i < wrong.length; i++) {
            vm.expectRevert(ProofClaimGate.InclusionInvalid.selector);
            _claim(vc, _inclusion(wrong[i], solo, 1));
            vm.expectRevert(ProofClaimGate.InclusionInvalid.selector);
            _claim(vc, _inclusion(wrong[i], solo, wrong[i]));
        }
        // The padding leaf, and past the end.
        vm.expectRevert(abi.encodeWithSelector(ProofClaimGate.PositionOutOfRange.selector, 3, 3));
        _claim(vc, _inclusion(3, bytes32(0), 1));
        // A path one level short.
        Request memory shortPath = _inclusion(1, solo, 1);
        bytes32[] memory p = new bytes32[](1);
        p[0] = shortPath.inc.path[0];
        shortPath.inc.path = p;
        vm.expectRevert(ProofClaimGate.InclusionInvalid.selector);
        _claim(vc, shortPath);
        assertEq(_claimed(), 0, "nothing claimed");
    }

    function test_the_proof_must_be_for_the_included_commitment() public {
        // Position 0 opens correctly, but the proof is for the commitment at position 1.
        x402BatchSettlement.VoucherClaim memory vc = _voucher(config, 2 * UNIT, UNIT);
        vm.expectRevert(ProofClaimGate.ProofInvalid.selector);
        _claim(vc, _inclusion(0, batch[0], 0));
        assertEq(_claimed(), 0, "nothing claimed");
    }

    // ── The proof ───────────────────────────────────────────────────────────────────────────────

    function test_an_invalid_proof_is_refused_and_the_position_stays_open() public {
        x402BatchSettlement.VoucherClaim memory vc = _voucher(config, 2 * UNIT, UNIT);
        Request memory inc = _inclusion(1, solo, 1);
        bytes memory sig = _rootSig(channelId, terms, payerKey);
        vm.expectRevert(ProofClaimGate.ProofInvalid.selector);
        gate.claimWithProof(vc, terms, sig, inc.leaf, inc.inc, soloEntry, output, _flip(proof, 100));
        assertFalse(gate.proven(gate.rootDigestOf(channelId, terms), 1), "still open");
        _claim(vc, inc);
        assertEq(_claimed(), UNIT, "then the valid proof claims");
    }

    function test_a_check_that_cannot_run_is_unavailable_not_invalid() public {
        x402BatchSettlement.VoucherClaim memory vc = _voucher(config, 2 * UNIT, UNIT);
        Request memory inc = _inclusion(1, solo, 1);
        vm.etch(SOLO, FixturesK8.verifierBytecode());
        vm.expectRevert(abi.encodeWithSelector(ProofClaimGate.VerifierUnavailable.selector, soloId));
        _claim(vc, inc);

        VerifierEntry memory e = soloEntry;
        e.verifyGas += 1;
        bytes memory sig = _rootSig(channelId, terms, payerKey);
        vm.expectRevert(abi.encodeWithSelector(ProofClaimGate.VerifierUnavailable.selector, soloId));
        gate.claimWithProof(vc, terms, sig, inc.leaf, inc.inc, e, output, _flip(proof, 100));
        assertEq(_claimed(), 0, "nothing claimed");
    }

    // ── What the payer signed ───────────────────────────────────────────────────────────────────

    function test_a_root_the_payer_did_not_sign_is_refused() public {
        x402BatchSettlement.VoucherClaim memory vc = _voucher(config, 2 * UNIT, UNIT);
        Request memory inc = _inclusion(1, solo, 1);
        (, uint256 otherKey) = makeAddrAndKey("not the payer");
        bytes memory byOther = _rootSig(channelId, terms, otherKey);
        vm.expectRevert(ProofClaimGate.RootSignatureInvalid.selector);
        gate.claimWithProof(vc, terms, byOther, inc.leaf, inc.inc, soloEntry, output, proof);

        // Signed terms, altered after signing: a higher price.
        bytes memory sig = _rootSig(channelId, terms, payerKey);
        ProofClaimGate.RootTerms memory dearer = terms;
        dearer.unitPrice = 2 * UNIT;
        vm.expectRevert(ProofClaimGate.RootSignatureInvalid.selector);
        gate.claimWithProof(vc, dearer, sig, inc.leaf, inc.inc, soloEntry, output, proof);
    }

    function test_a_root_signed_for_one_channel_does_not_open_another() public {
        x402BatchSettlement.ChannelConfig memory other = config;
        other.salt = bytes32(uint256(1));
        _deposit(other, 3 * UNIT);
        bytes memory sigForFirst = _rootSig(channelId, terms, payerKey);
        x402BatchSettlement.VoucherClaim memory vc = _voucher(other, 2 * UNIT, UNIT);
        vm.expectRevert(ProofClaimGate.RootSignatureInvalid.selector);
        gate.claimWithProof(
            vc, terms, sigForFirst, _inclusion(1, solo, 1).leaf, _inclusion(1, solo, 1).inc, soloEntry, output, proof
        );
    }

    function test_a_root_signed_for_another_gate_does_not_open_this_one() public {
        ProofClaimGate otherGate = new ProofClaimGate(settlement, registry);
        bytes memory sigForOther = _signDigest(payerKey, _rootDigest(address(otherGate), channelId, terms));
        x402BatchSettlement.VoucherClaim memory vc = _voucher(config, 2 * UNIT, UNIT);
        vm.expectRevert(ProofClaimGate.RootSignatureInvalid.selector);
        gate.claimWithProof(
            vc, terms, sigForOther, _inclusion(1, solo, 1).leaf, _inclusion(1, solo, 1).inc, soloEntry, output, proof
        );
    }

    // ── How much a proof unlocks ────────────────────────────────────────────────────────────────

    function test_one_proof_claims_one_unit_and_a_position_counts_once() public {
        // The payer's voucher allows two requests; one proof unlocks one.
        x402BatchSettlement.VoucherClaim memory two = _voucher(config, 2 * UNIT, 2 * UNIT);
        vm.expectRevert(abi.encodeWithSelector(ProofClaimGate.ClaimExceedsProven.selector, 2 * UNIT, UNIT));
        _claim(two, _inclusion(1, solo, 1));

        _claim(_voucher(config, 2 * UNIT, UNIT), _inclusion(1, solo, 1));
        vm.expectRevert(abi.encodeWithSelector(ProofClaimGate.AlreadyProven.selector, 1));
        _claim(two, _inclusion(1, solo, 1));
        assertEq(_claimed(), UNIT, "one unit");
    }

    function test_base_claimed_carries_earlier_batches() public {
        // An earlier batch was claimed to one unit; this batch's root says so.
        _claim(_voucher(config, 3 * UNIT, UNIT), _inclusion(1, solo, 1));
        delete batch;
        delete payees;
        _request(solo, payee2);
        _request(keccak256("request 4"), payee0);
        _signTerms(UNIT);
        _claim(_voucher(config, 3 * UNIT, 2 * UNIT), _inclusion(0, solo, 0));
        assertEq(_claimed(), 2 * UNIT, "base plus one proven request");
        assertEq(token.balanceOf(payee2), UNIT, "this batch's payee");
        _gateHoldsNothing();
    }

    // ── (c) The gate is the only way in ─────────────────────────────────────────────────────────

    function test_without_the_gate_nobody_claims_or_signs_for_its_channel() public {
        x402BatchSettlement.VoucherClaim[] memory claims = new x402BatchSettlement.VoucherClaim[](1);
        claims[0] = _voucher(config, 2 * UNIT, UNIT);
        address[5] memory others = [stranger, payee, payee0, payee2, payer];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(x402BatchSettlement.NotAuthorizedToClaim.selector);
            settlement.claim(claims);
        }
        // The gate has no ERC-1271, so no signature authorizes a relayed claim.
        bytes memory sig = _signDigest(payerKey, settlement.getClaimBatchDigest(claims));
        vm.expectRevert(x402BatchSettlement.InvalidSignature.selector);
        settlement.claimWithSignature(claims, sig);
        assertEq(_claimed(), 0, "nothing claimed");
    }

    function test_a_channel_whose_receiver_is_not_the_gate_is_refused() public {
        x402BatchSettlement.ChannelConfig memory leaky = config;
        leaky.receiver = payee;
        _refusedAndWhy(leaky, payee);
    }

    function test_a_channel_whose_receiver_authorizer_is_not_the_gate_is_refused() public {
        x402BatchSettlement.ChannelConfig memory leaky = config;
        leaky.receiverAuthorizer = payee;
        _refusedAndWhy(leaky, payee);
    }

    /// The gate refuses a channel it does not wholly hold; `leak`, which holds the other role, could
    /// claim on it with no proof at all.
    function _refusedAndWhy(x402BatchSettlement.ChannelConfig memory leaky, address leak) internal {
        _deposit(leaky, 3 * UNIT);
        bytes32 leakyId = settlement.getChannelId(leaky);
        x402BatchSettlement.VoucherClaim memory vc = _voucher(leaky, 2 * UNIT, UNIT);
        bytes memory sig = _rootSig(leakyId, terms, payerKey);
        vm.expectRevert(ProofClaimGate.NotThisGate.selector);
        gate.claimWithProof(
            vc, terms, sig, _inclusion(1, solo, 1).leaf, _inclusion(1, solo, 1).inc, soloEntry, output, proof
        );

        // Why: x402BatchSettlement admits both the receiver and the receiver authorizer.
        x402BatchSettlement.VoucherClaim[] memory claims = new x402BatchSettlement.VoucherClaim[](1);
        claims[0] = _voucher(leaky, 2 * UNIT, 2 * UNIT);
        vm.prank(leak);
        settlement.claim(claims);
        (, uint128 claimed) = settlement.channels(leakyId);
        assertEq(claimed, 2 * UNIT, "claimed without any proof");
    }

    // ── The tree ────────────────────────────────────────────────────────────────────────────────

    function test_every_position_of_batches_of_one_to_nine_opens_only_where_it_is() public {
        for (uint256 n = 1; n <= 9; n++) {
            delete batch;
            delete payees;
            for (uint256 i = 0; i < n; i++) {
                _request(keccak256(abi.encode("request", n, i)), address(uint160(uint256(keccak256(abi.encode(n, i))))));
            }
            bytes32 root = _root(batch, payees);
            for (uint256 i = 0; i < n; i++) {
                assertTrue(_includes(root, uint32(n), _inclusion(uint32(i), batch[i], i)), "own position");
                if (n > 1) {
                    uint256 j = (i + 1) % n;
                    assertFalse(_includes(root, uint32(n), _inclusion(uint32(j), batch[i], i)), "other position");
                    assertFalse(_includes(root, uint32(n), _inclusion(uint32(i), batch[j], i)), "other commitment");
                }
            }
        }
    }

    // ── Gas ─────────────────────────────────────────────────────────────────────────────────────

    function test_gas_claim_with_proof_first_claim_of_the_channel() public {
        bytes memory data = abi.encodeCall(
            gate.claimWithProof,
            (
                _voucher(config, 2 * UNIT, UNIT),
                terms,
                _rootSig(channelId, terms, payerKey),
                _inclusion(1, solo, 1).leaf,
                _inclusion(1, solo, 1).inc,
                soloEntry,
                output,
                proof
            )
        );
        address[] memory cold = new address[](7);
        (cold[0], cold[1], cold[2], cold[3], cold[4], cold[5], cold[6]) =
        (address(gate), address(settlement), address(registry), address(adapter), SOLO, payer, address(token));
        TxGas memory g = _measure(stranger, address(gate), data, cold);
        _log("ProofClaimGate.claimWithProof, the channel's first claim", g);
        assertEq(_claimed(), UNIT, "the measured call claimed");
        assertLe(g.total, 841_700, "pin: measured 841,297");
    }

    /// The channel's second claim, from a second signed batch: the channel's and the receiver's
    /// totals are already non-zero.
    function test_gas_claim_with_proof_steady() public {
        _claim(_voucher(config, 2 * UNIT, UNIT), _inclusion(1, solo, 1));
        delete batch;
        delete payees;
        _request(solo, payee);
        _request(keccak256("request 4"), payee0);
        _signTerms(UNIT);
        bytes memory data = abi.encodeCall(
            gate.claimWithProof,
            (
                _voucher(config, 2 * UNIT, 2 * UNIT),
                terms,
                _rootSig(channelId, terms, payerKey),
                _inclusion(0, solo, 0).leaf,
                _inclusion(0, solo, 0).inc,
                soloEntry,
                output,
                proof
            )
        );
        address[] memory cold = new address[](7);
        (cold[0], cold[1], cold[2], cold[3], cold[4], cold[5], cold[6]) =
        (address(gate), address(settlement), address(registry), address(adapter), SOLO, payer, address(token));
        TxGas memory g = _measure(stranger, address(gate), data, cold);
        _log("ProofClaimGate.claimWithProof, steady", g);
        assertEq(_claimed(), 2 * UNIT, "the measured call claimed");
        assertLe(g.total, 793_900, "pin: measured 793,491");
    }
}
