// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Fixtures} from "./fixtures/Fixtures.sol";
import {FixturesK8} from "./fixtures/FixturesK8.sol";
import {IProofVerifier} from "../src/IProofVerifier.sol";
import {IVerifierRegistry, VerifierEntry} from "../src/IVerifierRegistry.sol";
import {VerifierRegistry} from "../src/VerifierRegistry.sol";
import {Halo2EzklAdapter} from "../src/Halo2EzklAdapter.sol";
import {Halo2EzklAdapterV2} from "../src/Halo2EzklAdapterV2.sol";
import {ProofStatus} from "../src/ProofCheck.sol";
import {ProofCheckHarness} from "./mocks/Mocks.sol";

interface IHalo2Verifier {
    function verifyProof(bytes calldata proof, uint256[] calldata instances) external returns (bool);
}

/// Shared setup: the two pinned verifiers, the registry, the EZKL adapter, and both circuits
/// registered.
abstract contract ProofCoreBase is Test {
    address internal constant SOLO = address(0x5010);
    address internal constant K8 = address(0x5080);

    // keccak256(vk.key), from circuits/spike-mlp/MANIFEST.md.
    bytes32 internal constant SOLO_VK_HASH = 0x13cff0426abe00c941934bdd6bb7757f2e703fb9f6862bf08a783eeca08b4ff2;
    bytes32 internal constant K8_VK_HASH = 0xdd03fb0c69e96cc02cbcc6bed8ef51665f934c01cddaf2a855bd1c7fce94675f;

    // Gas inside verifyProof for the stored proofs (test/FixtureBaseline.t.sol pins these).
    uint256 internal constant SOLO_DIRECT_GAS = 577_544;
    uint256 internal constant K8_DIRECT_GAS = 635_807;

    // Gas the registry entries hand to the adapter.
    uint32 internal constant SOLO_VERIFY_GAS = 600_000;
    uint32 internal constant K8_VERIFY_GAS = 660_000;
    /// Allowances of the entries for `Halo2EzklAdapterV2`: at least 1.10 times the verifier's valid
    /// path on a first call (cold accounts), so that a genuine rejection leaves more than 1/16 of
    /// the allowance unspent (docs/known-issues/2026-11-out-of-gas-as-invalid.md).
    uint32 internal constant SOLO_VERIFY_GAS_V2 = 645_000;
    uint32 internal constant K8_VERIFY_GAS_V2 = 712_000;

    uint32 internal constant OUTPUT_SIZE = 320; // 10 field elements per lane

    // Order of the BN254 scalar field.
    uint256 internal constant R = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

    VerifierRegistry internal registry;
    Halo2EzklAdapter internal adapter; // the deployed adapter (v3.0.0-testnet)
    Halo2EzklAdapterV2 internal adapterV2;
    ProofCheckHarness internal harness;

    // The entries every consumer test runs against: adapter V2 with allowances sized for the 1/16
    // rule, as v3.1 registers them.
    VerifierEntry internal soloEntry;
    VerifierEntry internal k8Entry;
    bytes32 internal soloId;
    bytes32 internal k8Id;
    // The entries registered on the testnet for v3.0.0-testnet: the deployed adapter, 600,000 and
    // 660,000. Immutable; kept for the deployment tests and docs/known-issues.
    VerifierEntry internal soloEntryV1;
    VerifierEntry internal k8EntryV1;
    bytes32 internal soloIdV1;
    bytes32 internal k8IdV1;

    function setUp() public virtual {
        vm.etch(SOLO, Fixtures.verifierBytecode());
        vm.etch(K8, FixturesK8.verifierBytecode());
        registry = new VerifierRegistry();
        adapter = new Halo2EzklAdapter();
        adapterV2 = new Halo2EzklAdapterV2();
        harness = new ProofCheckHarness(registry);

        soloEntryV1 = _entry(address(adapter), SOLO, 1, OUTPUT_SIZE, SOLO_VERIFY_GAS, SOLO_VK_HASH);
        k8EntryV1 = _entry(address(adapter), K8, 8, OUTPUT_SIZE, K8_VERIFY_GAS, K8_VK_HASH);
        soloIdV1 = registry.register(soloEntryV1);
        k8IdV1 = registry.register(k8EntryV1);
        soloEntry = _entry(address(adapterV2), SOLO, 1, OUTPUT_SIZE, SOLO_VERIFY_GAS_V2, SOLO_VK_HASH);
        k8Entry = _entry(address(adapterV2), K8, 8, OUTPUT_SIZE, K8_VERIFY_GAS_V2, K8_VK_HASH);
        soloId = registry.register(soloEntry);
        k8Id = registry.register(k8Entry);
    }

    function _entry(address adapter_, address target, uint32 lanes, uint32 outputSize, uint32 verifyGas, bytes32 vkHash)
        internal
        view
        returns (VerifierEntry memory)
    {
        return VerifierEntry({
            adapter: adapter_,
            lanes: lanes,
            outputSize: outputSize,
            verifyGas: verifyGas,
            target: target,
            adapterCodeHash: adapter_.codehash,
            targetCodeHash: target == address(0) ? bytes32(0) : target.codehash,
            vkHash: vkHash,
            emptyLane: bytes32(0)
        });
    }

    /// Split a generated verifier's instance array into what an adapter is given.
    function _split(uint256[] memory instances, uint256 lanes)
        internal
        pure
        returns (bytes32[] memory commitments, bytes memory outputs)
    {
        commitments = new bytes32[](lanes);
        for (uint256 i = 0; i < lanes; i++) {
            commitments[i] = bytes32(instances[i]);
        }
        uint256 n = instances.length - lanes;
        outputs = new bytes(n * 32);
        for (uint256 j = 0; j < n; j++) {
            uint256 v = instances[lanes + j];
            assembly ("memory-safe") {
                mstore(add(add(outputs, 0x20), mul(j, 0x20)), v)
            }
        }
    }

    function _solo() internal pure returns (bytes32[] memory commitments, bytes memory outputs, bytes memory proof) {
        (commitments, outputs) = _split(Fixtures.instances(), 1);
        proof = Fixtures.proofBytes();
    }

    function _k8() internal pure returns (bytes32[] memory commitments, bytes memory outputs, bytes memory proof) {
        (commitments, outputs) = _split(FixturesK8.instances(), 8);
        proof = FixturesK8.proofBytes();
    }

    /// Overwrite one 32-byte word of `data`.
    function _setWord(bytes memory data, uint256 index, uint256 value) internal pure {
        assembly ("memory-safe") {
            mstore(add(add(data, 0x20), mul(index, 0x20)), value)
        }
    }

    function _word(bytes memory data, uint256 index) internal pure returns (uint256 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), mul(index, 0x20)))
        }
    }

    function _assertStatus(ProofStatus actual, ProofStatus expected) internal pure {
        assertEq(uint8(actual), uint8(expected), "proof status");
    }
}
