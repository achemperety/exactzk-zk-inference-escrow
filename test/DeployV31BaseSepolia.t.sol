// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProofCoreBase} from "./ProofCoreBase.sol";
import {MockERC3009} from "./mocks/MockERC3009.sol";
import {ReferenceDeploy} from "./external/ReferenceDeploy.sol";
import {DeployBaseSepolia} from "../script/DeployBaseSepolia.s.sol";
import {DeployV31BaseSepolia} from "../script/DeployV31BaseSepolia.s.sol";
import {DeployBaseSepoliaHarness} from "./DeployBaseSepolia.t.sol";
import {ProofStatus} from "../src/ProofCheck.sol";
import {ProofCheckHarness} from "./mocks/Mocks.sol";
import {VerifierRegistry} from "../src/VerifierRegistry.sol";
import {IdentityRegistryUpgradeable} from "lib/erc-8004-contracts/contracts/IdentityRegistryUpgradeable.sol";
import {ValidationRegistryUpgradeable} from "lib/erc-8004-contracts/contracts/ValidationRegistryUpgradeable.sol";
import {AuthCaptureEscrow} from "lib/commerce-payments/src/AuthCaptureEscrow.sol";
import {ERC3009PaymentCollector} from "lib/commerce-payments/src/collectors/ERC3009PaymentCollector.sol";

/// The v3.1 script against local copies: the chain as in the v3.0 test, and the v3.0 deployment made
/// first by the v3.0 script itself.
contract DeployV31BaseSepoliaHarness is DeployV31BaseSepolia {
    Expected internal expected;
    V30 internal old;

    function expect(Expected memory c, V30 memory o) external {
        expected = c;
        old = o;
    }

    function _chain() internal view override returns (Expected memory) {
        return expected;
    }

    function _v30() internal view override returns (V30 memory) {
        return old;
    }
}

contract DeployV31BaseSepoliaTest is ProofCoreBase {
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant ESCROW = 0xf96815976523E00e65Be8f34cA5e64b4f41EB19c;
    address internal constant COLLECTOR = 0x8612dfdc421f80336cd14E8EF9cb1E765dB5ab88;
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    bytes32 internal constant SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    DeployBaseSepolia.Expected internal chain;
    DeployBaseSepolia.Deployment internal v30;
    DeployV31BaseSepoliaHarness internal script;

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
        DeployBaseSepoliaHarness first = new DeployBaseSepoliaHarness();
        first.expect(chain);
        MockERC3009(USDC).mint(DEFAULT_SENDER, 4);
        v30 = first.run();

        script = new DeployV31BaseSepoliaHarness();
        script.expect(chain, DeployV31BaseSepolia.V30(v30.registry, v30.soloVerifier, v30.k8Verifier));
    }

    function test_run_refuses_so_this_file_never_deploys_v30() public {
        vm.expectRevert(bytes("DeployV31BaseSepolia: run with --sig 'runV31()'"));
        script.run();
    }

    function test_deploys_v31_into_the_v30_registry() public {
        DeployV31BaseSepolia.DeploymentV31 memory d = script.runV31();

        assertEq(address(d.registry), address(v30.registry), "the v3.0 registry");
        assertEq(d.soloId, soloId, "solo id: the id the tests compute for adapter V2 at 645,000");
        assertEq(d.k8Id, k8Id, "K=8 id: the id the tests compute for adapter V2 at 712,000");
        assertTrue(d.registry.exists(v30.soloId) && d.registry.exists(v30.k8Id), "v3.0 entries untouched");
        assertEq(address(d.registry.entry(d.soloId).adapter).codehash, address(adapterV2).codehash, "adapter V2");
        assertEq(d.registry.entry(d.soloId).target, v30.soloVerifier, "solo: the v3.0 verifier");
        assertEq(d.registry.entry(d.k8Id).target, v30.k8Verifier, "K=8: the v3.0 verifier");

        assertEq(MockERC3009(USDC).balanceOf(address(d.solo)), 1, "SoloSettlement seed");
        assertEq(MockERC3009(USDC).balanceOf(address(d.channel)), 1, "ChannelSettlement seed");
        assertEq(MockERC3009(USDC).balanceOf(DEFAULT_SENDER), 0, "all four units came from the deployer");
        assertTrue(address(d.solo) != address(v30.solo) && address(d.operator) != address(v30.operator), "new");
        assertEq(address(d.validator.validationRegistry()), chain.validationRegistry, "validator's ERC-8004 registry");
        assertEq(address(d.operator.escrow()), ESCROW, "operator escrow");
    }

    /// The new entry answers Invalid for a wrong output; the v3.0 entry, through this check,
    /// answers Unverifiable (docs/known-issues/2026-11-out-of-gas-as-invalid.md).
    function test_the_new_solo_entry_reports_a_wrong_output_as_invalid() public {
        DeployV31BaseSepolia.DeploymentV31 memory d = script.runV31();
        ProofCheckHarness h = new ProofCheckHarness(d.registry);
        (bytes32[] memory c, bytes memory o, bytes memory p) = _solo();
        _setWord(o, 0, _word(o, 0) + 1);
        _assertStatus(h.checkWithEntry(d.soloId, d.registry.entry(d.soloId), c, o, p), ProofStatus.Invalid);
        _assertStatus(h.checkWithEntry(v30.soloId, d.registry.entry(v30.soloId), c, o, p), ProofStatus.Unverifiable);
    }

    function test_refuses_a_registry_without_the_v30_entries() public {
        script.expect(chain, DeployV31BaseSepolia.V30(new VerifierRegistry(), v30.soloVerifier, v30.k8Verifier));
        vm.expectRevert(bytes("preflight: v3.0 entries missing"));
        script.runV31();
    }

    function test_refuses_a_registry_whose_code_is_not_verifier_registry() public {
        vm.etch(address(v30.registry), hex"600160005260206000f3");
        vm.expectRevert(bytes("preflight: the registry's code is not VerifierRegistry"));
        script.runV31();
    }

    function test_refuses_a_verifier_that_is_not_the_pinned_one() public {
        script.expect(chain, DeployV31BaseSepolia.V30(v30.registry, v30.k8Verifier, v30.k8Verifier));
        vm.expectRevert(bytes("preflight: solo verifier address"));
        script.runV31();
    }

    function test_refuses_to_run_twice() public {
        script.runV31();
        MockERC3009(USDC).mint(DEFAULT_SENDER, 2);
        vm.expectRevert(bytes("preflight: v3.1 entries exist"));
        script.runV31();
    }
}
