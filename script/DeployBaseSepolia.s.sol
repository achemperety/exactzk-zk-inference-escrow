// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Fixtures} from "../test/fixtures/Fixtures.sol";
import {FixturesK8} from "../test/fixtures/FixturesK8.sol";
import {VerifierRegistry} from "../src/VerifierRegistry.sol";
import {Halo2EzklAdapter} from "../src/Halo2EzklAdapter.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";
import {SoloSettlement} from "../src/SoloSettlement.sol";
import {ChannelSettlement} from "../src/ChannelSettlement.sol";
import {ProofEvaluator8183} from "../src/ProofEvaluator8183.sol";
import {ProofValidator8004} from "../src/ProofValidator8004.sol";
import {IValidationRegistry} from "../src/IValidationRegistry.sol";
import {AuthCaptureProofOperator} from "../src/AuthCaptureProofOperator.sol";
import {IAuthCaptureEscrow} from "../src/IAuthCaptureEscrow.sol";

interface IIdentityRegistryLink {
    function getIdentityRegistry() external view returns (address);
}

interface ICollectorLink {
    function authCaptureEscrow() external view returns (address);
}

/// Deploys this repository's contracts to Base Sepolia (docs/deployment-notes.md, "Order"):
///
///     forge script script/DeployBaseSepolia.s.sol --rpc-url <rpc> --account <keystore>             (simulation)
///     forge script script/DeployBaseSepolia.s.sol --rpc-url <rpc> --account <keystore> --broadcast --slow
///
/// `scripts/deploy_base_sepolia.sh` wraps both. The two pinned EZKL verifiers are deployed from the
/// runtime bytes in test/fixtures/ as they are, not recompiled, so their code hashes equal the pinned
/// ones in circuits/spike-mlp/MANIFEST.md; the registry refuses to register them otherwise.
///
/// Before anything is sent, the whole run is executed locally, and it stops if the chain is not what
/// was checked: the ERC-8004 registries' implementations (scripts/erc8004_live_check.py), the code of
/// x402's escrow and ERC-3009 collector at the canonical addresses (compared with base/commerce-payments
/// v1.1.0), the deployer's USDC for the seeds. After deploying, it checks what it built: code hashes,
/// verifier ids, seeds and every contract's links.
contract DeployBaseSepolia is Script {
    /// What the deployment relies on that is not ours. `run` stops if the chain disagrees.
    struct Expected {
        uint256 chainId;
        address usdc;
        address validationRegistry;
        address validationImplementation;
        address identityRegistry;
        address identityImplementation;
        address escrow;
        bytes32 escrowCodeHash;
        address collector;
        bytes32 collectorCodeHash;
    }

    struct Deployment {
        address deployer;
        VerifierRegistry registry;
        Halo2EzklAdapter adapter;
        address soloVerifier;
        address k8Verifier;
        bytes32 soloId;
        bytes32 k8Id;
        SoloSettlement solo;
        ChannelSettlement channel;
        ProofEvaluator8183 evaluator;
        ProofValidator8004 validator;
        AuthCaptureProofOperator operator;
    }

    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // circuits/spike-mlp/MANIFEST.md: keccak256 of the pinned runtime bytecode, and of vk.key.
    bytes32 internal constant SOLO_CODE_HASH = 0x8cd0b80f6b67e187a9ee98478fdd1278b8e1b666d666d442920aaf911f485f49;
    bytes32 internal constant K8_CODE_HASH = 0x471c8109f1a03375b17ae6afd421f5857346edf92bf37fce1c7b90a3e02d7ef1;
    bytes32 internal constant SOLO_VK_HASH = 0x13cff0426abe00c941934bdd6bb7757f2e703fb9f6862bf08a783eeca08b4ff2;
    bytes32 internal constant K8_VK_HASH = 0xdd03fb0c69e96cc02cbcc6bed8ef51665f934c01cddaf2a855bd1c7fce94675f;

    // The entries the tests register (test/ProofCoreBase.sol), and the ids they get.
    uint32 internal constant OUTPUT_SIZE = 320;
    uint32 internal constant SOLO_VERIFY_GAS = 600_000;
    uint32 internal constant K8_VERIFY_GAS = 660_000;
    bytes32 internal constant SOLO_ID = 0xc302c6867eddfdcd201bbe7fb653191da6ee4c1a178e7df821e9ebca01b6ff9b;
    bytes32 internal constant K8_ID = 0xff34bcad7f2abcb126327e61b648bae1d6a446ad3bd15924ec2218c742d51107;

    /// One unit of USDC in each settlement contract (docs/deployment-notes.md, "Why the seed").
    uint256 internal constant SEED = 1;

    /// Creation code that returns the bytes appended to it as the runtime code:
    /// PUSH1 11, CODESIZE, SUB, DUP1, PUSH1 11, RETURNDATASIZE, CODECOPY, RETURNDATASIZE, RETURN.
    bytes internal constant RAW_RUNTIME_PREFIX = hex"600b380380600b3d393df3";

    function run() external virtual returns (Deployment memory d) {
        Expected memory c = _chain();
        vm.startBroadcast();
        (, d.deployer,) = vm.readCallers();
        _preflight(c, d.deployer);

        d.registry = new VerifierRegistry();
        d.adapter = new Halo2EzklAdapter();
        d.soloVerifier = _deployRuntime(Fixtures.verifierBytecode());
        d.k8Verifier = _deployRuntime(FixturesK8.verifierBytecode());
        d.soloId =
            d.registry.register(_entry(d.adapter, d.soloVerifier, 1, SOLO_VERIFY_GAS, SOLO_CODE_HASH, SOLO_VK_HASH));
        d.k8Id = d.registry.register(_entry(d.adapter, d.k8Verifier, 8, K8_VERIFY_GAS, K8_CODE_HASH, K8_VK_HASH));
        d.solo = new SoloSettlement(d.registry);
        d.channel = new ChannelSettlement(d.registry);
        require(IERC20(c.usdc).transfer(address(d.solo), SEED), "seed: SoloSettlement");
        require(IERC20(c.usdc).transfer(address(d.channel), SEED), "seed: ChannelSettlement");
        d.evaluator = new ProofEvaluator8183(d.registry);
        d.validator = new ProofValidator8004(d.registry, IValidationRegistry(c.validationRegistry));
        d.operator = new AuthCaptureProofOperator(IAuthCaptureEscrow(c.escrow), d.registry);
        vm.stopBroadcast();

        _check(c, d);
        _log(d);
    }

    /// The chain this script was checked against on 2026-11-24 (docs/deployment-notes.md).
    function _chain() internal view virtual returns (Expected memory) {
        return Expected({
            chainId: 84532,
            usdc: 0x036CbD53842c5426634e7929541eC2318f3dCF7e,
            // TESTNET_ADDRESSES in lib/erc-8004-contracts/scripts/addresses.ts
            validationRegistry: 0x8004Cb1BF31DAf7788923b405b754f57acEB4272,
            validationImplementation: 0xDB31f5d9167f8ebc8B30FbBF814c4d297c2D7F99,
            identityRegistry: 0x8004A818BFB912233c491871b3d84c89A494BD9e,
            identityImplementation: 0x7274e874CA62410a93Bd8bf61c69d8045E399c02,
            // x402's auth-capture v1.1 deployment set: base/commerce-payments v1.1.0
            escrow: 0xf96815976523E00e65Be8f34cA5e64b4f41EB19c,
            escrowCodeHash: 0x33558f6cb34733174fdd6ec5ca8257834a8e4302abc08a4542f73ddf07d8702a,
            collector: 0x8612dfdc421f80336cd14E8EF9cb1E765dB5ab88,
            collectorCodeHash: 0xe27322c83d2cb91d01f59fc5c86512f4ecb5e9f300ed17120d78c55fbc5fb62f
        });
    }

    function _preflight(Expected memory c, address deployer) internal view {
        _preflightChain(c);
        require(
            IERC20(c.usdc).balanceOf(deployer) >= 2 * SEED, "preflight: deployer needs 2 units of USDC for the seeds"
        );
    }

    /// The chain's contracts this deployment depends on are the ones pinned above.
    function _preflightChain(Expected memory c) internal view {
        require(block.chainid == c.chainId, "preflight: wrong chain");
        require(
            _implementation(c.validationRegistry) == c.validationImplementation,
            "preflight: Validation Registry implementation changed"
        );
        require(
            IIdentityRegistryLink(c.validationRegistry).getIdentityRegistry() == c.identityRegistry,
            "preflight: Validation Registry points at another Identity Registry"
        );
        require(
            _implementation(c.identityRegistry) == c.identityImplementation,
            "preflight: Identity Registry implementation changed"
        );
        require(c.escrow.codehash == c.escrowCodeHash, "preflight: escrow code differs");
        require(c.collector.codehash == c.collectorCodeHash, "preflight: collector code differs");
        require(
            ICollectorLink(c.collector).authCaptureEscrow() == c.escrow, "preflight: collector serves another escrow"
        );
    }

    function _check(Expected memory c, Deployment memory d) internal view {
        require(d.soloVerifier.codehash == SOLO_CODE_HASH, "check: solo verifier code hash");
        require(d.k8Verifier.codehash == K8_CODE_HASH, "check: K=8 verifier code hash");
        require(d.soloId == SOLO_ID, "check: solo verifier id");
        require(d.k8Id == K8_ID, "check: K=8 verifier id");
        require(IERC20(c.usdc).balanceOf(address(d.solo)) == SEED, "check: SoloSettlement seed");
        require(IERC20(c.usdc).balanceOf(address(d.channel)) == SEED, "check: ChannelSettlement seed");
        require(d.solo.registry() == d.registry, "check: SoloSettlement registry");
        require(d.channel.registry() == d.registry, "check: ChannelSettlement registry");
        require(d.evaluator.registry() == d.registry, "check: evaluator registry");
        require(d.validator.registry() == d.registry, "check: validator registry");
        require(
            address(d.validator.validationRegistry()) == c.validationRegistry, "check: validator's ERC-8004 registry"
        );
        require(d.operator.registry() == d.registry, "check: operator registry");
        require(address(d.operator.escrow()) == c.escrow, "check: operator escrow");
    }

    function _entry(
        Halo2EzklAdapter adapter,
        address target,
        uint32 lanes,
        uint32 verifyGas,
        bytes32 targetCodeHash,
        bytes32 vkHash
    ) internal view returns (VerifierEntry memory) {
        return VerifierEntry({
            adapter: address(adapter),
            lanes: lanes,
            outputSize: OUTPUT_SIZE,
            verifyGas: verifyGas,
            target: target,
            adapterCodeHash: address(adapter).codehash,
            targetCodeHash: targetCodeHash, // the pinned hash: registration fails if the code differs
            vkHash: vkHash,
            emptyLane: bytes32(0)
        });
    }

    function _deployRuntime(bytes memory runtime) internal returns (address a) {
        bytes memory init = abi.encodePacked(RAW_RUNTIME_PREFIX, runtime);
        assembly ("memory-safe") {
            a := create(0, add(init, 0x20), mload(init))
        }
        require(a != address(0), "deploy: verifier");
    }

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _log(Deployment memory d) internal pure {
        console.log("VerifierRegistry        ", address(d.registry));
        console.log("Halo2EzklAdapter        ", address(d.adapter));
        console.log("solo verifier (pinned)  ", d.soloVerifier);
        console.log("K=8 verifier (pinned)   ", d.k8Verifier);
        console.log("solo verifier id");
        console.logBytes32(d.soloId);
        console.log("K=8 verifier id");
        console.logBytes32(d.k8Id);
        console.log("SoloSettlement          ", address(d.solo));
        console.log("ChannelSettlement       ", address(d.channel));
        console.log("ProofEvaluator8183      ", address(d.evaluator));
        console.log("ProofValidator8004      ", address(d.validator));
        console.log("AuthCaptureProofOperator", address(d.operator));
    }
}
