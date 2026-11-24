// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProofCoreBase} from "./ProofCoreBase.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";
import {ProofCheck, ProofStatus} from "../src/ProofCheck.sol";
import {
    AcceptAllTarget,
    RevertingTarget,
    RevertsWithTrueTarget,
    GasBurnerTarget,
    ReturnsTwoTarget,
    ReturnsTwoWordsTarget,
    ReturnsNothingTarget,
    AlwaysTrueAdapter,
    AlwaysFalseAdapter,
    RevertingAdapter,
    RevertsWithTrueAdapter,
    GasBurnerAdapter,
    ReturnsTwoAdapter,
    ReturnsTwoWordsAdapter,
    ReturnsNothingAdapter,
    GasGaugeAdapter,
    ProofCheckHarness
} from "./mocks/Mocks.sol";

contract ProofCheckTest is ProofCoreBase {
    /// Register an entry and run the solo statement against it, through both entry points.
    /// Both must agree; the common answer is returned.
    function _registerAndCheck(VerifierEntry memory e) internal returns (ProofStatus status) {
        bytes32 id = registry.register(e);
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        status = harness.checkWithEntry(id, e, c, o, p);
        _assertStatus(harness.checkById(id, c, o, p), status);
    }

    // ── Real proofs ─────────────────────────────────────────────────────────────────────────────

    function test_solo_fixture_is_valid() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        _assertStatus(harness.checkWithEntry(soloId, soloEntry, c, o, p), ProofStatus.Valid);
        _assertStatus(harness.checkById(soloId, c, o, p), ProofStatus.Valid);
    }

    function test_k8_fixture_is_valid() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _k8();
        _assertStatus(harness.checkWithEntry(k8Id, k8Entry, c, o, p), ProofStatus.Valid);
        _assertStatus(harness.checkById(k8Id, c, o, p), ProofStatus.Valid);
    }

    function test_wrong_output_is_invalid_and_does_not_revert() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        _setWord(o, 0, _word(o, 0) + 1);
        _assertStatus(harness.checkWithEntry(soloId, soloEntry, c, o, p), ProofStatus.Invalid);
        _assertStatus(harness.checkById(soloId, c, o, p), ProofStatus.Invalid);
    }

    function test_tampered_proof_is_invalid_and_does_not_revert() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _k8();
        p[7] = bytes1(uint8(p[7]) ^ 0x80);
        _assertStatus(harness.checkWithEntry(k8Id, k8Entry, c, o, p), ProofStatus.Invalid);
        _assertStatus(harness.checkById(k8Id, c, o, p), ProofStatus.Invalid);
    }

    function test_proof_checked_against_the_other_circuit_is_invalid() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        (,, bytes memory k8Proof) = _k8();
        _assertStatus(harness.checkWithEntry(soloId, soloEntry, c, o, k8Proof), ProofStatus.Invalid);
        (c, o,) = _k8();
        _assertStatus(harness.checkWithEntry(k8Id, k8Entry, c, o, p), ProofStatus.Invalid);
    }

    function test_zero_value_of_the_status_is_invalid() public pure {
        ProofStatus unset;
        assertEq(uint8(unset), uint8(ProofStatus.Invalid));
        assertEq(uint8(ProofStatus.Invalid), 0);
        assertEq(uint8(ProofStatus.Valid), 1);
        assertEq(uint8(ProofStatus.Unverifiable), 2);
    }

    // ── Unverifiable ────────────────────────────────────────────────────────────────────────────

    function test_unknown_id_is_unverifiable() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        bytes32 unknown = keccak256("unknown");
        _assertStatus(harness.checkWithEntry(unknown, soloEntry, c, o, p), ProofStatus.Unverifiable);
        _assertStatus(harness.checkById(unknown, c, o, p), ProofStatus.Unverifiable);
    }

    /// The caller supplies the entry on the cheap path. Anything other than the registered entry
    /// must be refused, in particular the registered id paired with an adapter that says yes.
    function test_supplied_entry_that_is_not_the_registered_one_is_unverifiable() public {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        _setWord(o, 0, _word(o, 0) + 1); // a statement the real verifier rejects

        VerifierEntry memory forged = soloEntry;
        forged.adapter = address(new AlwaysTrueAdapter());
        forged.adapterCodeHash = forged.adapter.codehash;
        _assertStatus(harness.checkWithEntry(soloId, forged, c, o, p), ProofStatus.Unverifiable);

        forged = soloEntry;
        forged.target = address(new AcceptAllTarget());
        forged.targetCodeHash = forged.target.codehash;
        _assertStatus(harness.checkWithEntry(soloId, forged, c, o, p), ProofStatus.Unverifiable);

        forged = soloEntry;
        forged.verifyGas = 1;
        _assertStatus(harness.checkWithEntry(soloId, forged, c, o, p), ProofStatus.Unverifiable);

        // A registered entry presented under another registered id.
        (c, o, p) = _solo();
        _assertStatus(harness.checkWithEntry(k8Id, soloEntry, c, o, p), ProofStatus.Unverifiable);
    }

    function test_target_whose_code_changed_is_unverifiable() public {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        _setWord(o, 0, _word(o, 0) + 1); // a statement the real verifier rejects
        vm.etch(SOLO, address(new AcceptAllTarget()).code);
        _assertStatus(harness.checkWithEntry(soloId, soloEntry, c, o, p), ProofStatus.Unverifiable);
        _assertStatus(harness.checkById(soloId, c, o, p), ProofStatus.Unverifiable);
    }

    function test_adapter_whose_code_changed_is_unverifiable() public {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        _setWord(o, 0, _word(o, 0) + 1);
        vm.etch(address(adapter), address(new AlwaysTrueAdapter()).code);
        _assertStatus(harness.checkWithEntry(soloId, soloEntry, c, o, p), ProofStatus.Unverifiable);
        _assertStatus(harness.checkById(soloId, c, o, p), ProofStatus.Unverifiable);
    }

    function test_target_whose_code_was_removed_is_unverifiable() public {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        vm.etch(SOLO, "");
        _assertStatus(harness.checkWithEntry(soloId, soloEntry, c, o, p), ProofStatus.Unverifiable);
        _assertStatus(harness.checkById(soloId, c, o, p), ProofStatus.Unverifiable);
    }

    // ── Shape, checked before any adapter is asked ──────────────────────────────────────────────

    function test_arguments_that_do_not_fit_the_entry_are_invalid() public {
        // An adapter that accepts anything: only the library's own check can refuse.
        VerifierEntry memory e =
            _entry(address(new AlwaysTrueAdapter()), address(0), 8, OUTPUT_SIZE, 100_000, bytes32(0));
        bytes32 id = registry.register(e);

        (bytes32[] memory c8, bytes memory o8, bytes memory p) = _k8();
        _assertStatus(harness.checkWithEntry(id, e, c8, o8, p), ProofStatus.Valid);

        (bytes32[] memory c1, bytes memory o1,) = _solo();
        _assertStatus(harness.checkWithEntry(id, e, c1, o1, p), ProofStatus.Invalid);
        _assertStatus(harness.checkById(id, c1, o1, p), ProofStatus.Invalid);
        _assertStatus(harness.checkWithEntry(id, e, c8, o1, p), ProofStatus.Invalid);
        _assertStatus(harness.checkWithEntry(id, e, c1, o8, p), ProofStatus.Invalid);
        _assertStatus(harness.checkWithEntry(id, e, c8, new bytes(o8.length + 32), p), ProofStatus.Invalid);
    }

    // ── Adapters and targets that misbehave ─────────────────────────────────────────────────────

    function test_always_true_adapter_is_valid_and_always_false_is_invalid() public {
        _assertStatus(
            _registerAndCheck(_entry(address(new AlwaysTrueAdapter()), SOLO, 1, OUTPUT_SIZE, 100_000, bytes32(0))),
            ProofStatus.Valid
        );
        _assertStatus(
            _registerAndCheck(_entry(address(new AlwaysFalseAdapter()), SOLO, 1, OUTPUT_SIZE, 100_000, bytes32(0))),
            ProofStatus.Invalid
        );
    }

    function test_misbehaving_adapters_never_give_valid() public {
        address[6] memory bad = [
            address(new RevertingAdapter()),
            address(new RevertsWithTrueAdapter()),
            address(new GasBurnerAdapter()),
            address(new ReturnsTwoAdapter()),
            address(new ReturnsTwoWordsAdapter()),
            address(new ReturnsNothingAdapter())
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            _assertStatus(
                _registerAndCheck(_entry(bad[i], SOLO, 1, OUTPUT_SIZE, 100_000, bytes32(uint256(i)))),
                ProofStatus.Invalid
            );
        }
    }

    function test_misbehaving_targets_behind_the_ezkl_adapter_never_give_valid() public {
        address[6] memory bad = [
            address(new RevertingTarget()),
            address(new RevertsWithTrueTarget()),
            address(new GasBurnerTarget()),
            address(new ReturnsTwoTarget()),
            address(new ReturnsTwoWordsTarget()),
            address(new ReturnsNothingTarget())
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            _assertStatus(
                _registerAndCheck(_entry(address(adapter), bad[i], 1, OUTPUT_SIZE, 100_000, bytes32(uint256(i)))),
                ProofStatus.Invalid
            );
        }
    }

    /// An adapter is given its allowance and no more, however much gas the transaction carries.
    function test_adapter_cannot_spend_more_than_its_allowance() public {
        VerifierEntry memory e = _entry(address(new GasBurnerAdapter()), SOLO, 1, OUTPUT_SIZE, 100_000, bytes32(0));
        bytes32 id = registry.register(e);
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();

        _assertStatus(harness.checkWithEntry{gas: 5_000_000}(id, e, c, o, p), ProofStatus.Invalid);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint("gas used with a 100,000 allowance and an adapter that burns everything", used);
        assertLt(used, 150_000);
    }

    // ── Gas: the submitter cannot turn a valid proof into an invalid one ─────────────────────────

    function test_insufficient_gas_reverts_with_a_typed_error() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        bytes memory call = abi.encodeCall(ProofCheckHarness.checkWithEntry, (soloId, soloEntry, c, o, p));

        // Enough to reach the check, not enough to hand over the full allowance.
        (bool ok, bytes memory ret) = address(harness).staticcall{gas: SOLO_VERIFY_GAS}(call);
        assertFalse(ok, "ran the verifier short of gas");
        assertEq(bytes4(ret), ProofCheck.InsufficientGasForVerifier.selector);

        call = abi.encodeCall(ProofCheckHarness.checkById, (soloId, c, o, p));
        (ok, ret) = address(harness).staticcall{gas: SOLO_VERIFY_GAS}(call);
        assertFalse(ok, "ran the verifier short of gas");
        assertEq(bytes4(ret), ProofCheck.InsufficientGasForVerifier.selector);
    }

    /// Sweep the gas given to a check of a valid real proof. Every attempt must end in one of two
    /// ways: the call reverts, or the status is Valid. `Invalid` must never appear.
    function test_no_gas_amount_turns_a_valid_real_proof_invalid() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        bytes memory call = abi.encodeCall(ProofCheckHarness.checkWithEntry, (soloId, soloEntry, c, o, p));
        uint256 valid;
        uint256 typedReverts;
        for (uint256 g = 20_000; g <= 700_000; g += 9_973) {
            (bool ok, bytes memory ret) = address(harness).staticcall{gas: g}(call);
            if (ok) {
                _assertStatus(abi.decode(ret, (ProofStatus)), ProofStatus.Valid);
                valid++;
            } else {
                assertTrue(
                    ret.length == 0 || bytes4(ret) == ProofCheck.InsufficientGasForVerifier.selector,
                    "unexpected revert"
                );
                if (ret.length != 0) typedReverts++;
            }
        }
        assertGt(valid, 0, "sweep never reached a successful check");
        assertGt(typedReverts, 0, "sweep never hit the gas rule");
    }

    /// The same sweep with an adapter that accepts only if it was started with its whole
    /// allowance, to the unit of gas, in steps fine enough to land on the boundary. If the library
    /// ever hands over less than the allowance without reverting, the status is Invalid.
    function test_adapter_always_receives_its_full_allowance() public {
        // Large enough that the 64/63 term (allowance / 63) is far bigger than the fixed margin,
        // so dropping either one is visible.
        uint32 allowance = 3_000_000;
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();

        // Calibrate: how much gas does the gauge spend before it looks at its gas?
        uint256 probeThreshold = allowance - 1_000;
        address probe = address(new GasGaugeAdapter(probeThreshold));
        uint256 g = probeThreshold;
        while (true) {
            (bool reached, bytes memory answer) = probe.staticcall{gas: g}(hex"00000000");
            if (reached && abi.decode(answer, (uint256)) == 1) break;
            g++;
        }
        uint256 spentBeforeLooking = g - probeThreshold;
        assertLt(spentBeforeLooking, 200, "calibration");

        // This gauge says yes if and only if it was started with at least `allowance` gas.
        address gauge = address(new GasGaugeAdapter(allowance - spentBeforeLooking));
        (bool ok, bytes memory ret) = gauge.staticcall{gas: allowance}(hex"00000000");
        assertTrue(ok && abi.decode(ret, (uint256)) == 1, "gauge accepts the exact allowance");
        (ok, ret) = gauge.staticcall{gas: allowance - 1}(hex"00000000");
        assertTrue(ok && abi.decode(ret, (uint256)) == 0, "gauge refuses one unit less");

        VerifierEntry memory e = _entry(gauge, address(0), 1, OUTPUT_SIZE, allowance, bytes32(0));
        bytes32 id = registry.register(e);
        bytes memory call = abi.encodeCall(ProofCheckHarness.checkWithEntry, (id, e, c, o, p));

        uint256 valid;
        uint256 typedReverts;
        for (g = allowance; g <= uint256(allowance) + allowance / 63 + 30_000; g += 23) {
            (ok, ret) = address(harness).staticcall{gas: g}(call);
            if (ok) {
                _assertStatus(abi.decode(ret, (ProofStatus)), ProofStatus.Valid);
                valid++;
            } else {
                assertEq(bytes4(ret), ProofCheck.InsufficientGasForVerifier.selector, "unexpected revert");
                typedReverts++;
            }
        }
        assertGt(valid, 0, "sweep never reached a successful check");
        assertGt(typedReverts, 0, "sweep never hit the gas rule");
    }

    // ── Cost, for the record ────────────────────────────────────────────────────────────────────
    // Gas used by the whole check (the harness call) minus gas used by verifyProof itself. Of
    // this, 9,900 is four first touches: the registry and one of its slots, the adapter, the
    // target. The bounds are the measured figures rounded up; they exist to catch regressions.

    function _checkOverhead(bool withEntry, bytes32 id, VerifierEntry memory e, uint256 direct, bool k8)
        internal
        view
        returns (uint256)
    {
        (bytes32[] memory c, bytes memory o, bytes memory p) = k8 ? _k8() : _solo();
        ProofStatus status = withEntry ? harness.checkWithEntry(id, e, c, o, p) : harness.checkById(id, c, o, p);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        _assertStatus(status, ProofStatus.Valid);
        return used - direct;
    }

    function test_check_overhead_solo() public {
        uint256 overhead = _checkOverhead(true, soloId, soloEntry, SOLO_DIRECT_GAS, false);
        emit log_named_uint("check overhead, solo, entry supplied by caller", overhead);
        assertLe(overhead, 17_700, "pin: measured 17,429");
    }

    function test_check_overhead_solo_by_id() public {
        uint256 overhead = _checkOverhead(false, soloId, soloEntry, SOLO_DIRECT_GAS, false);
        emit log_named_uint("check overhead, solo, entry read from registry", overhead);
        assertLe(overhead, 28_600, "pin: measured 28,320");
    }

    function test_check_overhead_k8() public {
        uint256 overhead = _checkOverhead(true, k8Id, k8Entry, K8_DIRECT_GAS, true);
        emit log_named_uint("check overhead, K=8, entry supplied by caller", overhead);
        assertLe(overhead, 20_700, "pin: measured 20,435");
    }

    function test_check_overhead_k8_by_id() public {
        uint256 overhead = _checkOverhead(false, k8Id, k8Entry, K8_DIRECT_GAS, true);
        emit log_named_uint("check overhead, K=8, entry read from registry", overhead);
        assertLe(overhead, 31_600, "pin: measured 31,325");
    }
}
