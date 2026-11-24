// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GasMeter} from "./GasMeter.sol";
import {SoloSettlementBase} from "./SoloSettlementBase.sol";
import {SoloSettlement, Terms} from "../src/SoloSettlement.sol";

interface IUSDC {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function balanceOf(address) external view returns (uint256);
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}

/// The solo flows against the real USDC contract of Base Sepolia, on a local fork of that chain:
/// the same settlement contract, proof and gas method as `SoloSettlementGas.t.sol`, with Circle's
/// token (a proxy in front of FiatToken v2.2) in place of the test token. Also shows that the real
/// token accepts an ERC-1271 payer through this contract.
///
/// Skipped unless `FORK_RPC_URL` is set, so CI never depends on a network:
///
///     FORK_RPC_URL=https://sepolia.base.org forge test --match-path test/SoloSettlementFork.t.sol -vv
///
/// `FORK_BLOCK` pins the block (the figures in measurements/2026-11-23-solo-settlement/ used one);
/// without it the fork follows the latest block.
///
/// The fork runs under this repository's Osaka schedule. Figures are logged, not pinned, because
/// they depend on the live token; each test holds its transaction to the day-2 limit that applies.
abstract contract SoloForkBase is SoloSettlementBase, GasMeter {
    /// Circle's testnet USDC on Base Sepolia (developers.circle.com, "USDC contract addresses").
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    uint256 internal constant ONE_TX_TARGET = 775_000;
    uint256 internal constant ONE_TX_LIMIT = 795_000;
    uint256 internal constant OPEN_LIMIT = 130_000;

    bool internal forked;
    address internal implementation;

    function setUp() public virtual override {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blockNumber = vm.envOr("FORK_BLOCK", uint256(0));
        if (blockNumber == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNumber);
        forked = true;
        emit log_named_uint("forked at block", block.number);
        super.setUp(); // deploys the core and settlement on the fork; the test token goes unused

        tokenDomain = IUSDC(USDC).DOMAIN_SEPARATOR();
        implementation = address(uint160(uint256(vm.load(USDC, keccak256("org.zeppelinos.proxy.implementation")))));
        deal(USDC, payer, 10 * AMOUNT);
        deal(USDC, address(wallet), 10 * AMOUNT);
        deal(USDC, provider, 0);
        deal(USDC, address(settlement), 0);
    }

    modifier onlyForked() {
        if (!forked) vm.skip(true);
        _;
    }

    function _usdcTerms(bytes32 salt) internal view returns (Terms memory t) {
        t = _terms(salt);
        t.asset = USDC;
    }

    function _cold() internal view returns (address[] memory a) {
        a = new address[](9);
        (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8]) =
        (
            address(settlement),
            USDC,
            implementation,
            address(registry),
            address(adapter),
            SOLO,
            payer,
            provider,
            address(wallet)
        );
    }

    function _settleTx(Terms memory t, bytes memory sig) internal returns (TxGas memory) {
        bytes memory data = abi.encodeCall(SoloSettlement.settle, (t, soloEntry, VALID_BEFORE, sig, output, proof));
        return _measure(address(settlement), data, _cold());
    }

    function _openTx() internal returns (TxGas memory) {
        Terms memory t = _usdcTerms("gas");
        return
            _measure(
                address(settlement), abi.encodeCall(SoloSettlement.open, (t, VALID_BEFORE, _signEscrow(t))), _cold()
            );
    }

    function _releaseTx() internal returns (TxGas memory) {
        bytes memory data = abi.encodeCall(SoloSettlement.release, (_usdcTerms("gas"), soloEntry, output, proof));
        return _measure(address(settlement), data, _cold());
    }

    function _refundTx() internal returns (TxGas memory) {
        vm.warp(PROVE_BY + 1);
        return _measure(address(settlement), abi.encodeCall(SoloSettlement.refund, (_usdcTerms("gas"))), _cold());
    }
}

/// The provider has never been paid and the contract holds no USDC.
contract SoloForkFirstTest is SoloForkBase {
    function test_fork_settle_first_payment_to_the_provider() public onlyForked {
        Terms memory t = _usdcTerms("gas");
        TxGas memory g = _settleTx(t, _signPayment(t));
        _log("USDC settle, first payment to the provider", g);
        assertEq(IUSDC(USDC).balanceOf(provider), AMOUNT, "provider paid");
        // Over the 775,000 target: the provider's USDC balance goes from zero to non-zero.
        assertLe(g.total, ONE_TX_LIMIT, "hard limit");
    }

    /// Over the 130,000 limit: the contract's own USDC balance goes from zero to non-zero (22,100).
    /// It happens whenever the contract holds no USDC at all, so seeding it with one unit at
    /// deployment removes this case; the steady figure then applies.
    function test_fork_open_first_lock_held_by_the_contract() public onlyForked {
        TxGas memory g = _openTx();
        _log("USDC open, first lock held by the contract", g);
        assertEq(IUSDC(USDC).balanceOf(address(settlement)), AMOUNT, "locked");
        assertLe(g.total, OPEN_LIMIT + 22_100, "limit plus the zero-to-non-zero write");
    }
}

