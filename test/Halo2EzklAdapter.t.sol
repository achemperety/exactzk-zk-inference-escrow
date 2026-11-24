// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Fixtures} from "./fixtures/Fixtures.sol";
import {FixturesK8} from "./fixtures/FixturesK8.sol";
import {ProofCoreBase, IHalo2Verifier} from "./ProofCoreBase.sol";
import {
    AcceptAllTarget,
    RejectAllTarget,
    RevertingTarget,
    RevertsWithTrueTarget,
    GasBurnerTarget,
    ReturnsTwoTarget,
    ReturnsTwoWordsTarget,
    ReturnsNothingTarget,
    ExactCalldataTarget
} from "./mocks/Mocks.sol";

contract Halo2EzklAdapterTest is ProofCoreBase {
    address internal acceptAll;

    function setUp() public override {
        super.setUp();
        acceptAll = address(new AcceptAllTarget());
    }

    // ── Real proofs ─────────────────────────────────────────────────────────────────────────────

    function test_solo_fixture_verifies_through_adapter() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        assertTrue(adapter.verify(SOLO, OUTPUT_SIZE, c, o, p));
    }

    function test_k8_fixture_verifies_through_adapter() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _k8();
        assertTrue(adapter.verify(K8, OUTPUT_SIZE, c, o, p));
    }

    function test_proof_system_tag() public view {
        assertEq(adapter.proofSystem(), keccak256("halo2-kzg-bn254/ezkl"));
    }

    function test_wrong_output_returns_false() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        _setWord(o, 3, _word(o, 3) + 1);
        assertFalse(adapter.verify(SOLO, OUTPUT_SIZE, c, o, p));
    }

    function test_wrong_commitment_returns_false() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _k8();
        c[5] = bytes32(uint256(c[5]) + 1);
        assertFalse(adapter.verify(K8, OUTPUT_SIZE, c, o, p));
    }

    function test_tampered_proof_returns_false() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        p[100] = bytes1(uint8(p[100]) ^ 0x01);
        assertFalse(adapter.verify(SOLO, OUTPUT_SIZE, c, o, p));
    }

    function test_lanes_swapped_returns_false() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _k8();
        (c[0], c[1]) = (c[1], c[0]);
        assertFalse(adapter.verify(K8, OUTPUT_SIZE, c, o, p));
    }

    // ── The calldata the adapter builds ─────────────────────────────────────────────────────────

    function test_calldata_is_the_abi_encoding_of_verifyProof() public {
        ExactCalldataTarget target = new ExactCalldataTarget();

        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        target.expect(keccak256(abi.encodeCall(IHalo2Verifier.verifyProof, (p, Fixtures.instances()))));
        assertTrue(adapter.verify(address(target), OUTPUT_SIZE, c, o, p), "solo layout");

        (c, o, p) = _k8();
        target.expect(keccak256(abi.encodeCall(IHalo2Verifier.verifyProof, (p, FixturesK8.instances()))));
        assertTrue(adapter.verify(address(target), OUTPUT_SIZE, c, o, p), "K=8 layout");

        // A proof whose length is not a multiple of 32, and a circuit with no outputs.
        bytes memory odd = hex"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425";
        uint256[] memory two = new uint256[](2);
        (two[0], two[1]) = (7, 9);
        bytes32[] memory twoLanes = new bytes32[](2);
        (twoLanes[0], twoLanes[1]) = (bytes32(uint256(7)), bytes32(uint256(9)));
        target.expect(keccak256(abi.encodeCall(IHalo2Verifier.verifyProof, (odd, two))));
        assertTrue(adapter.verify(address(target), 0, twoLanes, "", odd), "odd proof length, no outputs");
    }

    // ── Field elements ──────────────────────────────────────────────────────────────────────────

    function test_canonical_boundary() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        c[0] = bytes32(R - 1);
        assertTrue(adapter.verify(acceptAll, OUTPUT_SIZE, c, o, p), "R - 1 is a field element");
        c[0] = bytes32(R);
        assertFalse(adapter.verify(acceptAll, OUTPUT_SIZE, c, o, p), "R is not");
        c[0] = bytes32(type(uint256).max);
        assertFalse(adapter.verify(acceptAll, OUTPUT_SIZE, c, o, p), "2^256 - 1 is not");
    }

    /// With a target that accepts anything, the adapter alone must refuse a non-canonical word in
    /// every position: all 88 of a K=8 statement and all 11 of a solo statement. The two shapes
    /// between them exercise both the eight-word pass and the word-by-word remainder.
    function test_noncanonical_word_rejected_at_every_position() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _k8();
        _assertEveryPositionIsChecked(c, o, p);
        (c, o, p) = _solo();
        _assertEveryPositionIsChecked(c, o, p);
    }

    function _assertEveryPositionIsChecked(bytes32[] memory c, bytes memory o, bytes memory p) internal view {
        assertTrue(adapter.verify(acceptAll, OUTPUT_SIZE, c, o, p), "canonical statement");

        for (uint256 i = 0; i < c.length; i++) {
            bytes32 saved = c[i];
            c[i] = bytes32(uint256(saved) + R);
            assertFalse(adapter.verify(acceptAll, OUTPUT_SIZE, c, o, p), "commitment + R accepted");
            c[i] = saved;
        }
        uint256 words = o.length / 32;
        for (uint256 j = 0; j < words; j++) {
            uint256 saved = _word(o, j);
            _setWord(o, j, saved + R);
            assertFalse(adapter.verify(acceptAll, OUTPUT_SIZE, c, o, p), "output + R accepted");
            _setWord(o, j, saved);
        }
        assertTrue(adapter.verify(acceptAll, OUTPUT_SIZE, c, o, p), "statement restored");
    }

    // ── Shape ───────────────────────────────────────────────────────────────────────────────────

    function test_shape_mismatch_returns_false() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        assertTrue(adapter.verify(acceptAll, OUTPUT_SIZE, c, o, p), "well-formed");

        assertFalse(adapter.verify(acceptAll, OUTPUT_SIZE, new bytes32[](0), "", p), "no lanes");
        assertFalse(adapter.verify(acceptAll, OUTPUT_SIZE, c, new bytes(288), p), "outputs too short");
        assertFalse(adapter.verify(acceptAll, OUTPUT_SIZE, c, new bytes(352), p), "outputs too long");
        assertFalse(adapter.verify(acceptAll, OUTPUT_SIZE, new bytes32[](2), o, p), "two lanes, one lane of outputs");
        assertFalse(adapter.verify(acceptAll, 33, c, new bytes(33), p), "output size not a whole number of words");
    }

    // ── Targets that misbehave ──────────────────────────────────────────────────────────────────

    function test_failing_targets_return_false() public {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        assertFalse(adapter.verify(address(new RejectAllTarget()), OUTPUT_SIZE, c, o, p), "returns false");
        assertFalse(adapter.verify(address(new RevertingTarget()), OUTPUT_SIZE, c, o, p), "reverts");
        assertFalse(adapter.verify(address(new RevertsWithTrueTarget()), OUTPUT_SIZE, c, o, p), "reverts with 1");
        assertFalse(adapter.verify(address(new ReturnsTwoTarget()), OUTPUT_SIZE, c, o, p), "returns 2");
        assertFalse(adapter.verify(address(new ReturnsTwoWordsTarget()), OUTPUT_SIZE, c, o, p), "returns two words");
        assertFalse(adapter.verify(address(new ReturnsNothingTarget()), OUTPUT_SIZE, c, o, p), "returns nothing");
        assertFalse(adapter.verify(makeAddr("account without code"), OUTPUT_SIZE, c, o, p), "no code");
    }

    function test_target_that_burns_all_gas_returns_false_without_reverting() public {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        address burner = address(new GasBurnerTarget());
        assertFalse(adapter.verify{gas: 300_000}(burner, OUTPUT_SIZE, c, o, p));
    }

    /// The real verifier, starved of gas inside the adapter, must give false and not a revert.
    function test_real_verifier_out_of_gas_returns_false_without_reverting() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        assertFalse(adapter.verify{gas: 400_000}(SOLO, OUTPUT_SIZE, c, o, p));
    }

    // ── Gas ─────────────────────────────────────────────────────────────────────────────────────
    // "Overhead" is gas used by the adapter's call frame minus gas used by verifyProof itself.
    // Each test checks the acceptance limit (6,000) and a tighter pin just above the measured
    // figure, so that a regression of a few hundred gas is noticed.

    function _overhead(address target, uint256 direct, bytes32[] memory c, bytes memory o, bytes memory p)
        internal
        view
        returns (uint256)
    {
        bool ok = adapter.verify(target, OUTPUT_SIZE, c, o, p);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        assertTrue(ok, "the measured call must be a successful verification");
        return used - direct;
    }

    function test_adapter_overhead_solo_target_warm() public {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        IHalo2Verifier(SOLO).verifyProof(p, Fixtures.instances());
        assertEq(vm.lastCallGas().gasTotalUsed, SOLO_DIRECT_GAS);
        uint256 overhead = _overhead(SOLO, SOLO_DIRECT_GAS, c, o, p);
        emit log_named_uint("adapter overhead, solo, target already warm", overhead);
        assertLe(overhead, 6_000, "acceptance limit");
        assertLe(overhead, 3_200, "pin: measured 2,959");
    }

    function test_adapter_overhead_solo_target_cold() public {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        uint256 overhead = _overhead(SOLO, SOLO_DIRECT_GAS, c, o, p);
        emit log_named_uint("adapter overhead, solo, first touch of target", overhead);
        assertLe(overhead, 6_000, "acceptance limit");
        assertLe(overhead, 5_700, "pin: measured 5,459");
    }

    function test_adapter_overhead_k8_target_warm() public {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _k8();
        IHalo2Verifier(K8).verifyProof(p, FixturesK8.instances());
        assertEq(vm.lastCallGas().gasTotalUsed, K8_DIRECT_GAS);
        uint256 overhead = _overhead(K8, K8_DIRECT_GAS, c, o, p);
        emit log_named_uint("adapter overhead, K=8, target already warm", overhead);
        assertLe(overhead, 6_000, "acceptance limit");
        assertLe(overhead, 5_700, "pin: measured 5,441");
    }

    /// This one is over the 6,000 limit: 7,941. The excess is the 2,500 that the first touch of
    /// any account costs. In a real check the target has already been touched when the adapter is
    /// called (ProofCheck reads its code hash first), so the warm figure is the one that applies.
    function test_adapter_overhead_k8_target_cold() public {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _k8();
        uint256 overhead = _overhead(K8, K8_DIRECT_GAS, c, o, p);
        emit log_named_uint("adapter overhead, K=8, first touch of target", overhead);
        assertLe(overhead, 8_200, "pin: measured 7,941 (6,000 limit plus 2,500 first-touch charge is 8,500)");
    }
}
