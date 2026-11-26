// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GasMeter} from "./GasMeter.sol";
import {ChannelSettlementBase} from "./ChannelSettlementBase.sol";
import {IHalo2Verifier} from "./ProofCoreBase.sol";
import {FixturesK16} from "./fixtures/FixturesK16.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";
import {ChannelSettlement, ChannelConfig} from "../src/ChannelSettlement.sol";

/// K=16 with the real proof: the K=16 batch circuit's verifier, regenerated from its existing key and
/// deployed as EZKL compiles it (test/fixtures/FixturesK16.sol), and the proof stored with that key in
/// the 2026-09-28 K=16 measurement. Same method as test/ChannelSettlementGas.t.sol: Osaka schedule,
/// test token (a batch never calls the token), each measured call the first thing its test does.
///
/// The K=16 circuit is not one of the two pinned circuits; it is registered here for measurement only.
abstract contract ChannelK16Base is ChannelSettlementBase, GasMeter {
    address internal constant K16 = address(0x5160);
    // keccak256 of the K=16 vk.key (SHA-256 in FixturesK16.sol's header).
    bytes32 internal constant K16_VK_HASH = 0xa3490d874b6e2fee46b3d20d3355d71980e8fed85b8860c6cabffc2d46d63518;
    // About 4% above the 702,349 the verifier uses for the stored proof, as for the solo and K=8 entries.
    uint32 internal constant K16_VERIFY_GAS = 730_000;
    uint256 internal constant K16_INDEX = 3;
    /// The acceptance figure for a steady K=16 batch with the real proof.
    uint256 internal constant K16_STEADY_ACCEPTANCE = 1_170_000;

    VerifierEntry internal k16Entry;
    bytes32 internal k16Id;
    bytes32[] internal k16Commitments;
    bytes internal k16Outputs;
    bytes internal k16Proof;
    address[16] internal payers16;
    uint256[16] internal keys16;

    function setUp() public virtual override {
        super.setUp();
        vm.etch(K16, FixturesK16.verifierBytecode());
        k16Entry = _entry(address(adapter), K16, 16, OUTPUT_SIZE, K16_VERIFY_GAS, K16_VK_HASH);
        k16Id = registry.register(k16Entry);
        set.push(k16Id);
        setHash = keccak256(abi.encodePacked(set));
        (k16Commitments, k16Outputs) = _split(FixturesK16.instances(), 16);
        k16Proof = FixturesK16.proofBytes();
        for (uint256 i = 0; i < 16; i++) {
            (payers16[i], keys16[i]) = makeAddrAndKey(string.concat("k16 payer", vm.toString(i)));
            token.mint(payers16[i], 2 * DEPOSIT);
        }
    }

    function _coldK16() internal view returns (address[] memory a) {
        a = new address[](5);
        (a[0], a[1], a[2], a[3], a[4]) = (address(settlement), address(registry), address(adapter), K16, address(token));
    }

    function _k16Call(ChannelConfig[] memory cs, bytes memory frames) internal view returns (bytes memory) {
        return abi.encodeCall(
            ChannelSettlement.settleBatch, (k16Entry, set, K16_INDEX, cs, frames, k16Commitments, k16Outputs, k16Proof)
        );
    }

    function _settleK16(ChannelConfig[] memory cs, bytes memory frames) internal {
        settlement.settleBatch(k16Entry, set, K16_INDEX, cs, frames, k16Commitments, k16Outputs, k16Proof);
    }

    function _openSixteen(bytes32 saltBase) internal returns (ChannelConfig[] memory cs) {
        cs = new ChannelConfig[](16);
        for (uint256 i = 0; i < 16; i++) {
            cs[i] = _config(payers16[i], bytes32(uint256(saltBase) + i));
            _open(cs[i], keys16[i], DEPOSIT);
        }
    }

    /// Lane `i` against channel `cs[i]`, voucher `seq` of `AMOUNT`, signed by payer `i`.
    function _k16Frames(ChannelConfig[] memory cs, uint256 seq) internal view returns (bytes memory frames) {
        for (uint256 i = 0; i < 16; i++) {
            bytes memory sig =
                _voucher(keys16[i], _channelId(cs[i]), seq, AMOUNT, seq * AMOUNT, k16Commitments[i], PROVE_BY);
            frames = bytes.concat(frames, _frame(i, seq, AMOUNT, PROVE_BY, sig));
        }
    }

    /// Sixteen vouchers of one channel, lane `i` carrying voucher `after_ + i + 1`.
    function _k16SingleChannelFrames(ChannelConfig memory c, uint256 after_)
        internal
        view
        returns (bytes memory frames)
    {
        for (uint256 i = 0; i < 16; i++) {
            uint256 seq = after_ + i + 1;
            bytes memory sig =
                _voucher(keys16[0], _channelId(c), seq, AMOUNT, seq * AMOUNT, k16Commitments[i], PROVE_BY);
            frames = bytes.concat(frames, _frame(0, seq, AMOUNT, PROVE_BY, sig));
        }
    }
}