/// The provider has been paid before and the contract holds other locks.
contract SoloForkSteadyTest is SoloForkBase {
    function setUp() public override {
        super.setUp();
        if (!forked) return;
        deal(USDC, provider, 1);
        deal(USDC, address(settlement), 1);
    }

    function test_fork_settle_steady() public onlyForked {
        Terms memory t = _usdcTerms("gas");
        TxGas memory g = _settleTx(t, _signPayment(t));
        _log("USDC settle, steady", g);
        assertEq(IUSDC(USDC).balanceOf(provider), AMOUNT + 1, "provider paid");
        assertTrue(IUSDC(USDC).authorizationState(payer, _paymentId(t)), "authorization consumed");
        assertLe(g.total, ONE_TX_TARGET, "target");
    }

    function test_fork_open_steady() public onlyForked {
        TxGas memory g = _openTx();
        _log("USDC open, steady", g);
        assertEq(IUSDC(USDC).balanceOf(address(settlement)), AMOUNT + 1, "locked");
        assertLe(g.total, OPEN_LIMIT, "open limit");
    }

    function test_fork_smart_wallet_payer_settles_through_real_usdc() public onlyForked {
        Terms memory t = _usdcTerms("gas-1271");
        t.payer = address(wallet);
        bytes memory sig = _authorize(walletOwnerKey, address(wallet), address(settlement), AMOUNT, _paymentId(t));
        TxGas memory g = _settleTx(t, sig);
        _log("USDC settle, ERC-1271 payer, steady", g);
        assertEq(IUSDC(USDC).balanceOf(address(wallet)), 9 * AMOUNT, "wallet charged");
        assertEq(IUSDC(USDC).balanceOf(provider), AMOUNT + 1, "provider paid");
        assertLe(g.total, ONE_TX_LIMIT, "hard limit");
    }

    function test_fork_smart_wallet_that_rejects_is_not_charged_by_real_usdc() public onlyForked {
        Terms memory t = _usdcTerms("gas-1271-reject");
        t.payer = address(wallet);
        bytes memory sig = _authorize(walletOwnerKey, address(wallet), address(settlement), AMOUNT, _paymentId(t));
        wallet.setAccepting(false);
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        settlement.settle(t, soloEntry, VALID_BEFORE, sig, output, proof);
    }
}

/// One lock open, the only one; the provider has never been paid.
contract SoloForkReleaseFirstTest is SoloForkBase {
    function setUp() public override {
        super.setUp();
        if (!forked) return;
        _open(_usdcTerms("gas"));
    }

    function test_fork_release_first_payment_to_the_provider() public onlyForked {
        TxGas memory g = _releaseTx();
        _log("USDC release, first payment to the provider, last lock", g);
        assertEq(IUSDC(USDC).balanceOf(provider), AMOUNT, "provider paid");
        assertLe(g.total, ONE_TX_LIMIT, "no worse than the one-transaction limit");
    }

    function test_fork_refund_last_lock() public onlyForked {
        TxGas memory g = _refundTx();
        _log("USDC refund, last lock", g);
        assertEq(IUSDC(USDC).balanceOf(payer), 10 * AMOUNT, "payer refunded");
    }
}

/// One lock open among others; the provider has been paid before.
contract SoloForkReleaseSteadyTest is SoloForkBase {
    function setUp() public override {
        super.setUp();
        if (!forked) return;
        deal(USDC, provider, 1);
        deal(USDC, address(settlement), 1);
        _open(_usdcTerms("gas"));
    }

    function test_fork_release_steady() public onlyForked {
        TxGas memory g = _releaseTx();
        _log("USDC release, steady", g);
        assertEq(IUSDC(USDC).balanceOf(provider), AMOUNT + 1, "provider paid");
        assertLe(g.total, ONE_TX_LIMIT, "no worse than the one-transaction limit");
    }

    function test_fork_refund_steady() public onlyForked {
        TxGas memory g = _refundTx();
        _log("USDC refund, steady", g);
        assertEq(IUSDC(USDC).balanceOf(payer), 10 * AMOUNT, "payer refunded");
    }
}
