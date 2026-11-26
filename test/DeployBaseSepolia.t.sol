// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProofCoreBase, IHalo2Verifier} from "./ProofCoreBase.sol";
import {Fixtures} from "./fixtures/Fixtures.sol";
import {FixturesK8} from "./fixtures/FixturesK8.sol";
import {MockERC3009} from "./mocks/MockERC3009.sol";
import {ReferenceDeploy} from "./external/ReferenceDeploy.sol";
import {DeployBaseSepolia} from "../script/DeployBaseSepolia.s.sol";
import {IdentityRegistryUpgradeable} from "lib/erc-8004-contracts/contracts/IdentityRegistryUpgradeable.sol";
import {ValidationRegistryUpgradeable} from "lib/erc-8004-contracts/contracts/ValidationRegistryUpgradeable.sol";
// Imported so that Forge compiles them; they are placed with `deployCodeTo` below.
import {AuthCaptureEscrow} from "lib/commerce-payments/src/AuthCaptureEscrow.sol";
import {ERC3009PaymentCollector} from "lib/commerce-payments/src/collectors/ERC3009PaymentCollector.sol";

/// The deployment script with the chain it expects replaced by local copies: the ERC-8004 reference
/// registries, x402's escrow and collector built from source at the canonical addresses, and the test
/// token at the USDC address. Everything else is the script's own code.
contract DeployBaseSepoliaHarness is DeployBaseSepolia {
    Expected internal expected;

    function expect(Expected memory c) external {
        expected = c;
    }

    function _chain() internal view override returns (Expected memory) {
        return expected;
    }
}

