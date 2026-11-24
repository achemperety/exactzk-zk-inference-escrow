#!/usr/bin/env python3
"""
Dollar-cost conversion for K=16 settlement gas, using this session's own
MEASURED settle_k16_results.json gas figures. Fjord L1-fee formula and oracle
fetch logic COPIED (not imported) from the previous repository's cost
model, which is not part of this repository. Read-only RPC call to live Base Sepolia (no chain transactions).
"""
import json, os, sys
from web3 import Web3

RPC_URL = "https://sepolia.base.org"
ETH_USD = 3000.0  # project-standard assumption, used for every published $ figure

ORACLE_ADDR = "0x420000000000000000000000000000000000000F"
ORACLE_ABI = [
    {"name": "baseFeeScalar",     "type": "function", "inputs": [], "outputs": [{"type": "uint32"}],  "stateMutability": "view"},
    {"name": "blobBaseFeeScalar", "type": "function", "inputs": [], "outputs": [{"type": "uint32"}],  "stateMutability": "view"},
    {"name": "l1BaseFee",         "type": "function", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view"},
    {"name": "blobBaseFee",       "type": "function", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view"},
]

FJORD_COEFFICIENT  =    836_500
FJORD_INTERCEPT    = -42_585_600
FJORD_SCALE        =  1_000_000
MIN_TX_SIZE_SCALED =  100 * FJORD_SCALE


def fjord_l1_fee(calldata_bytes, base_fee_scalar, blob_base_fee_scalar, l1_base_fee_wei, blob_base_fee_wei):
    estimated_scaled = max(MIN_TX_SIZE_SCALED, FJORD_INTERCEPT + FJORD_COEFFICIENT * calldata_bytes)
    if estimated_scaled <= 0:
        return 0
    l1_fee_scaled = base_fee_scalar * l1_base_fee_wei * 16 + blob_base_fee_scalar * blob_base_fee_wei
    return (estimated_scaled * l1_fee_scaled) // 1_000_000_000_000


def usd(wei, eth_usd):
    return wei * eth_usd / 1e18


def channel_batch_calldata_bytes(k):
    return 4_068 + 640 * k  # DERIVED from the batch calldata layout; exact match confirmed at K=1, K=8


def main():
    w3 = Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"timeout": 15}))
    assert w3.is_connected(), "cannot reach Base Sepolia"
    oracle = w3.eth.contract(address=w3.to_checksum_address(ORACLE_ADDR), abi=ORACLE_ABI)
    base_fee_scalar = oracle.functions.baseFeeScalar().call()
    blob_base_fee_scalar = oracle.functions.blobBaseFeeScalar().call()
    l1_base_fee_wei = oracle.functions.l1BaseFee().call()
    blob_base_fee_wei = oracle.functions.blobBaseFee().call()
    l2_gas_price_wei = w3.eth.gas_price
    block_number = w3.eth.block_number

    print(f"Base Sepolia oracle @ block {block_number}:")
    print(f"  baseFeeScalar={base_fee_scalar} blobBaseFeeScalar={blob_base_fee_scalar}")
    print(f"  l1BaseFee={l1_base_fee_wei/1e9:.4f} gwei  blobBaseFee={blob_base_fee_wei/1e9:.6f} gwei")
    print(f"  L2 gasPrice={l2_gas_price_wei/1e9:.6f} gwei")

    with open(os.path.join(os.path.dirname(__file__), "settle_k16_results.json")) as f:
        r16 = json.load(f)
    K = r16["K"]
    steady_gas_per_req = r16["derive"]["steady_per_request"]
    cold_gas_per_req = r16["derive"]["cold_per_request"]
    steady_batch_gas = r16["derive"]["steady_gas"]
    cold_batch_gas = r16["derive"]["cold_gas"]

    calldata_per_req = channel_batch_calldata_bytes(K) / K

    results = {}
    for label, gas_per_req in [("steady", steady_gas_per_req), ("cold", cold_gas_per_req)]:
        l2_wei = int(gas_per_req) * l2_gas_price_wei
        l1_wei = fjord_l1_fee(calldata_per_req, base_fee_scalar, blob_base_fee_scalar, l1_base_fee_wei, blob_base_fee_wei)
        l2_usd = usd(l2_wei, ETH_USD)
        l1_usd = usd(l1_wei, ETH_USD)
        total_usd = l2_usd + l1_usd
        results[label] = {
            "gas_per_request": gas_per_req, "calldata_bytes_per_request": calldata_per_req,
            "l2_exec_usd": l2_usd, "l1_data_usd": l1_usd, "total_usd": total_usd,
        }
        print(f"\nK=16 {label}: gas/req={gas_per_req:,.1f}  calldata/req={calldata_per_req:.1f}B")
        print(f"  L2 exec cost: ${l2_usd:.6f}   L1 data cost: ${l1_usd:.6f}   TOTAL: ${total_usd:.6f}")

    # cross-check against K=8 steady (measured 2026-09-18: 138,921 gas/request) using
    # the identical live-fetched oracle values, to confirm this script reproduces
    # the project's own published $ figures under today's conditions.
    k8_steady_gas = 138_921
    k8_calldata = channel_batch_calldata_bytes(8) / 8
    k8_l2 = usd(k8_steady_gas * l2_gas_price_wei, ETH_USD)
    k8_l1 = usd(fjord_l1_fee(k8_calldata, base_fee_scalar, blob_base_fee_scalar, l1_base_fee_wei, blob_base_fee_wei), ETH_USD)
    print(f"\nCross-check K=8 steady (measured 138,921 gas/req): L2=${k8_l2:.6f} L1=${k8_l1:.6f} TOTAL=${k8_l2+k8_l1:.6f}")
    results["k8_steady_crosscheck_total_usd"] = k8_l2 + k8_l1

    solo_gas = 720_888
    solo_calldata = 4_776
    solo_l2 = usd(solo_gas * l2_gas_price_wei, ETH_USD)
    solo_l1 = usd(fjord_l1_fee(solo_calldata, base_fee_scalar, blob_base_fee_scalar, l1_base_fee_wei, blob_base_fee_wei), ETH_USD)
    print(f"Cross-check solo settle (measured locally: 720,888 gas): L2=${solo_l2:.6f} L1=${solo_l1:.6f} TOTAL=${solo_l2+solo_l1:.6f}")
    results["solo_settle_crosscheck_total_usd"] = solo_l2 + solo_l1

    results["oracle"] = {
        "block_number": block_number, "base_fee_scalar": base_fee_scalar,
        "blob_base_fee_scalar": blob_base_fee_scalar,
        "l1_base_fee_gwei": l1_base_fee_wei/1e9, "blob_base_fee_gwei": blob_base_fee_wei/1e9,
        "l2_gas_price_gwei": l2_gas_price_wei/1e9, "eth_usd": ETH_USD,
    }
    with open(os.path.join(os.path.dirname(__file__), "price_k16_results.json"), "w") as f:
        json.dump(results, f, indent=2)


if __name__ == "__main__":
    main()