/// The regenerated verifier accepts the stored proof and rejects it with one byte changed.
contract K16VerifierTest is ChannelK16Base {
    function test_k16_verifier_accepts_the_stored_proof() public {
        vm.cool(K16);
        bool ok = IHalo2Verifier(K16).verifyProof(FixturesK16.proofBytes(), FixturesK16.instances());
        emit log_named_uint("K=16, verifyProof, gas inside the call", vm.lastCallGas().gasTotalUsed);
        assertTrue(ok, "the stored proof verifies");
    }

    function test_k16_verifier_rejects_a_changed_proof() public {
        bytes memory p = FixturesK16.proofBytes();
        p[100] ^= 0x01;
        (bool ok, bytes memory ret) = K16.call(abi.encodeCall(IHalo2Verifier.verifyProof, (p, FixturesK16.instances())));
        assertTrue(!ok || !abi.decode(ret, (bool)), "a changed proof does not verify");
    }

    function test_k16_entry_is_registered_with_the_real_code() public view {
        assertEq(registry.entry(k16Id).targetCodeHash, K16.codehash, "registered code");
        assertEq(registry.entry(k16Id).lanes, 16, "sixteen lanes");
    }
}

/// Sixteen new channels; the provider has never been paid.
contract ChannelGasK16FirstTest is ChannelK16Base {
    bytes internal data;

    function setUp() public override {
        super.setUp();
        ChannelConfig[] memory cs = _openSixteen("gas16");
        data = _k16Call(cs, _k16Frames(cs, 1));
    }

    function test_gas_k16_first_batch_new_channels_first_accrual() public {
        TxGas memory g = _measure(address(settlement), data, _coldK16());
        _log("K=16, sixteen new channels, provider's first accrual", g);
        assertEq(settlement.accrued(provider, address(token)), 16 * AMOUNT, "the measured call settled every lane");
        assertLe(g.total, 1_154_200, "pin: measured 1,154,183");
    }
}

/// The same sixteen channels' second vouchers.
contract ChannelGasK16SteadyTest is ChannelK16Base {
    bytes internal data;

    function setUp() public override {
        super.setUp();
        ChannelConfig[] memory cs = _openSixteen("gas16");
        _settleK16(cs, _k16Frames(cs, 1));
        data = _k16Call(cs, _k16Frames(cs, 2));
    }

    function test_gas_k16_steady() public {
        TxGas memory g = _measure(address(settlement), data, _coldK16());
        _log("K=16, steady", g);
        emit log_named_uint("K=16, steady, per request", g.total / 16);
        assertEq(settlement.accrued(provider, address(token)), 32 * AMOUNT, "the measured call settled every lane");
        assertLe(g.total, K16_STEADY_ACCEPTANCE, "acceptance: K=16 steady <= 1,170,000");
        assertLe(g.total, 1_137_200, "pin: measured 1,137,131");
    }
}

/// One new channel, sixteen of its vouchers in one batch; the provider has never been paid.
contract ChannelGasK16SingleChannelFirstTest is ChannelK16Base {
    bytes internal data;

    function setUp() public override {
        super.setUp();
        ChannelConfig[] memory cs = new ChannelConfig[](1);
        cs[0] = _config(payers16[0], "single16");
        _open(cs[0], keys16[0], DEPOSIT);
        data = _k16Call(cs, _k16SingleChannelFrames(cs[0], 0));
    }

    function test_gas_k16_single_channel_first_batch() public {
        TxGas memory g = _measure(address(settlement), data, _coldK16());
        _log("K=16, one channel, first batch", g);
        assertEq(settlement.accrued(provider, address(token)), 16 * AMOUNT, "the measured call settled every lane");
        assertLe(g.total, 1_050_400, "pin: measured 1,050,182");
    }
}

/// The same channel's next sixteen vouchers.
contract ChannelGasK16SingleChannelSteadyTest is ChannelK16Base {
    bytes internal data;

    function setUp() public override {
        super.setUp();
        ChannelConfig[] memory cs = new ChannelConfig[](1);
        cs[0] = _config(payers16[0], "single16");
        _open(cs[0], keys16[0], DEPOSIT);
        _settleK16(cs, _k16SingleChannelFrames(cs[0], 0));
        data = _k16Call(cs, _k16SingleChannelFrames(cs[0], 16));
    }

    function test_gas_k16_single_channel_steady() public {
        TxGas memory g = _measure(address(settlement), data, _coldK16());
        _log("K=16, one channel, steady", g);
        emit log_named_uint("K=16, one channel, steady, per request", g.total / 16);
        assertEq(settlement.accrued(provider, address(token)), 32 * AMOUNT, "the measured call settled every lane");
        assertLe(g.total, 1_033_300, "pin: measured 1,033,130");
    }
}
