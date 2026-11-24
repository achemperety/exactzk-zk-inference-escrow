#!/usr/bin/env python3
"""
K=16 settlement gas measurement, real Halo2Verifier + real K=16 proof, on a
fresh local Anvil instance. Mirrors measurements/2026-09-18-steady/'s method
for K=8 (cold vs steady-state, cross-checked with `cast receipt`), generalized
to K=16 with a freshly-deployed (not etched-fixture) verifier since no
FixturesK16.sol exists.

No contract source is touched. No public-network transactions.
"""
import asyncio, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
CONTRACTS_DIR = os.path.join(PROJECT_ROOT, "contracts")
CONTRACTS_OUT = os.path.join(PROJECT_ROOT, "contracts", "out")
FOUNDRY_BIN = os.path.expanduser("~/.foundry/bin")
K16_WORK = os.path.join(HERE, "k16_work")

RPC_PORT = 19549
RPC_URL = f"http://127.0.0.1:{RPC_PORT}"

PROVIDER_KEY = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # no 0x, ezkl requirement
CLIENT_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

NUM_OUTPUTS = 10
H_DUMMY = 0  # no dummy lanes used in this measurement; real commitments are never 0
AMOUNT = 1_000_000
DEPOSIT = 50_000_000
PROVE_WIN_SEC = 10
K = 16

RESULTS_PATH = os.path.join(HERE, "settle_k16_results.json")


def load_artifact(name):
    path = os.path.join(CONTRACTS_OUT, f"{name}.sol", f"{name}.json")
    with open(path) as f:
        return json.load(f)


