// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProofCoreBase} from "./ProofCoreBase.sol";
import {IVerifierRegistry, VerifierEntry} from "../src/IVerifierRegistry.sol";
import {VerifierRegistry} from "../src/VerifierRegistry.sol";
import {Halo2EzklAdapterV2} from "../src/Halo2EzklAdapterV2.sol";
import {
    AcceptAllTarget,
    RejectAllTarget,
    AlwaysTrueAdapter,
    AlwaysFalseAdapter,
    TEST_PROOF_SYSTEM
} from "./mocks/Mocks.sol";

contract VerifierRegistryTest is ProofCoreBase {
    bytes32 internal constant EZKL = keccak256("halo2-kzg-bn254/ezkl");

    function _id(bytes32 system, VerifierEntry memory e) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                system, e.vkHash, e.targetCodeHash, e.adapterCodeHash, e.lanes, e.outputSize, e.verifyGas, e.emptyLane
            )
        );
    }

    function _assertSame(VerifierEntry memory a, VerifierEntry memory b) internal pure {
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), "entry");
    }

    // ── Registration ────────────────────────────────────────────────────────────────────────────

    function test_register_stores_the_entry_and_emits_it() public {
        VerifierRegistry fresh = new VerifierRegistry();
        bytes32 expectedId = _id(EZKL, soloEntry);

        vm.expectEmit(true, true, true, true, address(fresh));
        emit IVerifierRegistry.VerifierRegistered(
            expectedId,
            SOLO_VK_HASH,
            SOLO,
            soloEntry.adapter,
            soloEntry.adapter.codehash,
            SOLO.codehash,
            EZKL,
            1,
            OUTPUT_SIZE,
            SOLO_VERIFY_GAS_V2,
            bytes32(0)
        );
        bytes32 id = fresh.register(soloEntry);

        assertEq(id, expectedId);
        assertTrue(fresh.exists(id));
        assertEq(fresh.entryHash(id), keccak256(abi.encode(soloEntry)));
        _assertSame(fresh.entry(id), soloEntry);
    }

    function test_id_is_computed_from_content() public view {
        assertEq(soloId, _id(EZKL, soloEntry));
        assertEq(k8Id, _id(EZKL, k8Entry));
        assertEq(registry.computeId(EZKL, soloEntry), soloId);
        assertTrue(soloId != k8Id);
    }

    function test_anyone_can_register() public {
        VerifierRegistry fresh = new VerifierRegistry();
        vm.prank(makeAddr("stranger"));
        bytes32 id = fresh.register(k8Entry);
        assertTrue(fresh.exists(id));
    }

    function test_unknown_id_reads_as_empty() public view {
        bytes32 unknown = keccak256("unknown");
        assertFalse(registry.exists(unknown));
        assertEq(registry.entryHash(unknown), bytes32(0));
        VerifierEntry memory e = registry.entry(unknown);
        assertEq(e.adapter, address(0));
        assertEq(e.lanes, 0);
    }

    // ── Append-only ─────────────────────────────────────────────────────────────────────────────

    function test_registering_the_same_entry_again_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IVerifierRegistry.AlreadyRegistered.selector, soloId));
        registry.register(soloEntry);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(IVerifierRegistry.AlreadyRegistered.selector, soloId));
        registry.register(soloEntry);
    }

    /// The same code at other addresses has the same id, so it cannot be registered a second time,
    /// and the attempt leaves the first entry as it was.
    function test_same_code_at_other_addresses_cannot_replace_an_entry() public {
        address otherTarget = makeAddr("second copy of the solo verifier");
        vm.etch(otherTarget, SOLO.code);
        Halo2EzklAdapterV2 otherAdapter = new Halo2EzklAdapterV2();
        VerifierEntry memory copy =
            _entry(address(otherAdapter), otherTarget, 1, OUTPUT_SIZE, SOLO_VERIFY_GAS_V2, SOLO_VK_HASH);
        assertEq(_id(EZKL, copy), soloId, "same content, same id");

        vm.expectRevert(abi.encodeWithSelector(IVerifierRegistry.AlreadyRegistered.selector, soloId));
        registry.register(copy);

        _assertSame(registry.entry(soloId), soloEntry);
        assertEq(registry.entryHash(soloId), keccak256(abi.encode(soloEntry)));
    }

    // ── What the id commits to ──────────────────────────────────────────────────────────────────

    function test_always_true_and_always_false_adapters_have_distinct_ids() public {
        address yes = address(new AlwaysTrueAdapter());
        address no = address(new AlwaysFalseAdapter());
        // Identical in every field except the adapter, and both adapters report the same proof
        // system: the only thing that separates the ids is the adapter's code hash.
        VerifierEntry memory a = _entry(yes, SOLO, 1, OUTPUT_SIZE, SOLO_VERIFY_GAS, SOLO_VK_HASH);
        VerifierEntry memory b = _entry(no, SOLO, 1, OUTPUT_SIZE, SOLO_VERIFY_GAS, SOLO_VK_HASH);

        bytes32 idA = registry.register(a);
        bytes32 idB = registry.register(b);

        assertTrue(idA != idB, "adapters with different code share an id");
        assertTrue(idA != soloId && idB != soloId);
        assertEq(idA, _id(TEST_PROOF_SYSTEM, a));
        assertEq(idB, _id(TEST_PROOF_SYSTEM, b));
        assertEq(registry.entry(idA).adapter, yes);
        assertEq(registry.entry(idB).adapter, no);
    }

    function test_every_field_but_the_addresses_changes_the_id() public {
        VerifierEntry memory e = soloEntry;
        bytes32 base = registry.computeId(EZKL, e);

        e.vkHash = keccak256("another key");
        assertTrue(registry.computeId(EZKL, e) != base, "vkHash");
        e = soloEntry;
        e.lanes = 2;
        assertTrue(registry.computeId(EZKL, e) != base, "lanes");
        e = soloEntry;
        e.outputSize = 352;
        assertTrue(registry.computeId(EZKL, e) != base, "outputSize");
        e = soloEntry;
        e.verifyGas = SOLO_VERIFY_GAS + 1;
        assertTrue(registry.computeId(EZKL, e) != base, "verifyGas");
        e = soloEntry;
        e.emptyLane = bytes32(uint256(1));
        assertTrue(registry.computeId(EZKL, e) != base, "emptyLane");
        e = soloEntry;
        e.targetCodeHash = K8.codehash;
        assertTrue(registry.computeId(EZKL, e) != base, "targetCodeHash");
        e = soloEntry;
        e.adapterCodeHash = keccak256("other adapter code");
        assertTrue(registry.computeId(EZKL, e) != base, "adapterCodeHash");
        assertTrue(registry.computeId(TEST_PROOF_SYSTEM, soloEntry) != base, "proofSystem");

        e = soloEntry;
        e.adapter = makeAddr("elsewhere");
        e.target = makeAddr("elsewhere too");
        assertEq(registry.computeId(EZKL, e), base, "addresses are not part of the id");
    }

    /// An entry that differs only in the gas allowance is a different verifier. Nobody can spoil
    /// an id for others by registering it first with an allowance that is too small or too large.
    function test_gas_allowance_is_part_of_the_id() public {
        VerifierEntry memory tooSmall = soloEntry;
        tooSmall.verifyGas = 1;
        bytes32 id = registry.register(tooSmall);
        assertTrue(id != soloId);
        assertEq(registry.entry(soloId).verifyGas, SOLO_VERIFY_GAS_V2);
        assertEq(registry.entry(id).verifyGas, 1);
    }

    // ── Code must be what the entry declares ────────────────────────────────────────────────────

    function test_wrong_adapter_code_hash_reverts() public {
        VerifierEntry memory e = soloEntry;
        e.vkHash = keccak256("fresh");
        e.adapterCodeHash = keccak256("not the adapter");
        vm.expectRevert(
            abi.encodeWithSelector(
                IVerifierRegistry.CodeHashMismatch.selector,
                address(adapterV2),
                e.adapterCodeHash,
                address(adapterV2).codehash
            )
        );
        registry.register(e);
    }

    function test_wrong_target_code_hash_reverts() public {
        VerifierEntry memory e = soloEntry;
        e.vkHash = keccak256("fresh");
        e.targetCodeHash = K8.codehash;
        vm.expectRevert(
            abi.encodeWithSelector(IVerifierRegistry.CodeHashMismatch.selector, SOLO, K8.codehash, SOLO.codehash)
        );
        registry.register(e);
    }

    function test_account_without_code_reverts() public {
        address empty = makeAddr("account without code");
        vm.deal(empty, 1); // make the account exist, so its code hash is the hash of empty code

        VerifierEntry memory e = soloEntry;
        e.vkHash = keccak256("fresh");
        e.target = empty;
        e.targetCodeHash = empty.codehash;
        vm.expectRevert(abi.encodeWithSelector(IVerifierRegistry.NoCode.selector, empty));
        registry.register(e);

        e = soloEntry;
        e.vkHash = keccak256("fresh");
        e.adapter = empty;
        e.adapterCodeHash = empty.codehash;
        vm.expectRevert(abi.encodeWithSelector(IVerifierRegistry.NoCode.selector, empty));
        registry.register(e);
    }

    /// An account whose code is an EIP-7702 delegation designator keeps the same code hash while
    /// the code that runs is somebody else's. It must not be accepted as an adapter or a target.
    function test_delegated_account_reverts() public {
        address delegated = makeAddr("delegated account");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(new AcceptAllTarget())));

        VerifierEntry memory e = soloEntry;
        e.vkHash = keccak256("fresh");
        e.target = delegated;
        e.targetCodeHash = delegated.codehash;
        vm.expectRevert(abi.encodeWithSelector(IVerifierRegistry.DelegatedAccount.selector, delegated));
        registry.register(e);

        e = soloEntry;
        e.vkHash = keccak256("fresh");
        e.adapter = delegated;
        e.adapterCodeHash = delegated.codehash;
        vm.expectRevert(abi.encodeWithSelector(IVerifierRegistry.DelegatedAccount.selector, delegated));
        registry.register(e);
    }

    // ── Malformed entries ───────────────────────────────────────────────────────────────────────

    function test_target_hash_without_target_reverts() public {
        VerifierEntry memory e = _entry(address(new AlwaysTrueAdapter()), address(0), 1, 32, 100_000, bytes32(0));
        e.targetCodeHash = keccak256("something");
        vm.expectRevert(IVerifierRegistry.TargetHashWithoutTarget.selector);
        registry.register(e);

        e.targetCodeHash = bytes32(0);
        bytes32 id = registry.register(e);
        assertEq(registry.entry(id).target, address(0), "an adapter that needs no target can be registered");
    }

    function test_zero_lanes_reverts() public {
        VerifierEntry memory e = soloEntry;
        e.lanes = 0;
        vm.expectRevert(IVerifierRegistry.ZeroLanes.selector);
        registry.register(e);
    }

    function test_zero_verify_gas_reverts() public {
        VerifierEntry memory e = soloEntry;
        e.verifyGas = 0;
        vm.expectRevert(IVerifierRegistry.ZeroVerifyGas.selector);
        registry.register(e);
    }

    // ── Cost, for the record ────────────────────────────────────────────────────────────────────

    function test_registration_gas() public {
        VerifierRegistry fresh = new VerifierRegistry();
        fresh.register(soloEntry);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint("register(), first entry", used);
        assertLe(used, 150_500, "pin: measured 148,005");
    }
}
