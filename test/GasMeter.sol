// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// Rebuilds what a call would cost as a transaction of its own.
///
/// A Foundry test runs as one transaction, so a call inside it is charged neither the 21,000 base
/// nor calldata, and the storage refund is settled only at the end. Here: 21,000, plus calldata at
/// 4 gas per zero byte and 16 per non-zero byte (or the EIP-7623 floor of 10 and 40, if higher),
/// plus the gas the call frame used, minus its refund capped at a fifth of the total. Every listed
/// account and its storage is made cold first, as at the start of a transaction. The callee's own
/// account access is not counted, which matches a transaction sent to it directly.
abstract contract GasMeter is Test {
    struct TxGas {
        uint256 calldataGas; // EIP-2028 cost of the whole calldata
        uint256 execution; // gas used by the call frame, before refund
        uint256 refund; // refund applied, after the one-fifth cap
        uint256 total; // what the transaction would be charged
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 standard, uint256 floor) {
        uint256 zeros;
        for (uint256 i = 0; i < data.length; i++) {
            if (data[i] == 0) zeros++;
        }
        uint256 tokens = zeros + 4 * (data.length - zeros);
        return (4 * tokens, 10 * tokens);
    }

    function _measure(address to, bytes memory data, address[] memory cold) internal returns (TxGas memory g) {
        return _measure(address(this), to, data, cold);
    }

    /// The same, sent by `from`.
    function _measure(address from, address to, bytes memory data, address[] memory cold)
        internal
        returns (TxGas memory g)
    {
        for (uint256 i = 0; i < cold.length; i++) {
            vm.cool(cold[i]);
        }
        if (from != address(this)) vm.prank(from);
        (bool ok,) = to.call(data);
        assertTrue(ok, "measured call must succeed");
        Vm.Gas memory used = vm.lastCallGas();

        uint256 floor;
        (g.calldataGas, floor) = _calldataGas(data);
        g.execution = used.gasTotalUsed;
        uint256 beforeRefund = 21_000 + g.calldataGas + g.execution;
        uint256 refund = used.gasRefunded > 0 ? uint256(uint64(used.gasRefunded)) : 0;
        g.refund = refund < beforeRefund / 5 ? refund : beforeRefund / 5;
        g.total = beforeRefund - g.refund;
        if (g.total < 21_000 + floor) g.total = 21_000 + floor;
    }

    function _log(string memory label, TxGas memory g) internal {
        emit log_named_uint(string.concat(label, ": total"), g.total);
        emit log_named_uint(string.concat(label, ":   intrinsic"), 21_000);
        emit log_named_uint(string.concat(label, ":   calldata"), g.calldataGas);
        emit log_named_uint(string.concat(label, ":   execution"), g.execution);
        emit log_named_uint(string.concat(label, ":   refund"), g.refund);
    }
}