contract DeployBaseSepoliaTest is ProofCoreBase {
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant ESCROW = 0xf96815976523E00e65Be8f34cA5e64b4f41EB19c;
    address internal constant COLLECTOR = 0x8612dfdc421f80336cd14E8EF9cb1E765dB5ab88;
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    bytes32 internal constant SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // circuits/spike-mlp/MANIFEST.md, typed here again so that the script's copy is checked.
    bytes32 internal constant MANIFEST_SOLO_CODE_HASH =
        0x8cd0b80f6b67e187a9ee98478fdd1278b8e1b666d666d442920aaf911f485f49;
    bytes32 internal constant MANIFEST_K8_CODE_HASH =
        0x471c8109f1a03375b17ae6afd421f5857346edf92bf37fce1c7b90a3e02d7ef1;

    DeployBaseSepoliaHarness internal script;
    DeployBaseSepolia.Expected internal chain;

    function setUp() public override {
        super.setUp();
        vm.chainId(84532);
        deployCodeTo("MockERC3009.sol:MockERC3009", USDC);
        deployCodeTo("AuthCaptureEscrow.sol:AuthCaptureEscrow", ESCROW);
        deployCodeTo("ERC3009PaymentCollector.sol:ERC3009PaymentCollector", abi.encode(ESCROW, MULTICALL3), COLLECTOR);
        (IdentityRegistryUpgradeable identity, ValidationRegistryUpgradeable validation) = ReferenceDeploy.erc8004();

        chain = DeployBaseSepolia.Expected({
            chainId: 84532,
            usdc: USDC,
            validationRegistry: address(validation),
            validationImplementation: address(uint160(uint256(vm.load(address(validation), SLOT)))),
            identityRegistry: address(identity),
            identityImplementation: address(uint160(uint256(vm.load(address(identity), SLOT)))),
            escrow: ESCROW,
            escrowCodeHash: ESCROW.codehash,
            collector: COLLECTOR,
            collectorCodeHash: COLLECTOR.codehash
        });
        script = new DeployBaseSepoliaHarness();
        script.expect(chain);
        MockERC3009(USDC).mint(DEFAULT_SENDER, 2);
    }

    function test_deploys_the_pinned_verifiers_and_everything_the_notes_list() public {
        DeployBaseSepolia.Deployment memory d = script.run();

        assertEq(d.deployer, DEFAULT_SENDER, "the broadcaster deploys");
        assertEq(d.soloVerifier.codehash, MANIFEST_SOLO_CODE_HASH, "solo verifier: the pinned bytes");
        assertEq(d.k8Verifier.codehash, MANIFEST_K8_CODE_HASH, "K=8 verifier: the pinned bytes");
        assertEq(d.soloId, soloIdV1, "solo id: the id the tests compute");
        assertEq(d.k8Id, k8IdV1, "K=8 id: the id the tests compute");
        assertTrue(d.registry.exists(d.soloId) && d.registry.exists(d.k8Id), "both registered");

        // The deployed verifiers accept the stored proofs.
        assertTrue(IHalo2Verifier(d.soloVerifier).verifyProof(Fixtures.proofBytes(), Fixtures.instances()), "solo");
        assertTrue(IHalo2Verifier(d.k8Verifier).verifyProof(FixturesK8.proofBytes(), FixturesK8.instances()), "K=8");

        assertEq(MockERC3009(USDC).balanceOf(address(d.solo)), 1, "SoloSettlement seed");
        assertEq(MockERC3009(USDC).balanceOf(address(d.channel)), 1, "ChannelSettlement seed");
        assertEq(MockERC3009(USDC).balanceOf(DEFAULT_SENDER), 0, "both units came from the deployer");

        assertEq(address(d.solo.registry()), address(d.registry), "SoloSettlement registry");
        assertEq(address(d.channel.registry()), address(d.registry), "ChannelSettlement registry");
        assertEq(address(d.evaluator.registry()), address(d.registry), "evaluator registry");
        assertEq(address(d.validator.registry()), address(d.registry), "validator registry");
        assertEq(address(d.validator.validationRegistry()), chain.validationRegistry, "validator's ERC-8004 registry");
        assertEq(address(d.operator.registry()), address(d.registry), "operator registry");
        assertEq(address(d.operator.escrow()), ESCROW, "operator escrow");
    }

    function test_refuses_another_chain() public {
        vm.chainId(8453);
        vm.expectRevert(bytes("preflight: wrong chain"));
        script.run();
    }

    function test_refuses_a_changed_validation_registry_implementation() public {
        vm.store(chain.validationRegistry, SLOT, bytes32(uint256(uint160(makeAddr("new implementation")))));
        vm.expectRevert(bytes("preflight: Validation Registry implementation changed"));
        script.run();
    }

    function test_refuses_a_validation_registry_linked_to_another_identity_registry() public {
        chain.identityRegistry = makeAddr("another identity registry");
        script.expect(chain);
        vm.expectRevert(bytes("preflight: Validation Registry points at another Identity Registry"));
        script.run();
    }

    function test_refuses_a_changed_identity_registry_implementation() public {
        vm.store(chain.identityRegistry, SLOT, bytes32(uint256(uint160(makeAddr("new implementation")))));
        vm.expectRevert(bytes("preflight: Identity Registry implementation changed"));
        script.run();
    }

    function test_refuses_other_escrow_code() public {
        vm.etch(ESCROW, hex"00");
        vm.expectRevert(bytes("preflight: escrow code differs"));
        script.run();
    }

    function test_refuses_other_collector_code() public {
        vm.etch(COLLECTOR, hex"00");
        vm.expectRevert(bytes("preflight: collector code differs"));
        script.run();
    }

    function test_refuses_a_collector_that_serves_another_escrow() public {
        address other = makeAddr("collector for another escrow");
        deployCodeTo(
            "ERC3009PaymentCollector.sol:ERC3009PaymentCollector",
            abi.encode(makeAddr("another escrow"), MULTICALL3),
            other
        );
        chain.collector = other;
        chain.collectorCodeHash = other.codehash;
        script.expect(chain);
        vm.expectRevert(bytes("preflight: collector serves another escrow"));
        script.run();
    }

    function test_refuses_a_deployer_without_the_two_seed_units() public {
        vm.prank(DEFAULT_SENDER);
        MockERC3009(USDC).transfer(address(1), 1);
        vm.expectRevert(bytes("preflight: deployer needs 2 units of USDC for the seeds"));
        script.run();
    }
}
