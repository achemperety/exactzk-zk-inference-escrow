// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {Fixtures} from "../test/fixtures/Fixtures.sol";
import {MockERC3009} from "../test/mocks/MockERC3009.sol";
import {VerifierRegistry} from "../src/VerifierRegistry.sol";
import {Halo2EzklAdapter} from "../src/Halo2EzklAdapter.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";
import {SoloSettlement} from "../src/SoloSettlement.sol";
import {AuthCaptureProofOperator} from "../src/AuthCaptureProofOperator.sol";
import {IAuthCaptureEscrow} from "../src/IAuthCaptureEscrow.sol";
import {AuthCaptureEscrow} from "lib/commerce-payments/src/AuthCaptureEscrow.sol";
import {ERC3009PaymentCollector} from "lib/commerce-payments/src/collectors/ERC3009PaymentCollector.sol";

/// Builds the chain state for the x402 end-to-end run (x402/README.md) and writes it to
/// x402/.state/: `state.json` (every account, for x402/server/load_state.py to put on a local node
/// started with chain id 84532) and `deployment.json` (addresses, the solo entry, the stored proof).
///
///     forge script script/X402LocalChain.s.sol
///
/// Nothing is broadcast. x402's escrow and ERC-3009 collector are built from base/commerce-payments
/// v1.1.0 and placed at the canonical v1.1 addresses, because x402's own client signs for those. The
/// token is the test token placed at the testnet USDC address. Accounts are the local node's
/// published default accounts: 0 sends the server's transactions, 1 pays, 2 is paid.
contract X402LocalChain is Script {
    address internal constant ESCROW = 0xf96815976523E00e65Be8f34cA5e64b4f41EB19c;
    address internal constant COLLECTOR = 0x8612dfdc421f80336cd14E8EF9cb1E765dB5ab88;
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    address internal constant TOKEN = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant SOLO = address(0x5010);
    address internal constant PAYER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // default account 1
    address internal constant PAY_TO = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // default account 2
    bytes32 internal constant SOLO_VK_HASH = 0x13cff0426abe00c941934bdd6bb7757f2e703fb9f6862bf08a783eeca08b4ff2;
    string internal constant DIR = "x402/.state/";

    function _deployTo(string memory what, bytes memory args, address where) internal {
        vm.etch(where, abi.encodePacked(vm.getCode(what), args));
        (bool ok, bytes memory runtime) = where.call("");
        require(ok, what);
        vm.etch(where, runtime);
    }

    function run() external {
        vm.chainId(84532);
        _deployTo("MockERC3009.sol:MockERC3009", "", TOKEN);
        _deployTo("AuthCaptureEscrow.sol:AuthCaptureEscrow", "", ESCROW);
        _deployTo("ERC3009PaymentCollector.sol:ERC3009PaymentCollector", abi.encode(ESCROW, MULTICALL3), COLLECTOR);

        vm.etch(SOLO, Fixtures.verifierBytecode());
        VerifierRegistry registry = new VerifierRegistry();
        Halo2EzklAdapter adapter = new Halo2EzklAdapter();
        VerifierEntry memory e = VerifierEntry({
            adapter: address(adapter),
            lanes: 1,
            outputSize: 320,
            verifyGas: 600_000,
            target: SOLO,
            adapterCodeHash: address(adapter).codehash,
            targetCodeHash: SOLO.codehash,
            vkHash: SOLO_VK_HASH,
            emptyLane: bytes32(0)
        });
        bytes32 soloId = registry.register(e);
        SoloSettlement settlement = new SoloSettlement(registry);
        AuthCaptureProofOperator operator = new AuthCaptureProofOperator(IAuthCaptureEscrow(ESCROW), registry);

        MockERC3009(TOKEN).mint(PAYER, 100_000_000);
        MockERC3009(TOKEN).mint(address(settlement), 1); // the deployment seed (docs/deployment-notes.md)

        uint256[] memory inst = Fixtures.instances();
        bytes memory out = new bytes(320);
        for (uint256 j = 0; j < 10; j++) {
            uint256 v = inst[1 + j];
            assembly ("memory-safe") {
                mstore(add(add(out, 0x20), mul(j, 0x20)), v)
            }
        }

        string memory k = "deployment";
        vm.serializeUint(k, "chainId", 84532);
        vm.serializeAddress(k, "token", TOKEN);
        vm.serializeAddress(k, "escrow", ESCROW);
        vm.serializeAddress(k, "collector", COLLECTOR);
        vm.serializeAddress(k, "registry", address(registry));
        vm.serializeAddress(k, "settlement", address(settlement));
        vm.serializeAddress(k, "operator", address(operator));
        vm.serializeAddress(k, "payTo", PAY_TO);
        vm.serializeBytes32(k, "verifierId", soloId);
        vm.serializeBytes(k, "entry", abi.encode(e));
        vm.serializeBytes32(k, "inputCommitment", bytes32(inst[0]));
        vm.serializeBytes(k, "output", out);
        string memory json = vm.serializeBytes(k, "proof", Fixtures.proofBytes());
        vm.writeJson(json, string.concat(DIR, "deployment.json"));
        vm.dumpState(string.concat(DIR, "state.json"));
    }
}
