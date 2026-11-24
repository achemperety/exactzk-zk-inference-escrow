// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IHalo2Verifier} from "./ProofCoreBase.sol";
import {Fixtures} from "./fixtures/Fixtures.sol";
import {FixturesK8} from "./fixtures/FixturesK8.sol";
import {DeployBaseSepolia} from "../script/DeployBaseSepolia.s.sol";

interface IUSDCBalance {
    function balanceOf(address) external view returns (uint256);
}

/// The deployment script as it is, with every expectation it has about Base Sepolia, run on a fork of
/// that chain. Skipped unless `FORK_RPC_URL` is set, so CI never depends on a network:
///
///     FORK_RPC_URL=https://sepolia.base.org forge test --match-path test/DeployBaseSepoliaFork.t.sol -vv
///
/// `FORK_BLOCK` pins the block. Only the two seed units are given to the broadcaster with `deal`.
contract DeployBaseSepoliaForkTest is Test {
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant VALIDATION_REGISTRY = 0x8004Cb1BF31DAf7788923b405b754f57acEB4272;
    address internal constant ESCROW = 0xf96815976523E00e65Be8f34cA5e64b4f41EB19c;

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blockNumber = vm.envOr("FORK_BLOCK", uint256(0));
        if (blockNumber == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNumber);
        forked = true;
        deal(USDC, DEFAULT_SENDER, 2);
    }

    function test_fork_the_script_deploys_against_the_live_chain() public {
        if (!forked) vm.skip(true);
        DeployBaseSepolia.Deployment memory d = new DeployBaseSepolia().run();
        emit log_named_uint("fork block", block.number);

        assertTrue(IHalo2Verifier(d.soloVerifier).verifyProof(Fixtures.proofBytes(), Fixtures.instances()), "solo");
        assertTrue(IHalo2Verifier(d.k8Verifier).verifyProof(FixturesK8.proofBytes(), FixturesK8.instances()), "K=8");
        assertEq(IUSDCBalance(USDC).balanceOf(address(d.solo)), 1, "SoloSettlement seed");
        assertEq(IUSDCBalance(USDC).balanceOf(address(d.channel)), 1, "ChannelSettlement seed");
        assertEq(address(d.validator.validationRegistry()), VALIDATION_REGISTRY, "the authors' testnet registry");
        assertEq(address(d.operator.escrow()), ESCROW, "x402's canonical escrow");
    }
}
