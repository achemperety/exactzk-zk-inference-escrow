// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Fixtures} from "../test/fixtures/Fixtures.sol";
import {ReferenceDeploy} from "../test/external/ReferenceDeploy.sol";
import {AgenticCommerce} from "../test/external/erc8183/AgenticCommerce.sol";
import {ProofEvaluator8183} from "../src/ProofEvaluator8183.sol";
import {IVerifierRegistry, VerifierEntry} from "../src/IVerifierRegistry.sol";

/// One ERC-8183 job on Base Sepolia that ends Expired after a delivery that got no verdict: the
/// client names the terms on `ProofEvaluator8183` v3.1 (the v3.1 solo entry and the stored solo
/// proof's input commitment) and funds the job, the provider submits, nobody presents a proof, and
/// after `expiredAt` the client takes the budget back with `claimRefund`.
///
///     forge script script/Vector8183Expired.s.sol --sig "fundRoles()" --rpc-url <rpc> --broadcast --slow
///     forge script script/Vector8183Expired.s.sol --sig "deployJobContract()" --rpc-url <rpc> --broadcast --slow
///     forge script script/Vector8183Expired.s.sol --sig "openAndSubmit(address)" <acp> --rpc-url <rpc> --broadcast --slow
///     (wait until expiredAt)
///     forge script script/Vector8183Expired.s.sol --sig "refund(address,uint256)" <acp> <jobId> --rpc-url <rpc> --broadcast --slow
///
/// Keys come from the environment and are testnet-only throwaway keys: VECTOR_FUNDER_KEY (pays for
/// the other two and deploys the job contract), VECTOR_CLIENT_KEY, VECTOR_PROVIDER_KEY. The client
/// and the provider are fresh addresses used for nothing else.
///
/// The job contract is the ERC-8183 reference implementation as the ERC's text gives it
/// (test/external/erc8183/, test/external/README.md), behind an ERC-1967 proxy as in the tests,
/// with testnet USDC as payment token and no fees. Right after initialising it, the funder renounces
/// both admin roles, so nobody can upgrade it or set a fee afterwards.
contract Vector8183Expired is Script {
    address internal constant BURN = address(0xdEaD);
    uint256 internal constant BUDGET = 10_000; // 0.01 USDC
    uint256 internal constant CLIENT_ETH = 0.00003 ether;
    uint256 internal constant PROVIDER_ETH = 0.00002 ether;
    /// The reference contract requires `expiredAt > block.timestamp + 5 minutes` at `createJob`.
    /// Two minutes more absorb the gap between simulation and inclusion and leave time to fund and
    /// submit before expiry.
    uint256 internal constant EXPIRY = 7 minutes;
    string internal constant DESCRIPTION = "test vector: delivery submitted, no proof presented, expired";

    struct Target {
        uint256 chainId;
        address usdc;
        ProofEvaluator8183 evaluator;
        bytes32 soloId;
    }

    // ── steps ────────────────────────────────────────────────────────────────────────────────────

    /// The funder sends gas money to the client and the provider, and the budget to the client.
    function fundRoles() external {
        Target memory c = _preflight();
        (uint256 funderKey, address client, address provider) = _roles();
        vm.startBroadcast(funderKey);
        payable(client).transfer(CLIENT_ETH);
        payable(provider).transfer(PROVIDER_ETH);
        require(IERC20(c.usdc).transfer(client, BUDGET), "fund: USDC to client");
        vm.stopBroadcast();
    }

    /// The reference job contract behind a proxy, initialised with USDC, both admin roles renounced.
    function deployJobContract() external returns (AgenticCommerce acp) {
        Target memory c = _preflight();
        uint256 funderKey = vm.envUint("VECTOR_FUNDER_KEY");
        address funder = vm.addr(funderKey);
        vm.startBroadcast(funderKey);
        acp = ReferenceDeploy.agenticCommerce(c.usdc, BURN);
        acp.renounceRole(acp.ADMIN_ROLE(), funder);
        acp.renounceRole(acp.DEFAULT_ADMIN_ROLE(), funder);
        vm.stopBroadcast();
        _checkJobContract(c, acp, funder);
        console.log("AgenticCommerce (proxy)", address(acp));
    }

    /// Create, name the terms, set the budget, fund, submit. No proof is presented.
    function openAndSubmit(AgenticCommerce acp) external returns (uint256 jobId) {
        Target memory c = _preflight();
        (, address client, address provider) = _roles();
        uint256 clientKey = vm.envUint("VECTOR_CLIENT_KEY");
        uint256 providerKey = vm.envUint("VECTOR_PROVIDER_KEY");
        _checkJobContract(c, acp, address(0));
        require(IERC20(c.usdc).balanceOf(client) >= BUDGET, "preflight: client USDC");
        (bytes32 commitment, bytes memory output) = _soloClaim();
        uint256 expiredAt = block.timestamp + EXPIRY;

        vm.startBroadcast(clientKey);
        jobId = acp.createJob(provider, address(c.evaluator), expiredAt, DESCRIPTION, address(0));
        c.evaluator.setTerms(address(acp), jobId, ProofEvaluator8183.JobTerms(c.soloId, commitment));
        vm.stopBroadcast();

        vm.startBroadcast(providerKey);
        acp.setBudget(jobId, BUDGET, "");
        vm.stopBroadcast();

        vm.startBroadcast(clientKey);
        IERC20(c.usdc).approve(address(acp), BUDGET);
        acp.fund(jobId, "");
        vm.stopBroadcast();

        vm.startBroadcast(providerKey);
        acp.submit(jobId, keccak256(output), "");
        vm.stopBroadcast();

        AgenticCommerce.Job memory job = acp.getJob(jobId);
        require(job.status == AgenticCommerce.JobStatus.Submitted, "check: Submitted");
        require(job.client == client && job.provider == provider, "check: roles");
        require(job.evaluator == address(c.evaluator) && job.budget == BUDGET, "check: evaluator, budget");
        require(IERC20(c.usdc).balanceOf(address(acp)) >= BUDGET, "check: escrowed");
        console.log("jobId", jobId);
        console.log("expiredAt", job.expiredAt);
    }

    /// After expiry: the evaluator refuses even the valid stored proof (checked by a call, not sent),
    /// then the client claims the refund.
    function refund(AgenticCommerce acp, uint256 jobId) external {
        Target memory c = _preflight();
        (, address client,) = _roles();
        uint256 clientKey = vm.envUint("VECTOR_CLIENT_KEY");
        AgenticCommerce.Job memory job = acp.getJob(jobId);
        require(job.status == AgenticCommerce.JobStatus.Submitted, "preflight: not Submitted");
        require(block.timestamp >= job.expiredAt, "preflight: not expired yet");

        (bytes32 commitment, bytes memory output) = _soloClaim();
        ProofEvaluator8183.JobTerms memory t = c.evaluator.terms(address(acp), jobId);
        require(t.verifierId == c.soloId && t.inputCommitment == commitment, "preflight: terms");
        VerifierEntry memory e = c.evaluator.registry().entry(c.soloId);
        try c.evaluator.evaluate(address(acp), jobId, e, output, Fixtures.proofBytes()) {
            revert("check: the evaluator accepted a proof after expiry");
        } catch (bytes memory err) {
            require(
                keccak256(err)
                    == keccak256(abi.encodeWithSelector(ProofEvaluator8183.JobExpired.selector, job.expiredAt)),
                "check: evaluate after expiry did not revert JobExpired"
            );
        }

        uint256 before = IERC20(c.usdc).balanceOf(client);
        vm.startBroadcast(clientKey);
        acp.claimRefund(jobId);
        vm.stopBroadcast();

        require(acp.getJob(jobId).status == AgenticCommerce.JobStatus.Expired, "check: Expired");
        require(IERC20(c.usdc).balanceOf(client) == before + BUDGET, "check: refunded");
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────

    /// The chain, the v3.1 evaluator and the v3.1 solo id, from deployments/base-sepolia-v3.1.json.
    function _chain() internal view virtual returns (Target memory) {
        string memory j = vm.readFile("deployments/base-sepolia-v3.1.json");
        return Target({
            chainId: 84532,
            usdc: 0x036CbD53842c5426634e7929541eC2318f3dCF7e,
            evaluator: ProofEvaluator8183(vm.parseJsonAddress(j, ".contracts.ProofEvaluator8183")),
            soloId: vm.parseJsonBytes32(j, ".verifierIds.solo")
        });
    }

    function _preflight() internal view returns (Target memory c) {
        c = _chain();
        require(block.chainid == c.chainId, "preflight: chain id");
        require(address(c.evaluator).code.length != 0, "preflight: no evaluator");
        require(c.evaluator.registry().exists(c.soloId), "preflight: solo entry missing");
    }

    function _roles() internal view returns (uint256 funderKey, address client, address provider) {
        funderKey = vm.envUint("VECTOR_FUNDER_KEY");
        client = vm.addr(vm.envUint("VECTOR_CLIENT_KEY"));
        provider = vm.addr(vm.envUint("VECTOR_PROVIDER_KEY"));
        address funder = vm.addr(funderKey);
        require(client != provider && client != funder && provider != funder, "preflight: three distinct keys");
    }

    /// The job contract pays in USDC, takes no fee, has no hook allowed but none, and (when `funder`
    /// is given) the funder holds no admin role.
    function _checkJobContract(Target memory c, AgenticCommerce acp, address funder) internal view {
        require(address(acp.paymentToken()) == c.usdc, "check: payment token");
        require(acp.platformFeeBP() == 0 && acp.evaluatorFeeBP() == 0, "check: no fees");
        if (funder != address(0)) {
            require(!acp.hasRole(acp.ADMIN_ROLE(), funder), "check: ADMIN_ROLE renounced");
            require(!acp.hasRole(acp.DEFAULT_ADMIN_ROLE(), funder), "check: DEFAULT_ADMIN_ROLE renounced");
        }
    }

    /// The stored solo proof's input commitment and its 320-byte output.
    function _soloClaim() internal pure returns (bytes32 commitment, bytes memory output) {
        uint256[] memory inst = Fixtures.instances();
        commitment = bytes32(inst[0]);
        output = new bytes(32 * (inst.length - 1));
        for (uint256 i = 1; i < inst.length; i++) {
            uint256 v = inst[i];
            assembly ("memory-safe") {
                mstore(add(add(output, 0x20), mul(sub(i, 1), 0x20)), v)
            }
        }
    }
}
