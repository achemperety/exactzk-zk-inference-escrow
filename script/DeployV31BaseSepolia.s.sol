// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployBaseSepolia} from "./DeployBaseSepolia.s.sol";
import {VerifierRegistry} from "../src/VerifierRegistry.sol";
import {Halo2EzklAdapterV2} from "../src/Halo2EzklAdapterV2.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";
import {SoloSettlement} from "../src/SoloSettlement.sol";
import {ChannelSettlement} from "../src/ChannelSettlement.sol";
import {ProofEvaluator8183} from "../src/ProofEvaluator8183.sol";
import {ProofValidator8004} from "../src/ProofValidator8004.sol";
import {IValidationRegistry} from "../src/IValidationRegistry.sol";
import {AuthCaptureProofOperator} from "../src/AuthCaptureProofOperator.sol";
import {IAuthCaptureEscrow} from "../src/IAuthCaptureEscrow.sol";

/// Deploys v3.1 to Base Sepolia (docs/known-issues/2026-11-out-of-gas-as-invalid.md), in two steps:
///
///     forge script script/DeployV31BaseSepolia.s.sol --sig "runV31()" --rpc-url <rpc> --account <keystore>             (simulation)
///     forge script script/DeployV31BaseSepolia.s.sol --sig "runV31()" --rpc-url <rpc> --account <keystore> --broadcast --slow
///     forge script script/DeployV31BaseSepolia.s.sol --sig "runV31Validator()" --rpc-url <rpc> --account <keystore> --broadcast --slow
///
/// It reuses what v3.0.0-testnet deployed and is not affected: the registry (append-only) and the two
/// pinned EZKL verifiers, read from deployments/base-sepolia.json and checked before anything is sent.
/// It deploys `Halo2EzklAdapterV2`, registers the two entries sized for the 1/16 rule in the existing
/// registry, and deploys a new version of every contract that embeds `ProofCheck`, with the same
/// constructor arguments as v3.0 and the same one-unit USDC seed in each settlement contract.
/// `runV31()` deploys all of them but `ProofValidator8004`; `runV31Validator()` deploys that one later,
/// into the registry recorded in deployments/base-sepolia-v3.1.json, once its source on main is final.
/// `run()` refuses, so that this file can never run the v3.0 deployment it inherits.
contract DeployV31BaseSepolia is DeployBaseSepolia {
    struct V30 {
        VerifierRegistry registry;
        address soloVerifier;
        address k8Verifier;
    }

    struct DeploymentV31 {
        address deployer;
        VerifierRegistry registry;
        Halo2EzklAdapterV2 adapter;
        bytes32 soloId;
        bytes32 k8Id;
        SoloSettlement solo;
        ChannelSettlement channel;
        ProofEvaluator8183 evaluator;
        AuthCaptureProofOperator operator;
    }

    // At least 1.10 times the first-call valid path through Halo2EzklAdapterV2 (test/ProofCoreBase.sol).
    uint32 internal constant SOLO_VERIFY_GAS_V31 = 645_000;
    uint32 internal constant K8_VERIFY_GAS_V31 = 712_000;
    // The ids the tests compute for those entries (test/DeployV31BaseSepolia.t.sol checks them).
    bytes32 internal constant SOLO_ID_V31 = 0x660e857f27694c13851bfd3b8558b8a8e7e76d5fc48b3b31f60f8fa3f086c1e1;
    bytes32 internal constant K8_ID_V31 = 0x81e1e6281df75ff6da92568a8f6448aa11150fed22cbf5396465a764cc83c286;

    function run() external pure override returns (Deployment memory) {
        revert("DeployV31BaseSepolia: run with --sig 'runV31()'");
    }

    function runV31() external returns (DeploymentV31 memory d) {
        Expected memory c = _chain();
        V30 memory old = _v30();
        vm.startBroadcast();
        (, d.deployer,) = vm.readCallers();
        _preflight(c, d.deployer);
        _preflightV30(old);

        d.registry = old.registry;
        d.adapter = new Halo2EzklAdapterV2();
        d.soloId = d.registry
            .register(_entryV31(d.adapter, old.soloVerifier, 1, SOLO_VERIFY_GAS_V31, SOLO_CODE_HASH, SOLO_VK_HASH));
        d.k8Id =
            d.registry.register(_entryV31(d.adapter, old.k8Verifier, 8, K8_VERIFY_GAS_V31, K8_CODE_HASH, K8_VK_HASH));
        d.solo = new SoloSettlement(d.registry);
        d.channel = new ChannelSettlement(d.registry);
        require(IERC20(c.usdc).transfer(address(d.solo), SEED), "seed: SoloSettlement");
        require(IERC20(c.usdc).transfer(address(d.channel), SEED), "seed: ChannelSettlement");
        d.evaluator = new ProofEvaluator8183(d.registry);
        d.operator = new AuthCaptureProofOperator(IAuthCaptureEscrow(c.escrow), d.registry);
        vm.stopBroadcast();

        _checkV31(c, d);
        _logV31(d);
    }

    /// The second step: `ProofValidator8004` against the registry that holds the v3.1 entries.
    function runV31Validator() external returns (ProofValidator8004 validator) {
        Expected memory c = _chain();
        VerifierRegistry registry = _v31Registry();
        _preflightChain(c);
        require(
            address(registry).codehash == keccak256(type(VerifierRegistry).runtimeCode),
            "preflight: the registry's code is not VerifierRegistry"
        );
        require(registry.exists(SOLO_ID_V31) && registry.exists(K8_ID_V31), "preflight: v3.1 entries missing");
        vm.startBroadcast();
        validator = new ProofValidator8004(registry, IValidationRegistry(c.validationRegistry));
        vm.stopBroadcast();

        require(validator.registry() == registry, "check: validator registry");
        require(address(validator.validationRegistry()) == c.validationRegistry, "check: validator's ERC-8004 registry");
        console.log("ProofValidator8004 (v3.1)", address(validator));
    }

    /// The registry of the v3.1 deployment, from deployments/base-sepolia-v3.1.json.
    function _v31Registry() internal view virtual returns (VerifierRegistry) {
        string memory j = vm.readFile("deployments/base-sepolia-v3.1.json");
        return VerifierRegistry(vm.parseJsonAddress(j, ".contracts.VerifierRegistry"));
    }

    /// What v3.0.0-testnet deployed and v3.1 reuses, from deployments/base-sepolia.json.
    function _v30() internal view virtual returns (V30 memory) {
        string memory j = vm.readFile("deployments/base-sepolia.json");
        return V30({
            registry: VerifierRegistry(vm.parseJsonAddress(j, ".contracts.VerifierRegistry")),
            soloVerifier: vm.parseJsonAddress(j, ".contracts.soloVerifier"),
            k8Verifier: vm.parseJsonAddress(j, ".contracts.k8Verifier")
        });
    }

    /// The registry is this repository's registry, unchanged, holding the two v3.0 entries; the
    /// verifiers hold the pinned bytes. Nothing is sent otherwise.
    function _preflightV30(V30 memory old) internal view {
        require(
            address(old.registry).codehash == keccak256(type(VerifierRegistry).runtimeCode),
            "preflight: the registry's code is not VerifierRegistry"
        );
        require(old.registry.exists(SOLO_ID) && old.registry.exists(K8_ID), "preflight: v3.0 entries missing");
        require(old.registry.entry(SOLO_ID).target == old.soloVerifier, "preflight: solo verifier address");
        require(old.registry.entry(K8_ID).target == old.k8Verifier, "preflight: K=8 verifier address");
        require(old.soloVerifier.codehash == SOLO_CODE_HASH, "preflight: solo verifier code hash");
        require(old.k8Verifier.codehash == K8_CODE_HASH, "preflight: K=8 verifier code hash");
        require(!old.registry.exists(SOLO_ID_V31) && !old.registry.exists(K8_ID_V31), "preflight: v3.1 entries exist");
    }

    function _checkV31(Expected memory c, DeploymentV31 memory d) internal view {
        require(d.soloId == SOLO_ID_V31, "check: solo verifier id");
        require(d.k8Id == K8_ID_V31, "check: K=8 verifier id");
        require(d.registry.entry(d.soloId).verifyGas == SOLO_VERIFY_GAS_V31, "check: solo allowance");
        require(d.registry.entry(d.k8Id).verifyGas == K8_VERIFY_GAS_V31, "check: K=8 allowance");
        require(IERC20(c.usdc).balanceOf(address(d.solo)) == SEED, "check: SoloSettlement seed");
        require(IERC20(c.usdc).balanceOf(address(d.channel)) == SEED, "check: ChannelSettlement seed");
        require(d.solo.registry() == d.registry, "check: SoloSettlement registry");
        require(d.channel.registry() == d.registry, "check: ChannelSettlement registry");
        require(d.evaluator.registry() == d.registry, "check: evaluator registry");
        require(d.operator.registry() == d.registry, "check: operator registry");
        require(address(d.operator.escrow()) == c.escrow, "check: operator escrow");
    }

    function _entryV31(
        Halo2EzklAdapterV2 adapter,
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
            targetCodeHash: targetCodeHash,
            vkHash: vkHash,
            emptyLane: bytes32(0)
        });
    }

    function _logV31(DeploymentV31 memory d) internal pure {
        console.log("VerifierRegistry (v3.0) ", address(d.registry));
        console.log("Halo2EzklAdapterV2      ", address(d.adapter));
        console.log("solo verifier id (v3.1)");
        console.logBytes32(d.soloId);
        console.log("K=8 verifier id (v3.1)");
        console.logBytes32(d.k8Id);
        console.log("SoloSettlement          ", address(d.solo));
        console.log("ChannelSettlement       ", address(d.channel));
        console.log("ProofEvaluator8183      ", address(d.evaluator));
        console.log("AuthCaptureProofOperator", address(d.operator));
    }
}
