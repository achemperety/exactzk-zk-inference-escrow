// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProofCoreBase} from "./ProofCoreBase.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";
import {IProofVerifier} from "../src/IProofVerifier.sol";
import {ProofStatus} from "../src/ProofCheck.sol";
import {Halo2EzklAdapterV2} from "../src/Halo2EzklAdapterV2.sol";

// docs/known-issues/2026-11-out-of-gas-as-invalid.md. A verifier that runs out of gas must never
// read as Invalid. The exhaustion chains below are ported from the step-6 probe of the ERC draft:
// `d` counts the nested calls that forward all their gas, starting with the adapter's call to its
// target. Exhaustion at depth d leaves about allowance * (1 - (63/64)^d) unspent: 1.1%, 3.0%, 4.5%,
// 6.0%, 7.5% for d = 1..5. The threshold is 1/16 (6.25%), so chains up to d = 4 read as
// Unverifiable, and d = 5 is the depth that must not be registered.

/// Leaf: burns every unit of gas it is given.
contract Looper {
    fallback() external {
        assembly {
            for {} 1 {} {}
        }
    }
}

/// Forwards all its gas to `next`, then reverts with no data whatever happened, as a generated
/// verifier does when an inner call fails.
contract Forwarder {
    address internal immutable next;

    constructor(address n) {
        next = n;
    }

    fallback() external {
        address n = next;
        assembly {
            calldatacopy(0, 0, calldatasize())
            pop(staticcall(gas(), n, 0, calldatasize(), 0, 0))
            revert(0, 0)
        }
    }
}

/// Forwards all its gas to a precompile with an input the gas cannot pay for (MODEXP) or that the
/// precompile rejects (ECPAIRING, a point off the curve), then reverts with no data. A precompile
/// given bad input consumes all the gas it was given, exactly like running out of gas.
contract PrecompileCaller {
    bool internal immutable pairing;

    constructor(bool p) {
        pairing = p;
    }

    fallback() external {
        bool p = pairing;
        assembly {
            let ptr := mload(0x40)
            switch p
            case 0 {
                // MODEXP, 1024-byte base, exponent and modulus, all bits set: far above any allowance.
                mstore(ptr, 1024)
                mstore(add(ptr, 0x20), 1024)
                mstore(add(ptr, 0x40), 1024)
                let d := add(ptr, 0x60)
                for { let i := 0 } lt(i, 3072) { i := add(i, 0x20) } { mstore(add(d, i), not(0)) }
                pop(staticcall(gas(), 0x05, ptr, add(0x60, 3072), 0, 0x20))
            }
            default {
                // ECPAIRING with one pair whose G1 point (1, 3) is not on the curve.
                mstore(ptr, 1)
                mstore(add(ptr, 0x20), 3)
                for { let i := 0x40 } lt(i, 0xc0) { i := add(i, 0x20) } { mstore(add(ptr, i), 0) }
                pop(staticcall(gas(), 0x08, ptr, 0xc0, 0, 0x20))
            }
            revert(0, 0)
        }
    }
}

/// An adapter that spends gas until `keep` is left, then answers `false`.
contract LeaveGasAdapter {
    uint256 internal immutable keep;

    constructor(uint256 k) {
        keep = k;
    }

    function proofSystem() external pure returns (bytes32) {
        return keccak256("test/leave-gas");
    }

    fallback() external {
        uint256 k = keep;
        assembly {
            for {} gt(gas(), k) {} {}
            mstore(0, 0)
            return(0, 0x20)
        }
    }
}

/// A target that spends gas until `keep` is left, then reverts with no data (a generated verifier's
/// rejection).
contract LeaveGasTarget {
    uint256 internal immutable keep;

    constructor(uint256 k) {
        keep = k;
    }

    fallback() external {
        uint256 k = keep;
        assembly {
            for {} gt(gas(), k) {} {}
            revert(0, 0)
        }
    }
}

