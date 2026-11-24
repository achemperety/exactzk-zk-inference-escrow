// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProofCoreBase} from "./ProofCoreBase.sol";
import {AlwaysTrueAdapter} from "./mocks/Mocks.sol";
import {MockERC3009, MockSmartWallet} from "./mocks/MockERC3009.sol";
import {VerifierEntry} from "../src/IVerifierRegistry.sol";
import {SoloSettlement, Terms} from "../src/SoloSettlement.sol";

/// Shared setup for the solo settlement tests: the proof-system core from `ProofCoreBase`, a
/// test token, the settlement contract, an EOA payer, a smart-wallet payer, and a second
/// one-lane entry whose adapter accepts everything (to show that terms naming one verifier
/// cannot be settled through another).
abstract contract SoloSettlementBase is ProofCoreBase {
    uint256 internal constant T0 = 1_750_000_000;
    uint256 internal constant AMOUNT = 1_000_000; // 1 USDC
    uint64 internal constant PROVE_BY = uint64(T0 + 3600);
    uint256 internal constant VALID_BEFORE = T0 + 7200;

    bytes32 internal constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant PAYMENT_TYPEHASH = keccak256(
        "ProofGatedPayment(uint256 chainId,address settlement,address payer,address payTo,address asset,"
        "uint256 amount,bytes32 verifierId,bytes32 inputCommitment,uint64 proveBy,bytes32 salt)"
    );
    bytes32 internal constant ESCROW_TYPEHASH = keccak256(
        "ProofGatedEscrow(uint256 chainId,address settlement,address payer,address payTo,address asset,"
        "uint256 amount,bytes32 verifierId,bytes32 inputCommitment,uint64 proveBy,bytes32 salt)"
    );

    MockERC3009 internal token;
    SoloSettlement internal settlement;
    bytes32 internal tokenDomain;

    address internal payer;
    uint256 internal payerKey;
    address internal provider = makeAddr("provider");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");

    MockSmartWallet internal wallet;
    uint256 internal walletOwnerKey;

    VerifierEntry internal trueEntry; // one lane, adapter returns true for anything
    bytes32 internal trueId;

    bytes32 internal commitment; // the solo proof's input commitment
    bytes internal output; // the solo proof's 320-byte output
    bytes internal proof;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(T0);

        token = new MockERC3009();
        settlement = new SoloSettlement(registry);
        tokenDomain = token.DOMAIN_SEPARATOR();

        (payer, payerKey) = makeAddrAndKey("payer");
        token.mint(payer, 10 * AMOUNT);

        address walletOwner;
        (walletOwner, walletOwnerKey) = makeAddrAndKey("wallet owner");
        wallet = new MockSmartWallet(walletOwner);
        token.mint(address(wallet), 10 * AMOUNT);

        AlwaysTrueAdapter yes = new AlwaysTrueAdapter();
        trueEntry = _entry(address(yes), address(0), 1, OUTPUT_SIZE, SOLO_VERIFY_GAS, SOLO_VK_HASH);
        trueId = registry.register(trueEntry);

        bytes32[] memory c;
        (c, output, proof) = _solo();
        commitment = c[0];
    }

    // ── Terms and ids ───────────────────────────────────────────────────────────────────────────

    function _terms(bytes32 salt) internal view returns (Terms memory) {
        return Terms({
            payer: payer,
            payTo: provider,
            asset: address(token),
            amount: AMOUNT,
            verifierId: soloId,
            inputCommitment: commitment,
            proveBy: PROVE_BY,
            salt: salt
        });
    }

    /// Request id as a client computes it, for any chain id and settlement address.
    function _id(bytes32 typehash, uint256 chainId, address at, Terms memory t) internal pure returns (bytes32) {
        return keccak256(abi.encode(typehash, chainId, at, t));
    }

    function _paymentId(Terms memory t) internal view returns (bytes32) {
        return _id(PAYMENT_TYPEHASH, block.chainid, address(settlement), t);
    }

    function _escrowId(Terms memory t) internal view returns (bytes32) {
        return _id(ESCROW_TYPEHASH, block.chainid, address(settlement), t);
    }

    // ── Signatures ──────────────────────────────────────────────────────────────────────────────

    /// ERC-3009 ReceiveWithAuthorization signature by `key` for `from`, paying `to`.
    function _authorize(uint256 key, address from, address to, uint256 value, bytes32 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                tokenDomain,
                keccak256(abi.encode(RECEIVE_TYPEHASH, from, to, value, uint256(0), VALID_BEFORE, nonce))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// The payer's authorization for the one-transaction flow of `t`.
    function _signPayment(Terms memory t) internal view returns (bytes memory) {
        return _authorize(payerKey, t.payer, address(settlement), t.amount, _paymentId(t));
    }

    /// The payer's authorization for the escrow flow of `t`.
    function _signEscrow(Terms memory t) internal view returns (bytes memory) {
        return _authorize(payerKey, t.payer, address(settlement), t.amount, _escrowId(t));
    }

    // ── Calls ───────────────────────────────────────────────────────────────────────────────────

    function _settle(Terms memory t, bytes memory sig) internal {
        settlement.settle(t, soloEntry, VALID_BEFORE, sig, output, proof);
    }

    function _open(Terms memory t) internal returns (bytes32) {
        bytes memory sig = _signEscrow(t);
        vm.prank(relayer);
        return settlement.open(t, VALID_BEFORE, sig);
    }

    function _release(Terms memory t) internal {
        settlement.release(t, soloEntry, output, proof);
    }

    function _state(bytes32 id) internal view returns (SoloSettlement.EscrowState) {
        return settlement.escrowState(id);
    }

    function _assertState(bytes32 id, SoloSettlement.EscrowState expected) internal view {
        assertEq(uint8(settlement.escrowState(id)), uint8(expected), "escrow state");
    }

    /// `output` with word `index` increased by one.
    function _changedOutput(uint256 index) internal view returns (bytes memory o) {
        o = bytes.concat(output);
        _setWord(o, index, _word(o, index) + 1);
    }

    /// `proof` with one byte flipped.
    function _changedProof() internal view returns (bytes memory p) {
        p = bytes.concat(proof);
        p[100] = bytes1(uint8(p[100]) ^ 0x01);
    }
}
