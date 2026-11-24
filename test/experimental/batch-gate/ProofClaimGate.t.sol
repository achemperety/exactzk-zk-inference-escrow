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
    address internal payee = makeAddr("payee");
    address internal stranger = makeAddr("stranger");

    bytes32 internal solo; // the real proof's input commitment
    bytes internal output;
    bytes internal proof;

    x402BatchSettlement.ChannelConfig internal config;
    bytes32 internal channelId;
    bytes32[] internal batch; // the ordered input commitments of one batch
    ProofClaimGate.RootTerms internal terms;

    function setUp() public override {
        super.setUp();
        settlement = new x402BatchSettlement();
        gate = new ProofClaimGate(settlement, registry, payee);
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

        // Three requests; the real proof's commitment is the second.
        batch.push(keccak256("request 0"));
        batch.push(solo);
        batch.push(keccak256("request 2"));
        terms = ProofClaimGate.RootTerms({
            verifierId: soloId, root: _root(batch), count: uint32(batch.length), unitPrice: UNIT, baseClaimed: 0
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
    function _leaf(uint256 position, bytes32 commitment) internal pure returns (bytes32) {
        return keccak256(abi.encode(keccak256("x402.proof-claim-gate.leaf.v0"), position, commitment));
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

    function _level(bytes32[] memory commitments) internal pure returns (bytes32[] memory nodes) {
        uint256 width = 1;
        while (width < commitments.length) width <<= 1;
        nodes = new bytes32[](width); // padding leaves stay zero
        for (uint256 i = 0; i < commitments.length; i++) {
            nodes[i] = _leaf(i, commitments[i]);
        }
    }

    function _up(bytes32[] memory nodes) internal pure returns (bytes32[] memory parent) {
        parent = new bytes32[](nodes.length / 2);
        for (uint256 i = 0; i < parent.length; i++) {
            parent[i] = keccak256(abi.encodePacked(nodes[2 * i], nodes[2 * i + 1]));
        }
    }

    function _root(bytes32[] memory commitments) internal pure returns (bytes32) {
        bytes32[] memory nodes = _level(commitments);
        while (nodes.length > 1) nodes = _up(nodes);
        return nodes[0];
    }

    function _path(bytes32[] memory commitments, uint256 position) internal pure returns (bytes32[] memory path) {
        bytes32[] memory nodes = _level(commitments);
        uint256 depth;
        while ((uint256(1) << depth) < nodes.length) depth++;
        path = new bytes32[](depth);
        for (uint256 j = 0; j < depth; j++) {
            path[j] = nodes[position ^ 1];
            nodes = _up(nodes);
            position >>= 1;
        }
    }

    function _inclusion(uint32 position, bytes32 commitment, uint256 pathOf)
        internal
        view
        returns (ProofClaimGate.Inclusion memory)
    {
        return ProofClaimGate.Inclusion({position: position, commitment: commitment, path: _path(batch, pathOf)});
    }

    function _claim(x402BatchSettlement.VoucherClaim memory vc, ProofClaimGate.Inclusion memory inc) internal {
        gate.claimWithProof(vc, terms, _rootSig(channelId, terms, payerKey), inc, soloEntry, output, proof);
    }

    function _claimed() internal view returns (uint128 totalClaimed) {
        (, totalClaimed) = settlement.channels(channelId);
    }

    function _flip(bytes memory data, uint256 index) internal pure returns (bytes memory c) {
        c = bytes.concat(data);
        c[index] = bytes1(uint8(c[index]) ^ 0x01);
    }

    // ── One claim settles ───────────────────────────────────────────────────────────────────────

    function test_a_proven_request_at_its_signed_position_is_claimed_and_paid_out() public {
        x402BatchSettlement.VoucherClaim memory vc = _voucher(config, 2 * UNIT, UNIT);
        ProofClaimGate.Inclusion memory inc = _inclusion(1, solo, 1);
        bytes32 digest = gate.rootDigestOf(channelId, terms);
        assertEq(digest, _rootDigest(address(gate), channelId, terms), "the gate's digest is the EIP-712 one");
        assertEq(gate.leafHash(1, solo), _leaf(1, solo), "the gate's leaf");

        vm.expectEmit(address(gate));
        emit ProofClaimGate.ClaimProven(channelId, digest, 1, solo, output);
        vm.prank(stranger);
        _claim(vc, inc);

        assertEq(_claimed(), UNIT, "one request claimed");
        assertTrue(gate.proven(digest, 1), "position 1 proven");
        assertEq(gate.provenCount(digest), 1, "count");

        gate.payout(address(token));
        assertEq(token.balanceOf(payee), UNIT, "payee paid");
        assertEq(token.balanceOf(stranger), 0, "the caller gets nothing");
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
        ProofClaimGate.Inclusion memory shortPath = _inclusion(1, solo, 1);
        bytes32[] memory p = new bytes32[](1);
        p[0] = shortPath.path[0];
        shortPath.path = p;
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
        ProofClaimGate.Inclusion memory inc = _inclusion(1, solo, 1);
        bytes memory sig = _rootSig(channelId, terms, payerKey);
        vm.expectRevert(ProofClaimGate.ProofInvalid.selector);
        gate.claimWithProof(vc, terms, sig, inc, soloEntry, output, _flip(proof, 100));
        assertFalse(gate.proven(gate.rootDigestOf(channelId, terms), 1), "still open");
        _claim(vc, inc);
        assertEq(_claimed(), UNIT, "then the valid proof claims");
    }

    function test_a_check_that_cannot_run_is_unavailable_not_invalid() public {
        x402BatchSettlement.VoucherClaim memory vc = _voucher(config, 2 * UNIT, UNIT);
        ProofClaimGate.Inclusion memory inc = _inclusion(1, solo, 1);
        vm.etch(SOLO, FixturesK8.verifierBytecode());
        vm.expectRevert(abi.encodeWithSelector(ProofClaimGate.VerifierUnavailable.selector, soloId));
        _claim(vc, inc);

        VerifierEntry memory e = soloEntry;
        e.verifyGas += 1;
        bytes memory sig = _rootSig(channelId, terms, payerKey);
        vm.expectRevert(abi.encodeWithSelector(ProofClaimGate.VerifierUnavailable.selector, soloId));
        gate.claimWithProof(vc, terms, sig, inc, e, output, _flip(proof, 100));
        assertEq(_claimed(), 0, "nothing claimed");
    }

    // ── What the payer signed ───────────────────────────────────────────────────────────────────

    function test_a_root_the_payer_did_not_sign_is_refused() public {
        x402BatchSettlement.VoucherClaim memory vc = _voucher(config, 2 * UNIT, UNIT);
        ProofClaimGate.Inclusion memory inc = _inclusion(1, solo, 1);
        (, uint256 otherKey) = makeAddrAndKey("not the payer");
        bytes memory byOther = _rootSig(channelId, terms, otherKey);
        vm.expectRevert(ProofClaimGate.RootSignatureInvalid.selector);
        gate.claimWithProof(vc, terms, byOther, inc, soloEntry, output, proof);

        // Signed terms, altered after signing: a higher price.
        bytes memory sig = _rootSig(channelId, terms, payerKey);
        ProofClaimGate.RootTerms memory dearer = terms;
        dearer.unitPrice = 2 * UNIT;
        vm.expectRevert(ProofClaimGate.RootSignatureInvalid.selector);
        gate.claimWithProof(vc, dearer, sig, inc, soloEntry, output, proof);
    }

    function test_a_root_signed_for_one_channel_does_not_open_another() public {
        x402BatchSettlement.ChannelConfig memory other = config;
        other.salt = bytes32(uint256(1));
        _deposit(other, 3 * UNIT);
        bytes memory sigForFirst = _rootSig(channelId, terms, payerKey);
        x402BatchSettlement.VoucherClaim memory vc = _voucher(other, 2 * UNIT, UNIT);
        vm.expectRevert(ProofClaimGate.RootSignatureInvalid.selector);
        gate.claimWithProof(vc, terms, sigForFirst, _inclusion(1, solo, 1), soloEntry, output, proof);
    }

    function test_a_root_signed_for_another_gate_does_not_open_this_one() public {
        ProofClaimGate otherGate = new ProofClaimGate(settlement, registry, payee);
        bytes memory sigForOther = _signDigest(payerKey, _rootDigest(address(otherGate), channelId, terms));
        x402BatchSettlement.VoucherClaim memory vc = _voucher(config, 2 * UNIT, UNIT);
        vm.expectRevert(ProofClaimGate.RootSignatureInvalid.selector);
        gate.claimWithProof(vc, terms, sigForOther, _inclusion(1, solo, 1), soloEntry, output, proof);
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
        terms.baseClaimed = UNIT;
        x402BatchSettlement.VoucherClaim memory vc = _voucher(config, 3 * UNIT, 2 * UNIT);
        _claim(vc, _inclusion(1, solo, 1));
        assertEq(_claimed(), 2 * UNIT, "base plus one proven request");
    }

    // ── The gate is the only way in ─────────────────────────────────────────────────────────────

    function test_without_the_gate_nobody_claims_or_signs_for_its_channel() public {
        x402BatchSettlement.VoucherClaim[] memory claims = new x402BatchSettlement.VoucherClaim[](1);
        claims[0] = _voucher(config, 2 * UNIT, UNIT);
        address[2] memory others = [stranger, payee];
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
        _deposit(leaky, 3 * UNIT);
        bytes32 leakyId = settlement.getChannelId(leaky);
        x402BatchSettlement.VoucherClaim memory vc = _voucher(leaky, 2 * UNIT, UNIT);
        bytes memory sig = _rootSig(leakyId, terms, payerKey);
        vm.expectRevert(ProofClaimGate.NotThisGate.selector);
        gate.claimWithProof(vc, terms, sig, _inclusion(1, solo, 1), soloEntry, output, proof);

        // Why: x402BatchSettlement admits the receiver too, so this receiver claims with no proof.
        x402BatchSettlement.VoucherClaim[] memory claims = new x402BatchSettlement.VoucherClaim[](1);
        claims[0] = _voucher(leaky, 2 * UNIT, 2 * UNIT);
        vm.prank(payee);
        settlement.claim(claims);
        (, uint128 claimed) = settlement.channels(leakyId);
        assertEq(claimed, 2 * UNIT, "claimed by the receiver without any proof");
    }

    // ── The tree ────────────────────────────────────────────────────────────────────────────────

    function test_every_position_of_batches_of_one_to_nine_opens_only_where_it_is() public {
        for (uint256 n = 1; n <= 9; n++) {
            delete batch;
            for (uint256 i = 0; i < n; i++) {
                batch.push(keccak256(abi.encode("request", n, i)));
            }
            bytes32 root = _root(batch);
            for (uint256 i = 0; i < n; i++) {
                assertTrue(gate.includes(root, uint32(n), _inclusion(uint32(i), batch[i], i)), "own position");
                if (n > 1) {
                    uint256 j = (i + 1) % n;
                    assertFalse(gate.includes(root, uint32(n), _inclusion(uint32(j), batch[i], i)), "other position");
                    assertFalse(gate.includes(root, uint32(n), _inclusion(uint32(i), batch[j], i)), "other commitment");
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
                _inclusion(1, solo, 1),
                soloEntry,
                output,
                proof
            )
        );
        address[] memory cold = new address[](6);
        (cold[0], cold[1], cold[2], cold[3], cold[4], cold[5]) =
        (address(gate), address(settlement), address(registry), address(adapter), SOLO, payer);
        TxGas memory g = _measure(stranger, address(gate), data, cold);
        _log("ProofClaimGate.claimWithProof, the channel's first claim", g);
        assertEq(_claimed(), UNIT, "the measured call claimed");
        assertLe(g.total, 797_800, "pin: measured 797,428");
    }

    /// The channel's second claim, from a second signed batch: the channel's and the receiver's
    /// totals are already non-zero.
    function test_gas_claim_with_proof_steady() public {
        _claim(_voucher(config, 2 * UNIT, UNIT), _inclusion(1, solo, 1));
        delete batch;
        batch.push(solo);
        batch.push(keccak256("request 4"));
        terms.root = _root(batch);
        terms.count = 2;
        terms.baseClaimed = UNIT;
        bytes memory data = abi.encodeCall(
            gate.claimWithProof,
            (
                _voucher(config, 2 * UNIT, 2 * UNIT),
                terms,
                _rootSig(channelId, terms, payerKey),
                _inclusion(0, solo, 0),
                soloEntry,
                output,
                proof
            )
        );
        address[] memory cold = new address[](6);
        (cold[0], cold[1], cold[2], cold[3], cold[4], cold[5]) =
        (address(gate), address(settlement), address(registry), address(adapter), SOLO, payer);
        TxGas memory g = _measure(stranger, address(gate), data, cold);
        _log("ProofClaimGate.claimWithProof, steady", g);
        assertEq(_claimed(), 2 * UNIT, "the measured call claimed");
        assertLe(g.total, 769_600, "pin: measured 769,210");
    }
}