contract OutOfGasClassificationTest is ProofCoreBase {
    uint32 internal constant PROBE_ALLOWANCE = 600_000;

    function _check(bytes32 id, VerifierEntry memory e, bytes32[] memory c, bytes memory o, bytes memory p)
        internal
        view
        returns (ProofStatus status)
    {
        status = harness.checkWithEntry(id, e, c, o, p);
        _assertStatus(harness.checkById(id, c, o, p), status);
    }

    /// Register `target` behind `adapter_` with the probe's allowance and check the solo statement.
    function _checkTarget(address adapter_, address target) internal returns (ProofStatus) {
        VerifierEntry memory e = _entry(adapter_, target, 1, OUTPUT_SIZE, PROBE_ALLOWANCE, bytes32(0));
        bytes32 id = registry.register(e);
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        return _check(id, e, c, o, p);
    }

    function _chains() internal returns (address[7] memory t, string[7] memory label) {
        address leaf = address(new Looper());
        address modexp = address(new PrecompileCaller(false));
        address pairing = address(new PrecompileCaller(true));
        address d3 = address(new Forwarder(modexp));
        address d4 = address(new Forwarder(d3));
        t = [leaf, address(new Forwarder(leaf)), modexp, pairing, d3, d4, address(new Forwarder(d4))];
        label = [
            "d=1 target loops",
            "d=2 target -> loop",
            "d=2 target -> MODEXP out of gas",
            "d=2 target -> ECPAIRING, point off the curve",
            "d=3 target -> helper -> MODEXP",
            "d=4 target -> helper -> helper -> MODEXP",
            "d=5 target -> helper x3 -> MODEXP"
        ];
    }

    // ── Exhaustion chains (the probe's cases) ───────────────────────────────────────────────────

    /// Behind the deployed adapter, which answers `false` for all of them: the check alone must
    /// read every chain up to d = 4, and both precompile cases, as Unverifiable.
    function test_exhaustion_to_depth_4_is_unverifiable_behind_the_deployed_adapter() public {
        (address[7] memory t, string[7] memory label) = _chains();
        for (uint256 i = 0; i < 6; i++) {
            assertEq(uint8(_checkTarget(address(adapter), t[i])), uint8(ProofStatus.Unverifiable), label[i]);
        }
    }

    function test_exhaustion_to_depth_4_is_unverifiable_behind_adapter_v2() public {
        (address[7] memory t, string[7] memory label) = _chains();
        for (uint256 i = 0; i < 6; i++) {
            assertEq(uint8(_checkTarget(address(adapterV2), t[i])), uint8(ProofStatus.Unverifiable), label[i]);
        }
    }

    /// Adapter V2 itself reverts for every chain up to d = 4 instead of answering `false`.
    function test_adapter_v2_reverts_on_exhaustion_to_depth_4() public {
        (address[7] memory t, string[7] memory label) = _chains();
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        bytes memory call;
        for (uint256 i = 0; i < 6; i++) {
            call = abi.encodeCall(IProofVerifier.verify, (t[i], OUTPUT_SIZE, c, o, p));
            (bool ok, bytes memory ret) = address(adapterV2).staticcall{gas: PROBE_ALLOWANCE}(call);
            assertFalse(ok, label[i]);
            assertEq(bytes4(ret), Halo2EzklAdapterV2.TargetGasExhausted.selector, label[i]);
        }
    }

    /// d = 5 leaves about 7.5% unspent, over the 1/16 line: it reads as a rejection. This is the
    /// depth that must not be registered, and the reason for that rule.
    function test_depth_5_reads_as_a_rejection_which_is_why_it_must_not_be_registered() public {
        (address[7] memory t,) = _chains();
        _assertStatus(_checkTarget(address(adapter), t[6]), ProofStatus.Invalid);
        _assertStatus(_checkTarget(address(adapterV2), t[6]), ProofStatus.Invalid);
    }

    // ── The 1/16 boundary ───────────────────────────────────────────────────────────────────────

    /// An adapter that answers `false` with `keep` gas left. Sweeping `keep` across allowance / 16,
    /// the answer must turn from Unverifiable to Invalid exactly once, within a few hundred gas of
    /// the line: below it, a `false` cannot be told from exhaustion.
    function test_check_boundary_is_one_sixteenth_of_the_allowance() public {
        uint32 allowance = PROBE_ALLOWANCE;
        uint256 line = allowance / 16;
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        uint256 flip;
        for (uint256 keep = line - 2_000; keep <= line + 2_000; keep += 25) {
            VerifierEntry memory e =
                _entry(address(new LeaveGasAdapter(keep)), address(0), 1, OUTPUT_SIZE, allowance, 0);
            ProofStatus s = _check(registry.register(e), e, c, o, p);
            if (flip == 0) {
                if (s == ProofStatus.Invalid) flip = keep;
                else _assertStatus(s, ProofStatus.Unverifiable);
            } else {
                _assertStatus(s, ProofStatus.Invalid);
            }
        }
        emit log_named_uint("allowance / 16", line);
        emit log_named_uint("least gas left at which a false reads as Invalid", flip);
        assertGt(flip, 0, "never Invalid");
        assertApproxEqAbs(flip, line, 300, "flip point");
    }

    /// The same sweep one level down: a target that rejects with `keep` gas left behind adapter V2.
    /// The adapter keeps 1/64 of its gas back from the call, so its line sits lower by about that
    /// much; what matters is that it flips once, from a revert to `false`, near allowance / 16.
    function test_adapter_v2_boundary_is_one_sixteenth_of_its_gas() public {
        uint256 allowance = PROBE_ALLOWANCE;
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        uint256 flip;
        uint256 start = allowance / 16 - allowance / 64 - 2_000;
        for (uint256 keep = start; keep <= allowance / 16 + 1_000; keep += 25) {
            bytes memory call =
                abi.encodeCall(IProofVerifier.verify, (address(new LeaveGasTarget(keep)), OUTPUT_SIZE, c, o, p));
            (bool ok, bytes memory ret) = address(adapterV2).staticcall{gas: allowance}(call);
            if (flip == 0) {
                if (ok) {
                    flip = keep;
                    assertFalse(abi.decode(ret, (bool)), "false, not true");
                } else {
                    assertEq(bytes4(ret), Halo2EzklAdapterV2.TargetGasExhausted.selector, "typed revert");
                }
            } else {
                assertTrue(ok, "once false, always false above");
                assertFalse(abi.decode(ret, (bool)), "false, not true");
            }
        }
        emit log_named_uint("allowance / 16", allowance / 16);
        emit log_named_uint("least gas the target leaves at which adapter v2 answers false", flip);
        assertGt(flip, start, "the sweep must start in the revert region");
        assertGt(flip, allowance / 16 - allowance / 64 - 1_000, "flip point, low side");
        assertLt(flip, allowance / 16, "flip point, high side");
    }

    // ── The real verifiers ──────────────────────────────────────────────────────────────────────

    /// The deployed entries, checked by this version of the check: valid stays Valid, an early
    /// rejection stays Invalid, but a rejection at the final pairing leaves less than 1/16 of the
    /// allowance and reads as Unverifiable. Fail-safe; the entries sized below answer Invalid.
    function test_deployed_entries_report_a_final_pairing_rejection_as_unverifiable() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        _assertStatus(_check(soloIdV1, soloEntryV1, c, o, p), ProofStatus.Valid);
        bytes memory wrong = bytes.concat(o);
        _setWord(wrong, 9, _word(wrong, 9) + 1);
        _assertStatus(_check(soloIdV1, soloEntryV1, c, wrong, p), ProofStatus.Unverifiable);
        bytes memory flipped = bytes.concat(p);
        flipped[7] = bytes1(uint8(flipped[7]) ^ 0x80);
        _assertStatus(_check(soloIdV1, soloEntryV1, c, o, flipped), ProofStatus.Invalid);

        (c, o, p) = _k8();
        _assertStatus(_check(k8IdV1, k8EntryV1, c, o, p), ProofStatus.Valid);
        wrong = bytes.concat(o);
        _setWord(wrong, wrong.length / 32 - 1, _word(wrong, wrong.length / 32 - 1) + 1);
        _assertStatus(_check(k8IdV1, k8EntryV1, c, wrong, p), ProofStatus.Unverifiable);
        flipped = bytes.concat(p);
        flipped[7] = bytes1(uint8(flipped[7]) ^ 0x80);
        _assertStatus(_check(k8IdV1, k8EntryV1, c, o, flipped), ProofStatus.Invalid);
    }

    function test_new_entries_report_every_real_rejection_as_invalid() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        _assertStatus(_check(soloId, soloEntry, c, o, p), ProofStatus.Valid);
        bytes memory wrong = bytes.concat(o);
        _setWord(wrong, 9, _word(wrong, 9) + 1);
        _assertStatus(_check(soloId, soloEntry, c, wrong, p), ProofStatus.Invalid);
        bytes memory flipped = bytes.concat(p);
        flipped[7] = bytes1(uint8(flipped[7]) ^ 0x80);
        _assertStatus(_check(soloId, soloEntry, c, o, flipped), ProofStatus.Invalid);

        (c, o, p) = _k8();
        _assertStatus(_check(k8Id, k8Entry, c, o, p), ProofStatus.Valid);
        wrong = bytes.concat(o);
        _setWord(wrong, wrong.length / 32 - 1, _word(wrong, wrong.length / 32 - 1) + 1);
        _assertStatus(_check(k8Id, k8Entry, c, wrong, p), ProofStatus.Invalid);
        flipped = bytes.concat(p);
        flipped[7] = bytes1(uint8(flipped[7]) ^ 0x80);
        _assertStatus(_check(k8Id, k8Entry, c, o, flipped), ProofStatus.Invalid);
    }

    /// The real solo verifier with a valid proof and an allowance too small for it, through both
    /// adapters: whatever the shortfall, the check never answers Invalid. This is the known issue
    /// itself: before this version, every one of these read as Invalid.
    function test_a_valid_proof_short_of_its_allowance_is_never_invalid() public {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        uint256 n;
        for (uint32 a = 300_000; a < 585_000; a += 7_500) {
            for (uint256 k = 0; k < 2; k++) {
                address ad = k == 0 ? address(adapter) : address(adapterV2);
                VerifierEntry memory e = _entry(ad, SOLO, 1, OUTPUT_SIZE, a, SOLO_VK_HASH);
                ProofStatus s = _check(registry.register(e), e, c, o, p);
                assertTrue(s != ProofStatus.Invalid, "a valid proof read as Invalid");
                if (s == ProofStatus.Unverifiable) n++;
            }
        }
        assertGt(n, 70, "the sweep must reach exhaustion");
    }

    /// The deployed adapter answered `false` when the real verifier ran out of gas inside it; V2
    /// reverts with a typed error instead.
    function test_adapter_v2_reverts_when_the_real_verifier_runs_out_of_gas() public view {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        bytes memory call = abi.encodeCall(IProofVerifier.verify, (SOLO, OUTPUT_SIZE, c, o, p));
        (bool ok, bytes memory ret) = address(adapterV2).staticcall{gas: 400_000}(call);
        assertFalse(ok);
        assertEq(bytes4(ret), Halo2EzklAdapterV2.TargetGasExhausted.selector);
        assertFalse(adapter.verify{gas: 400_000}(SOLO, OUTPUT_SIZE, c, o, p), "the deployed adapter: false");
    }

    // ── Sizing the new entries ──────────────────────────────────────────────────────────────────

    function _used(address a, address t, bytes32[] memory c, bytes memory o, bytes memory p)
        internal
        view
        returns (uint256 used)
    {
        bytes memory cd = abi.encodeCall(IProofVerifier.verify, (t, OUTPUT_SIZE, c, o, p));
        uint256 before;
        uint256 afterCall;
        bool ok;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0x00, 0)
            before := gas()
            ok := staticcall(2000000, a, add(cd, 0x20), mload(cd), 0x00, 0x20)
            afterCall := gas()
            word := mload(0x00)
        }
        assertTrue(ok && word == 1, "valid proof accepted");
        used = before - afterCall;
    }

    /// The first call in a transaction costs 5,000 more than a repeat with the same arguments: the
    /// EIP-2929 surcharge for a cold account, 2,500 for the adapter and 2,500 for the target. A
    /// check reads both code hashes before the call, so inside a check both are warm. The new
    /// entries are sized at 1.10 times the cold first call, which also covers a caller that calls
    /// the adapter without a check.
    function test_first_call_surcharge_is_eip2929_and_new_entries_are_sized_over_it() public {
        // Fresh adapter accounts in this transaction are already warm (created here), so use the
        // ones from setUp, which are cold.
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        uint256 cold = _used(address(adapterV2), SOLO, c, o, p);
        uint256 warm = _used(address(adapterV2), SOLO, c, o, p);
        assertEq(cold - warm, 5_000, "solo: adapter and target cold");
        emit log_named_uint("adapter v2, solo, valid proof, first call", cold);
        emit log_named_uint("adapter v2, solo, valid proof, repeat", warm);
        assertGe(uint256(SOLO_VERIFY_GAS_V2) * 100, cold * 110, "solo entry >= 1.10 x first call");
        assertLe(cold, 585_667, "pin: measured 585,667");

        (c, o, p) = _k8();
        cold = _used(address(adapterV2), K8, c, o, p);
        warm = _used(address(adapterV2), K8, c, o, p);
        assertEq(cold - warm, 2_500, "K=8: only the target cold, the adapter was touched above");
        emit log_named_uint("adapter v2, K=8, valid proof, first touch of the target", cold);
        emit log_named_uint("adapter v2, K=8, valid proof, repeat", warm);
        assertGe(uint256(K8_VERIFY_GAS_V2) * 100, (warm + 5_000) * 110, "K=8 entry >= 1.10 x first call");
        assertLe(warm + 5_000, 646_412, "pin: measured 646,412");
    }

    /// Gas used by one adapter call, whatever the answer.
    function _usedAny(address a, address t, bytes32[] memory c, bytes memory o, bytes memory p)
        internal
        view
        returns (uint256 used, uint256 word)
    {
        bytes memory cd = abi.encodeCall(IProofVerifier.verify, (t, OUTPUT_SIZE, c, o, p));
        uint256 before;
        uint256 afterCall;
        bool ok;
        assembly ("memory-safe") {
            mstore(0x00, 0)
            before := gas()
            ok := staticcall(2000000, a, add(cd, 0x20), mload(cd), 0x00, 0x20)
            afterCall := gas()
            word := mload(0x00)
        }
        assertTrue(ok, "answered");
        used = before - afterCall;
    }

    /// The deployed entries: gas a valid proof uses through the deployed adapter, cold (first call)
    /// and warm (inside a check), against the entry's allowance. docs/known-issues, "Affected entries".
    function test_headroom_of_the_deployed_solo_entry() public {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        (uint256 cold,) = _usedAny(address(adapter), SOLO, c, o, p);
        (uint256 warm, uint256 w) = _usedAny(address(adapter), SOLO, c, o, p);
        assertEq(w, 1);
        emit log_named_uint("deployed adapter, solo, first call", cold);
        emit log_named_uint("deployed adapter, solo, in a check", warm);
        emit log_named_uint("unspent of 600,000 in a check", SOLO_VERIFY_GAS - warm);
        assertEq(cold, 585_620, "pin");
        assertEq(warm, 580_620, "pin");
    }

    function test_headroom_of_the_deployed_k8_entry() public {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _k8();
        (uint256 cold,) = _usedAny(address(adapter), K8, c, o, p);
        (uint256 warm, uint256 w) = _usedAny(address(adapter), K8, c, o, p);
        assertEq(w, 1);
        emit log_named_uint("deployed adapter, K=8, first call", cold);
        emit log_named_uint("deployed adapter, K=8, in a check", warm);
        emit log_named_uint("unspent of 660,000 in a check", K8_VERIFY_GAS - warm);
        assertEq(cold, 646_365, "pin");
        assertEq(warm, 641_365, "pin");
    }

    /// A wrong output, rejected at the final pairing, inside a check (accounts warm): under the
    /// deployed allowances it leaves less than 1/16, under the new ones more.
    function test_wrong_output_against_both_allowances() public {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        _setWord(o, 9, _word(o, 9) + 1);
        assertTrue(address(adapter).codehash != 0 && address(adapterV2).codehash != 0 && SOLO.codehash != 0);
        (uint256 v1,) = _usedAny(address(adapter), SOLO, c, o, p);
        (uint256 v2, uint256 w) = _usedAny(address(adapterV2), SOLO, c, o, p);
        assertEq(w, 0, "rejected");
        emit log_named_uint("solo wrong output, deployed adapter", v1);
        emit log_named_uint("solo wrong output, adapter V2", v2);
        assertLt(SOLO_VERIFY_GAS - v1, SOLO_VERIFY_GAS / 16, "deployed: under 1/16");
        assertGt(SOLO_VERIFY_GAS_V2 - v2, SOLO_VERIFY_GAS_V2 / 16, "new: over 1/16");

        (c, o, p) = _k8();
        _setWord(o, o.length / 32 - 1, _word(o, o.length / 32 - 1) + 1);
        assertTrue(K8.codehash != 0);
        (v1,) = _usedAny(address(adapter), K8, c, o, p);
        (v2, w) = _usedAny(address(adapterV2), K8, c, o, p);
        assertEq(w, 0, "rejected");
        emit log_named_uint("K=8 wrong output, deployed adapter", v1);
        emit log_named_uint("K=8 wrong output, adapter V2", v2);
        assertLt(K8_VERIFY_GAS - v1, K8_VERIFY_GAS / 16, "deployed: under 1/16");
        assertGt(K8_VERIFY_GAS_V2 - v2, K8_VERIFY_GAS_V2 / 16, "new: over 1/16");
    }

    /// Warming the two accounts with EXTCODEHASH, as the check does, removes the surcharge.
    function test_extcodehash_removes_the_first_call_surcharge() public {
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        assertTrue(address(adapterV2).codehash != bytes32(0) && SOLO.codehash != bytes32(0));
        uint256 first = _used(address(adapterV2), SOLO, c, o, p);
        uint256 repeat = _used(address(adapterV2), SOLO, c, o, p);
        assertEq(first, repeat);
    }
}
