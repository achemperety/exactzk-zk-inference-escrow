// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GasMeter} from "../../GasMeter.sol";
import {SoloSettlementBase} from "../../SoloSettlementBase.sol";
import {VerifierEntry} from "../../../src/IVerifierRegistry.sol";
import {SoloSettlement, Terms} from "../../../src/SoloSettlement.sol";
import {Verifier as Groth16Verifier} from "./Groth16Verifier.sol";
import {Groth16Adapter} from "./Groth16Adapter.sol";
import {Groth16Fixture} from "./Groth16Fixture.sol";

/// EXPERIMENTAL. The Groth16 prototype of the canonical MLP (measurements/experimental/groth16/) behind
/// the registry and `SoloSettlement`, with its real proof for the published input. Single-party local
/// trusted setup: insecure for anything but measurement. Its input commitment is Poseidon2, not the
/// canonical EZKL commitment, so it does not prove the same statement. Same method as
/// test/SoloSettlementGas.t.sol: Osaka, test token, each measured call the first thing its test does,
/// every account cold.
abstract contract Groth16Base is SoloSettlementBase, GasMeter {
    Groth16Verifier internal g16;
    Groth16Adapter internal g16Adapter;
    VerifierEntry internal g16Entry;
    bytes32 internal g16Id;
    /// About 4% above the 265,728 the adapter and verifier use for the stored proof, as for the other entries.
    uint32 internal constant G16_VERIFY_GAS = 280_000;

    function setUp() public virtual override {
        super.setUp();
        g16 = new Groth16Verifier();
        g16Adapter = new Groth16Adapter();
        g16Entry = _entry(address(g16Adapter), address(g16), 1, OUTPUT_SIZE, G16_VERIFY_GAS, Groth16Fixture.VK_HASH);
        g16Id = registry.register(g16Entry);
    }

    function _g16Terms(bytes32 salt) internal view returns (Terms memory t) {
        t = _terms(salt);
        t.verifierId = g16Id;
        t.inputCommitment = Groth16Fixture.COMMITMENT;
    }

    function _coldG16() internal view returns (address[] memory a) {
        a = new address[](7);
        (a[0], a[1], a[2], a[3], a[4], a[5], a[6]) =
        (address(settlement), address(token), address(registry), address(g16Adapter), address(g16), payer, provider);
    }

    function _settleData(bytes memory proof_) internal view returns (bytes memory) {
        Terms memory t = _g16Terms("g16");
        return abi.encodeCall(
            SoloSettlement.settle, (t, g16Entry, VALID_BEFORE, _signPayment(t), Groth16Fixture.output(), proof_)
        );
    }

    function _commitments(bytes32 c) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = c;
    }
}

contract Groth16AdapterTest is Groth16Base {
    function test_g16_adapter_accepts_the_proof() public {
        vm.cool(address(g16Adapter));
        vm.cool(address(g16));
        bool ok = g16Adapter.verify(
            address(g16),
            OUTPUT_SIZE,
            _commitments(Groth16Fixture.COMMITMENT),
            Groth16Fixture.output(),
            Groth16Fixture.proof()
        );
        emit log_named_uint("Groth16, adapter and verifier, gas inside the call", vm.lastCallGas().gasTotalUsed);
        assertTrue(ok, "the prototype's proof verifies");
    }

    function test_g16_adapter_rejects_a_changed_proof() public view {
        bytes memory p = Groth16Fixture.proof();
        p[40] ^= 0x01;
        assertFalse(
            g16Adapter.verify(
                address(g16), OUTPUT_SIZE, _commitments(Groth16Fixture.COMMITMENT), Groth16Fixture.output(), p
            )
        );
    }

    function test_g16_adapter_rejects_a_changed_output() public view {
        bytes memory o = Groth16Fixture.output();
        o[31] ^= 0x01;
        assertFalse(
            g16Adapter.verify(
                address(g16), OUTPUT_SIZE, _commitments(Groth16Fixture.COMMITMENT), o, Groth16Fixture.proof()
            )
        );
    }

    function test_g16_adapter_rejects_another_commitment() public view {
        assertFalse(
            g16Adapter.verify(
                address(g16), OUTPUT_SIZE, _commitments(commitment), Groth16Fixture.output(), Groth16Fixture.proof()
            )
        );
    }

    function test_g16_settle_rejects_a_changed_proof() public {
        bytes memory p = Groth16Fixture.proof();
        p[40] ^= 0x01;
        (bool ok, bytes memory ret) = address(settlement).call(_settleData(p));
        assertFalse(ok, "reverts");
        assertEq(bytes4(ret), SoloSettlement.ProofInvalid.selector, "ProofInvalid");
    }
}

/// The provider has never been paid.
contract Groth16SettleFirstTest is Groth16Base {
    function test_gas_g16_settle_first_payment_to_the_provider() public {
        TxGas memory g = _measure(address(settlement), _settleData(Groth16Fixture.proof()), _coldG16());
        _log("Groth16 settle, first payment to the provider", g);
        assertEq(token.balanceOf(provider), AMOUNT, "the measured call paid");
        assertLe(g.total, 390_300, "pin: measured 390,065");
    }
}

/// The provider has been paid before and the contract holds tokens.
contract Groth16SettleSteadyTest is Groth16Base {
    function setUp() public override {
        super.setUp();
        token.mint(provider, 1);
        token.mint(address(settlement), 1);
    }

    function test_gas_g16_settle_steady() public {
        TxGas memory g = _measure(address(settlement), _settleData(Groth16Fixture.proof()), _coldG16());
        _log("Groth16 settle, steady", g);
        assertEq(token.balanceOf(provider), AMOUNT + 1, "the measured call paid");
        assertLe(g.total, 373_200, "pin: measured 372,965");
    }
}