def start_anvil(port):
    proc = subprocess.Popen(
        [os.path.join(FOUNDRY_BIN, "anvil"), "--port", str(port), "--block-time", "1", "--silent"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    from web3 import Web3
    deadline = time.time() + 20
    while time.time() < deadline:
        try:
            w3 = Web3(Web3.HTTPProvider(f"http://127.0.0.1:{port}"))
            if w3.is_connected():
                return proc
        except Exception:
            pass
        time.sleep(0.3)
    proc.terminate()
    raise RuntimeError("anvil did not start")


def deploy_contract(w3, artifact, *ctor_args, key):
    from eth_account import Account
    acct = Account.from_key(key)
    contract = w3.eth.contract(abi=artifact["abi"], bytecode=artifact["bytecode"]["object"])
    tx = contract.constructor(*ctor_args).build_transaction({
        "from": acct.address, "nonce": w3.eth.get_transaction_count(acct.address),
    })
    tx["gas"] = int(w3.eth.estimate_gas(tx) * 1.3)
    signed = Account.sign_transaction(tx, key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    assert receipt.status == 1, "deploy reverted"
    return receipt.contractAddress


def send_tx(w3, contract, fn_name, *args, key, gas_override=None):
    from eth_account import Account
    acct = Account.from_key(key)
    fn = getattr(contract.functions, fn_name)
    tx = fn(*args).build_transaction({
        "from": acct.address, "nonce": w3.eth.get_transaction_count(acct.address),
    })
    tx["gas"] = gas_override if gas_override else int(w3.eth.estimate_gas(tx) * 1.3)
    signed = Account.sign_transaction(tx, key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)
    assert receipt.status == 1, f"{fn_name} reverted (tx {tx_hash.hex()})"
    return receipt


def erc3009_typehash(w3):
    return w3.keccak(text=(
        "ReceiveWithAuthorization(address from,address to,uint256 value,"
        "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    ))


def voucher_v2_typehash(w3):
    return w3.keccak(text=(
        "VoucherV2(bytes32 channelId,uint64 seq,bytes32 modelId,"
        "uint256 inputCommitment,uint256 amount,uint256 cumAmount,uint64 proveBy)"
    ))


def sign_erc3009(w3, key, domain_sep, from_addr, to_addr, value, valid_before, nonce):
    from eth_abi import encode as abi_encode
    from eth_account import Account
    from eth_account.messages import SignableMessage
    th = erc3009_typehash(w3)
    struct_hash = w3.keccak(abi_encode(
        ['bytes32', 'address', 'address', 'uint256', 'uint256', 'uint256', 'bytes32'],
        [th, from_addr, to_addr, value, 0, valid_before, nonce],
    ))
    signed = Account.from_key(key).sign_message(
        SignableMessage(version=b'\x01', header=domain_sep, body=bytes(struct_hash))
    )
    return signed.v, signed.r.to_bytes(32, 'big'), signed.s.to_bytes(32, 'big')


def sign_voucher_v2(w3, key, domain_sep, channel_id, seq, model_id, input_commitment,
                     amount, cum_amount, prove_by):
    from eth_abi import encode as abi_encode
    from eth_account import Account
    from eth_account.messages import SignableMessage
    th = voucher_v2_typehash(w3)
    struct_hash = w3.keccak(abi_encode(
        ['bytes32', 'bytes32', 'uint64', 'bytes32', 'uint256', 'uint256', 'uint256', 'uint64'],
        [th, channel_id, seq, model_id, input_commitment, amount, cum_amount, prove_by],
    ))
    signed = Account.from_key(key).sign_message(
        SignableMessage(version=b'\x01', header=domain_sep, body=bytes(struct_hash))
    )
    return signed.v, signed.r.to_bytes(32, 'big'), signed.s.to_bytes(32, 'big')


async def _create_and_deploy_verifier():
    import ezkl
    vk_path = os.path.join(K16_WORK, "vk.key")
    settings_path = os.path.join(K16_WORK, "settings.json")
    srs_path = os.path.join(K16_WORK, "srs.bin")
    sol_path = os.path.join(K16_WORK, "Halo2Verifier_k16.sol")
    abi_path = os.path.join(K16_WORK, "Halo2Verifier_k16.abi")

    print("  create_evm_verifier (K=16) ...", flush=True)
    t0 = time.perf_counter()
    result = ezkl.create_evm_verifier(
        vk_path=vk_path, settings_path=settings_path, sol_code_path=sol_path,
        abi_path=abi_path, srs_path=srs_path, reusable=False,
    )
    if asyncio.iscoroutine(result) or asyncio.isfuture(result):
        result = await result
    print(f"    done in {time.perf_counter()-t0:.2f}s, sol size={os.path.getsize(sol_path)} bytes", flush=True)

    print("  deploy_evm (K=16 verifier) ...", flush=True)
    import tempfile
    addr_path = tempfile.mktemp(suffix=".addr")
    t0 = time.perf_counter()
    result = ezkl.deploy_evm(
        addr_path=addr_path, rpc_url=RPC_URL, sol_code_path=sol_path,
        optimizer_runs=1, private_key=PROVIDER_KEY,
    )
    if asyncio.iscoroutine(result) or asyncio.isfuture(result):
        result = await result
    await asyncio.sleep(2)
    print(f"    done in {time.perf_counter()-t0:.2f}s", flush=True)
    with open(addr_path) as f:
        addr = f.read().strip()
    return addr


def cast_receipt_gas_used(tx_hash_hex):
    out = subprocess.run(
        [os.path.join(FOUNDRY_BIN, "cast"), "receipt", tx_hash_hex, "gasUsed", "--rpc-url", RPC_URL],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        raise RuntimeError(f"cast receipt failed: {out.stderr}")
    val = out.stdout.strip()
    return int(val, 16) if val.startswith("0x") else int(val)


def load_proof_and_instances():
    with open(os.path.join(K16_WORK, "proof.json")) as f:
        proof_json = json.load(f)
    proof_bytes = bytes(proof_json["proof"])
    instances_le = proof_json["instances"][0]
    instances_be = [int.from_bytes(bytes.fromhex(le), "little") for le in instances_le]
    expected_len = K * (1 + NUM_OUTPUTS)
    assert len(instances_be) == expected_len, f"got {len(instances_be)}, expected {expected_len}"
    return proof_bytes, instances_be


def main():
    from web3 import Web3

    results = {"transactions": [], "K": K}

    print("Building contracts (forge build, for MockERC3009 / ZkInferenceEscrowV2 artifacts only)...")
    b = subprocess.run([os.path.join(FOUNDRY_BIN, "forge"), "build"], cwd=CONTRACTS_DIR,
                        capture_output=True, text=True)
    if b.returncode != 0:
        print(b.stdout, b.stderr)
        raise RuntimeError("forge build failed")

    proof_bytes, instances = load_proof_and_instances()
    lane_commitments = instances[:K]
    print(f"Loaded K=16 proof: {len(proof_bytes)} bytes, {len(instances)} instances")

    print(f"\nStarting Anvil on port {RPC_PORT}...")
    anvil = start_anvil(RPC_PORT)
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    print(f"  chainId={w3.eth.chain_id} block={w3.eth.block_number}")

    try:
        loop = asyncio.new_event_loop()
        vk_batch_addr = loop.run_until_complete(_create_and_deploy_verifier())
        loop.run_until_complete(asyncio.sleep(1))
        loop.close()
        print(f"  K=16 Halo2Verifier deployed at {vk_batch_addr}")
        results["vk_batch_addr"] = vk_batch_addr

        # sanity: verify the real proof against the real deployed verifier via eth_call
        verifier_probe = w3.eth.contract(
            address=w3.to_checksum_address(vk_batch_addr),
            abi=[{"inputs": [{"name": "proof", "type": "bytes"}, {"name": "instances", "type": "uint256[]"}],
                  "name": "verifyProof", "outputs": [{"name": "", "type": "bool"}],
                  "stateMutability": "view", "type": "function"}],
        )
        ok = verifier_probe.functions.verifyProof(proof_bytes, instances).call()
        print(f"  eth_call verifyProof sanity check: {ok}")
        results["verify_precheck_eth_call"] = bool(ok)
        assert ok, "real K=16 proof does not verify against the freshly deployed verifier — aborting"

        from eth_account import Account
        provider_acct = Account.from_key(PROVIDER_KEY if PROVIDER_KEY.startswith("0x") else "0x" + PROVIDER_KEY)
        client_acct = Account.from_key(CLIENT_KEY)
        provider_key_0x = "0x" + PROVIDER_KEY if not PROVIDER_KEY.startswith("0x") else PROVIDER_KEY

        print("\nDeploying MockERC3009 + ZkInferenceEscrowV2...")
        usdc_artifact = load_artifact("MockERC3009")
        usdc_addr = deploy_contract(w3, usdc_artifact, "Mock USDC", "USDC", key=provider_key_0x)
        usdc = w3.eth.contract(address=usdc_addr, abi=usdc_artifact["abi"])

        escrow_artifact = load_artifact("ZkInferenceEscrowV2")
        escrow_addr = deploy_contract(
            w3, escrow_artifact, "0x0000000000000000000000000000000000000000", key=provider_key_0x
        )
        escrow = w3.eth.contract(address=escrow_addr, abi=escrow_artifact["abi"])

        model_id = w3.keccak(text="MnistMLP/v1-k16")
        send_tx(w3, escrow, "registerModel", model_id,
                w3.to_checksum_address(vk_batch_addr), w3.to_checksum_address(vk_batch_addr),
                NUM_OUTPUTS, H_DUMMY, key=provider_key_0x)
        print(f"  usdc={usdc_addr} escrow={escrow_addr} vkBatch(=vkSolo)={vk_batch_addr}")

        send_tx(w3, usdc, "mint", client_acct.address, K * DEPOSIT + AMOUNT * 100, key=provider_key_0x)

        usdc_domain_sep = bytes(usdc.functions.DOMAIN_SEPARATOR().call())
        escrow_domain_sep = bytes(escrow.functions.DOMAIN_SEPARATOR().call())
        valid_before = w3.eth.get_block("latest")["timestamp"] + 7200

        print(f"\nOpening {K} channels...")
        channel_ids = []
        for i in range(K):
            salt = (5000 + i).to_bytes(32, 'big')
            open_params = (client_acct.address, provider_acct.address, usdc.address, model_id,
                           DEPOSIT, salt, PROVE_WIN_SEC)
            channel_id = escrow.functions.channelIdOf(open_params).call()
            channel_ids.append(channel_id)
            nonce_bytes = bytes(channel_id)
            v, r, s = sign_erc3009(w3, CLIENT_KEY, usdc_domain_sep, client_acct.address,
                                    escrow.address, DEPOSIT, valid_before, nonce_bytes)
            send_tx(w3, escrow, "openChannel", open_params, valid_before, v, r, s, key=CLIENT_KEY)
        print(f"  {K} channels opened")

        def build_frames(seq):
            prove_by = w3.eth.get_block("latest")["timestamp"] + 3600
            frames = []
            for i in range(K):
                commitment = lane_commitments[i]
                cum_amount = seq * AMOUNT
                v, r, s = sign_voucher_v2(w3, CLIENT_KEY, escrow_domain_sep, bytes(channel_ids[i]),
                                           seq, bytes(model_id), commitment, AMOUNT, cum_amount, prove_by)
                frames.append((channel_ids[i], seq, commitment, AMOUNT, cum_amount, prove_by, v, r, s))
            return frames

        def record(scenario, receipt, extra=None):
            entry = {"scenario": scenario, "tx_hash": receipt.transactionHash.hex(),
                      "gasUsed_script": receipt.gasUsed, "status": receipt.status}
            if extra:
                entry.update(extra)
            results["transactions"].append(entry)
            print(f"  [{scenario}] gasUsed={receipt.gasUsed:,} tx={entry['tx_hash']}")
            return entry

        print("\n── COLD settle (seq=1, real K=16 verifier + real proof) ──")
        frames1 = build_frames(seq=1)
        r1 = send_tx(w3, escrow, "settleChannelBatch", model_id, frames1, proof_bytes, instances,
                     key=provider_key_0x, gas_override=15_000_000)
        record("cold_seq1", r1)

        print("\n── STEADY settle (seq=2, same channels, same real proof) ──")
        frames2 = build_frames(seq=2)
        r2 = send_tx(w3, escrow, "settleChannelBatch", model_id, frames2, proof_bytes, instances,
                     key=provider_key_0x, gas_override=15_000_000)
        record("steady_seq2", r2)

        print("\n── STEADY sanity (seq=3) ──")
        frames3 = build_frames(seq=3)
        r3 = send_tx(w3, escrow, "settleChannelBatch", model_id, frames3, proof_bytes, instances,
                     key=provider_key_0x, gas_override=15_000_000)
        record("steady_seq3_sanity", r3)

        results["derive"] = {
            "cold_gas": r1.gasUsed, "steady_gas": r2.gasUsed, "steady_sanity_gas": r3.gasUsed,
            "steady_per_request": r2.gasUsed / K,
            "cold_per_request": r1.gasUsed / K,
            "cold_minus_steady": r1.gasUsed - r2.gasUsed,
            "expected_diff_formula": K * 17100 + 17076,
        }

        print("\n── Cross-check via cast receipt ──")
        for entry in results["transactions"]:
            cast_gas = cast_receipt_gas_used(entry["tx_hash"])
            entry["gasUsed_cast"] = cast_gas
            entry["match"] = (cast_gas == entry["gasUsed_script"])
            print(f"  {entry['scenario']}: script={entry['gasUsed_script']:,} cast={cast_gas:,} match={entry['match']}")

        with open(RESULTS_PATH, "w") as f:
            json.dump(results, f, indent=2, default=str)
        print(f"\nResults written to {RESULTS_PATH}")
        print(json.dumps(results["derive"], indent=2))

    finally:
        print("\nStopping Anvil...")
        anvil.terminate()
        anvil.wait()


if __name__ == "__main__":
    main()
