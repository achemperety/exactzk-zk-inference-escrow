// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProofVerifier} from "../../src/IProofVerifier.sol";
import {IVerifierRegistry, VerifierEntry} from "../../src/IVerifierRegistry.sol";
import {ProofCheck, ProofStatus} from "../../src/ProofCheck.sol";

// ── Stand-ins for a system-specific verifier contract ("target") ────────────────────────────────
// Each answers every call the same way, whatever the calldata.

contract AcceptAllTarget {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 0x20)
        }
    }
}

contract RejectAllTarget {
    fallback() external {
        assembly {
            mstore(0, 0)
            return(0, 0x20)
        }
    }
}

contract RevertingTarget {
    fallback() external {
        assembly {
            revert(0, 0)
        }
    }
}

/// Reverts, and the revert data is a 32-byte 1.
contract RevertsWithTrueTarget {
    fallback() external {
        assembly {
            mstore(0, 1)
            revert(0, 0x20)
        }
    }
}

/// Consumes all the gas it is given.
contract GasBurnerTarget {
    fallback() external {
        assembly {
            invalid()
        }
    }
}

contract ReturnsTwoTarget {
    fallback() external {
        assembly {
            mstore(0, 2)
            return(0, 0x20)
        }
    }
}

/// Returns 64 bytes; the first word is 1.
contract ReturnsTwoWordsTarget {
    fallback() external {
        assembly {
            mstore(0, 1)
            mstore(0x20, 1)
            return(0, 0x40)
        }
    }
}

contract ReturnsNothingTarget {
    fallback() external {
        assembly {
            return(0, 0)
        }
    }
}

/// Accepts exactly one calldata, identified by its hash.
contract ExactCalldataTarget {
    bytes32 public expected;

    function expect(bytes32 calldataHash) external {
        expected = calldataHash;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        return abi.encode(keccak256(data) == expected);
    }
}

// ── Stand-ins for an adapter ────────────────────────────────────────────────────────────────────

bytes32 constant TEST_PROOF_SYSTEM = keccak256("test/constant");

contract AlwaysTrueAdapter is IProofVerifier {
    function verify(address, uint32, bytes32[] calldata, bytes calldata, bytes calldata) external pure returns (bool) {
        return true;
    }

    function proofSystem() external pure returns (bytes32) {
        return TEST_PROOF_SYSTEM;
    }
}

contract AlwaysFalseAdapter is IProofVerifier {
    function verify(address, uint32, bytes32[] calldata, bytes calldata, bytes calldata) external pure returns (bool) {
        return false;
    }

    function proofSystem() external pure returns (bytes32) {
        return TEST_PROOF_SYSTEM;
    }
}

/// Adapters below answer `proofSystem()` properly, so they can be registered, and answer every
/// other call, `verify` included, from their fallback.
abstract contract RawAdapter {
    function proofSystem() external pure returns (bytes32) {
        return TEST_PROOF_SYSTEM;
    }
}

contract RevertingAdapter is RawAdapter {
    fallback() external {
        assembly {
            revert(0, 0)
        }
    }
}

contract RevertsWithTrueAdapter is RawAdapter {
    fallback() external {
        assembly {
            mstore(0, 1)
            revert(0, 0x20)
        }
    }
}

contract GasBurnerAdapter is RawAdapter {
    fallback() external {
        assembly {
            invalid()
        }
    }
}

contract ReturnsTwoAdapter is RawAdapter {
    fallback() external {
        assembly {
            mstore(0, 2)
            return(0, 0x20)
        }
    }
}

contract ReturnsTwoWordsAdapter is RawAdapter {
    fallback() external {
        assembly {
            mstore(0, 1)
            mstore(0x20, 1)
            return(0, 0x40)
        }
    }
}

contract ReturnsNothingAdapter is RawAdapter {
    fallback() external {
        assembly {
            return(0, 0)
        }
    }
}

/// Answers every call, `proofSystem()` included, with 1 if it had at least `threshold` gas left
/// when it looked, and 0 otherwise. It has no functions, so every call takes the same path to
/// that look. Used to observe how much gas a caller really hands over.
contract GasGaugeAdapter {
    uint256 private immutable threshold;

    constructor(uint256 threshold_) {
        threshold = threshold_;
    }

    fallback() external {
        uint256 t = threshold;
        assembly {
            mstore(0, iszero(lt(gas(), t)))
            return(0, 0x20)
        }
    }
}

// ── The library under test, made callable ───────────────────────────────────────────────────────

contract ProofCheckHarness {
    IVerifierRegistry public immutable registry;

    constructor(IVerifierRegistry registry_) {
        registry = registry_;
    }

    function checkWithEntry(
        bytes32 verifierId,
        VerifierEntry calldata e,
        bytes32[] calldata commitments,
        bytes calldata outputs,
        bytes calldata proof
    ) external view returns (ProofStatus) {
        return ProofCheck.check(registry, verifierId, e, commitments, outputs, proof);
    }

    function checkById(bytes32 verifierId, bytes32[] calldata commitments, bytes calldata outputs, bytes calldata proof)
        external
        view
        returns (ProofStatus)
    {
        return ProofCheck.check(registry, verifierId, commitments, outputs, proof);
    }
}
