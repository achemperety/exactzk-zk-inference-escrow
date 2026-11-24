#!/usr/bin/env python3
"""Steady-state gas measurement, 2026-09-18. See harness.py / fixtures_k8.py."""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import harness as H
import fixtures_k8 as FX

HERE = os.path.dirname(__file__)
RESULTS_PATH = os.path.join(HERE, "results.json")

results = {"transactions": []}


def record_tx(scenario, receipt, extra=None):
    entry = {
        "scenario": scenario,
        "tx_hash": receipt.transactionHash.hex(),
        "gasUsed_script": receipt.gasUsed,
        "status": receipt.status,
    }
    if extra:
        entry.update(extra)
    results["transactions"].append(entry)
    print(f"  [{scenario}] gasUsed={receipt.gasUsed:,} tx={entry['tx_hash']}")
    return entry


def main():
    from web3 import Web3

    print("=== steady-state gas measurement ===")
    print("Building contracts...")
    import subprocess
    b = subprocess.run([os.path.join(H.FOUNDRY_BIN, "forge"), "build"], cwd=H.CONTRACTS_DIR,
                        capture_output=True, text=True)
    if b.returncode != 0:
        print(b.stdout, b.stderr)
        raise RuntimeError("forge build failed")

    proof_bytes = FX.load_proof_bytes()
    instances = FX.load_instances()
    verifier_hex = FX.load_verifier_bytecode_hex()
    lane_commitments = instances[:8]
    print(f"FixturesK8: proof={len(proof_bytes)}B instances={len(instances)} verifier={len(verifier_hex)//2}B")

    print("\nStarting Anvil on port 19545...")
    anvil = H.start_anvil(19545)
    w3 = Web3(Web3.HTTPProvider(H.RPC_URL))
    print(f"  chainId={w3.eth.chain_id} block={w3.eth.block_number}")

    try:
        # ── STEP 1: ANCHOR (real K=8 verifier, real proof, cold) ──────────
        print("\n── STEP 1: ANCHOR (real verifier, cold-start K=8) ──────────")
        stack1 = H.deploy_stack(w3, "MnistMLP/v2-anchor", batch_verifier_bytecode_hex=verifier_hex)
        print(f"  usdc={stack1['usdc_addr']} escrow={stack1['escrow_addr']} vkBatch={stack1['vk_batch_addr']}")
        channel_ids_1, open_receipts_1, _, escrow_ds_1 = H.open_8_channels(w3, stack1, salt_base=1000)
        frames_1 = H.build_frames(w3, stack1, channel_ids_1, escrow_ds_1, seq=1, lane_commitments=lane_commitments)

        r1 = H.send_tx(w3, stack1["escrow"], "settleChannelBatch",
                        stack1["model_id"], frames_1, proof_bytes, instances, key=H.PROVIDER_KEY)
        e1 = record_tx("step1_anchor_cold_real", r1)

        expected = 1_265_211
        diff = r1.gasUsed - expected
        gate_pass = abs(diff) <= 100
        results["step1_gate"] = {"expected": expected, "measured": r1.gasUsed, "diff": diff, "pass": gate_pass}
        print(f"  expected={expected:,} measured={r1.gasUsed:,} diff={diff:+,} GATE={'PASS' if gate_pass else 'FAIL'}")

        # ── STEP 3: MOCK BASELINES (a) fresh provider balance, (b) prefunded ──
        print("\n── STEP 3a: mock AlwaysTrueVerifier, provider balance=0 (fresh) ──")
        atv_artifact = H.load_artifact("AlwaysTrueVerifier", "ZkChannelV2.t.sol/AlwaysTrueVerifier.json")
        stack3a = H.deploy_stack(w3, "MnistMLP/v2-mock-a", batch_verifier_artifact=atv_artifact)
        print(f"  usdc={stack3a['usdc_addr']} escrow={stack3a['escrow_addr']} vkBatch={stack3a['vk_batch_addr']}")
        provider_bal_before_3a = stack3a["usdc"].functions.balanceOf(stack3a["provider_acct"].address).call()
        channel_ids_3a, _, _, escrow_ds_3a = H.open_8_channels(w3, stack3a, salt_base=2000)
        frames_3a = H.build_frames(w3, stack3a, channel_ids_3a, escrow_ds_3a, seq=1, lane_commitments=lane_commitments)
        r3a = H.send_tx(w3, stack3a["escrow"], "settleChannelBatch",
                         stack3a["model_id"], frames_3a, proof_bytes, instances, key=H.PROVIDER_KEY)
        provider_bal_after_3a = stack3a["usdc"].functions.balanceOf(stack3a["provider_acct"].address).call()
        record_tx("step3a_mock_cold_provider_zero", r3a,
                   {"provider_bal_before": provider_bal_before_3a, "provider_bal_after": provider_bal_after_3a})

        print("\n── STEP 3b: mock AlwaysTrueVerifier, provider pre-funded ──")
        stack3b = H.deploy_stack(w3, "MnistMLP/v2-mock-b", batch_verifier_artifact=atv_artifact)
        print(f"  usdc={stack3b['usdc_addr']} escrow={stack3b['escrow_addr']} vkBatch={stack3b['vk_batch_addr']}")
        H.send_tx(w3, stack3b["usdc"], "mint", stack3b["provider_acct"].address, 12_345_678, key=H.PROVIDER_KEY)
        provider_bal_before_3b = stack3b["usdc"].functions.balanceOf(stack3b["provider_acct"].address).call()
        channel_ids_3b, _, _, escrow_ds_3b = H.open_8_channels(w3, stack3b, salt_base=3000)
        frames_3b = H.build_frames(w3, stack3b, channel_ids_3b, escrow_ds_3b, seq=1, lane_commitments=lane_commitments)
        r3b = H.send_tx(w3, stack3b["escrow"], "settleChannelBatch",
                         stack3b["model_id"], frames_3b, proof_bytes, instances, key=H.PROVIDER_KEY)
        provider_bal_after_3b = stack3b["usdc"].functions.balanceOf(stack3b["provider_acct"].address).call()
        record_tx("step3b_mock_cold_provider_prefunded", r3b,
                   {"provider_bal_before": provider_bal_before_3b, "provider_bal_after": provider_bal_after_3b})

        results["step3_comparison"] = {
            "a_minus_b": r3a.gasUsed - r3b.gasUsed,
            "a_vs_612763": r3a.gasUsed - 612_763,
            "b_vs_592831": r3b.gasUsed - 592_831,
        }
        print(f"  (a)-(b) = {r3a.gasUsed - r3b.gasUsed:,}")
        print(f"  (a) vs earlier baseline 612,763: {r3a.gasUsed - 612_763:+,}")
        print(f"  (b) vs earlier baseline 592,831: {r3b.gasUsed - 592_831:+,}")

        # ── save intermediate results before we touch the slow ezkl step ──
        with open(RESULTS_PATH, "w") as f:
            json.dump(results, f, indent=2, default=str)
        print(f"\nIntermediate results written to {RESULTS_PATH}")

        # ── STEP 2: DIRECT STEADY (poll background fresh-proof job) ────────
        print("\n── STEP 2: DIRECT STEADY (poll gen_fresh_proof.py) ──────────")
        status_path = os.path.join(HERE, "proof2_status.json")
        deadline = time.time() + 600  # 10 min bound
        fresh_state = None
        while time.time() < deadline:
            if os.path.exists(status_path):
                with open(status_path) as f:
                    fresh_state = json.load(f)
                if fresh_state.get("state") in ("proved", "failed"):
                    break
            time.sleep(5)
        results["fresh_proof_job_final_status"] = fresh_state
        print(f"  fresh-proof job status: {fresh_state}")

        use_fresh = False
        proof2_bytes = None
        if fresh_state and fresh_state.get("state") == "proved":
            proof2_path = os.path.join(HERE, "proof2.json")
            with open(proof2_path) as f:
                proof2_json = json.load(f)
            hex_proof2 = proof2_json["hex_proof"]
            if hex_proof2.startswith("0x"):
                hex_proof2 = hex_proof2[2:]
            proof2_bytes = bytes.fromhex(hex_proof2)
            # Verify against the etched real verifier via eth_call before using it live.
            verifier_contract = w3.eth.contract(
                address=w3.to_checksum_address(stack1["vk_batch_addr"]),
                abi=[{"inputs": [{"name": "proof", "type": "bytes"}, {"name": "instances", "type": "uint256[]"}],
                      "name": "verifyProof", "outputs": [{"name": "", "type": "bool"}],
                      "stateMutability": "view", "type": "function"}],
            )
            try:
                ok = verifier_contract.functions.verifyProof(proof2_bytes, instances).call()
                results["fresh_proof_verifies_against_fixturesK8_verifier"] = bool(ok)
                use_fresh = bool(ok)
                print(f"  fresh proof2 verify_evm-style eth_call against FixturesK8 verifier: {ok}")
            except Exception as e:
                results["fresh_proof_verifies_against_fixturesK8_verifier"] = f"eth_call reverted: {e}"
                print(f"  fresh proof2 eth_call reverted: {e}")
                use_fresh = False

        if use_fresh:
            settle_proof_bytes = proof2_bytes
            settle_note = "freshly generated via ezkl.prove() on current pk.key/witness.json, verified OK"
        else:
            settle_proof_bytes = proof_bytes
            settle_note = ("REUSED FixturesK8 proof bytes (not freshly generated) — fresh-proof job "
                            f"did not produce a usable proof: {fresh_state}")
        results["step2_proof_source"] = settle_note
        print(f"  step2 proof source: {settle_note}")

        frames_1_seq2 = H.build_frames(w3, stack1, channel_ids_1, escrow_ds_1, seq=2, lane_commitments=lane_commitments)
        r2 = H.send_tx(w3, stack1["escrow"], "settleChannelBatch",
                        stack1["model_id"], frames_1_seq2, settle_proof_bytes, instances, key=H.PROVIDER_KEY)
        record_tx("step2_direct_steady_seq2", r2)

        frames_1_seq3 = H.build_frames(w3, stack1, channel_ids_1, escrow_ds_1, seq=3, lane_commitments=lane_commitments)
        r2c = H.send_tx(w3, stack1["escrow"], "settleChannelBatch",
                         stack1["model_id"], frames_1_seq3, settle_proof_bytes, instances, key=H.PROVIDER_KEY)
        record_tx("step2_steady_sanity_seq3", r2c)

        results["step2_derive"] = {
            "cold_gas": r1.gasUsed,
            "steady_gas": r2.gasUsed,
            "steady_sanity_gas_seq3": r2c.gasUsed,
            "steady_per_request": r2.gasUsed // 8,
            "cold_minus_steady": r1.gasUsed - r2.gasUsed,
        }

        # ── STEP 4: CROSS-CHECK every tx via cast receipt ─────────────────
        print("\n── STEP 4: cross-check via cast receipt ──────────────────")
        for entry in results["transactions"]:
            cast_gas = H.cast_receipt_gas_used(entry["tx_hash"])
            entry["gasUsed_cast"] = cast_gas
            entry["match"] = (cast_gas == entry["gasUsed_script"])
            print(f"  {entry['scenario']}: script={entry['gasUsed_script']:,} cast={cast_gas:,} match={entry['match']}")

        with open(RESULTS_PATH, "w") as f:
            json.dump(results, f, indent=2, default=str)
        print(f"\nFinal results written to {RESULTS_PATH}")

    finally:
        print("\nStopping Anvil...")
        anvil.terminate()
        anvil.wait()


if __name__ == "__main__":
    main()
