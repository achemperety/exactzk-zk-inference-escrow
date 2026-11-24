// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Fixtures} from "./fixtures/Fixtures.sol";
import {FixturesK8} from "./fixtures/FixturesK8.sol";

interface IHalo2Verifier {
    function verifyProof(bytes calldata proof, uint256[] calldata instances) external returns (bool);
}

/// The stored proofs, the pinned verifier bytecode and the gas baseline, checked directly against
/// the generated verifiers. Nothing from src/ is involved: this is the ground the rest stands on.
contract FixtureBaselineTest is Test {
    address internal constant SOLO = address(0x5010);
    address internal constant K8 = address(0x5080);

    // keccak256 of the pinned runtime bytecode (circuits/spike-mlp/MANIFEST.md).
    bytes32 internal constant SOLO_RUNTIME_HASH = 0x8cd0b80f6b67e187a9ee98478fdd1278b8e1b666d666d442920aaf911f485f49;
    bytes32 internal constant K8_RUNTIME_HASH = 0x471c8109f1a03375b17ae6afd421f5857346edf92bf37fce1c7b90a3e02d7ef1;

    // Gas used inside verifyProof for the stored proofs, as measured on the previous contracts.
    uint256 internal constant SOLO_VERIFY_GAS = 577_544;
    uint256 internal constant K8_VERIFY_GAS = 635_807;

    function setUp() public {
        vm.etch(SOLO, Fixtures.verifierBytecode());
        vm.etch(K8, FixturesK8.verifierBytecode());
    }

    function _accepts(address verifier, bytes memory proof, uint256[] memory instances) internal returns (bool) {
        (bool ok, bytes memory ret) = verifier.call(abi.encodeCall(IHalo2Verifier.verifyProof, (proof, instances)));
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1;
    }

    function test_solo_proof_verifies_on_generated_verifier() public {
        assertTrue(IHalo2Verifier(SOLO).verifyProof(Fixtures.proofBytes(), Fixtures.instances()));
    }

    function test_k8_proof_verifies_on_generated_verifier() public {
        assertTrue(IHalo2Verifier(K8).verifyProof(FixturesK8.proofBytes(), FixturesK8.instances()));
    }

    function test_pinned_bytecode_hashes() public view {
        assertEq(SOLO.codehash, SOLO_RUNTIME_HASH, "solo verifier bytecode changed");
        assertEq(K8.codehash, K8_RUNTIME_HASH, "K=8 verifier bytecode changed");
        bytes memory fromFile = vm.parseBytes(vm.readFile("test/fixtures/verifier_runtime.hex"));
        assertEq(keccak256(fromFile), SOLO_RUNTIME_HASH, "verifier_runtime.hex differs from Fixtures.sol");
    }

    function test_instance_layout() public pure {
        uint256[] memory solo = Fixtures.instances();
        assertEq(solo.length, 1 + Fixtures.NUM_OUTPUTS);
        assertEq(solo[0], Fixtures.INPUT_COMMITMENT);

        uint256[] memory k8 = FixturesK8.instances();
        assertEq(k8.length, FixturesK8.K * (1 + FixturesK8.NUM_OUTPUTS));
        for (uint256 lane = 0; lane < FixturesK8.K; lane++) {
            assertEq(k8[FixturesK8.HASH_BASE + lane], FixturesK8.laneCommitment(lane));
        }
        assertEq(FixturesK8.OUT_BASE, FixturesK8.K);
    }

    function test_verifier_gas_baseline_solo() public {
        IHalo2Verifier(SOLO).verifyProof(Fixtures.proofBytes(), Fixtures.instances());
        Vm.Gas memory g = vm.lastCallGas();
        assertEq(g.gasTotalUsed, SOLO_VERIFY_GAS, "solo verifyProof gas moved");
    }

    function test_verifier_gas_baseline_k8() public {
        IHalo2Verifier(K8).verifyProof(FixturesK8.proofBytes(), FixturesK8.instances());
        Vm.Gas memory g = vm.lastCallGas();
        assertEq(g.gasTotalUsed, K8_VERIFY_GAS, "K=8 verifyProof gas moved");
    }

    function test_tampered_proof_is_rejected() public {
        bytes memory proof = Fixtures.proofBytes();
        proof[proof.length / 2] = bytes1(uint8(proof[proof.length / 2]) ^ 0x01);
        assertFalse(_accepts(SOLO, proof, Fixtures.instances()));
    }

    function test_wrong_output_is_rejected() public {
        uint256[] memory instances = Fixtures.instances();
        instances[1] = instances[1] + 1;
        assertFalse(_accepts(SOLO, Fixtures.proofBytes(), instances));
    }

    function test_proof_for_one_circuit_fails_on_the_other() public {
        assertFalse(_accepts(K8, Fixtures.proofBytes(), FixturesK8.instances()));
        assertFalse(_accepts(SOLO, FixturesK8.proofBytes(), Fixtures.instances()));
    }
}
