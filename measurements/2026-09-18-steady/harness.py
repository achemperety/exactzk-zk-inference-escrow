#!/usr/bin/env python3
"""Shared helpers for the steady-state gas measurement (2026-09-18).
Adapted from an earlier measurement script — fixes that script's stale-proof bug
by sourcing proof/instances/verifier bytecode exclusively from FixturesK8.sol
(see fixtures_k8.py), never from circuits/spike-mlp/run_mnist_mw_k8/proof.json.
"""
import json
import os
import subprocess
import time

PROJECT_ROOT  = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CONTRACTS_DIR = os.path.join(PROJECT_ROOT, "contracts")
CONTRACTS_OUT = os.path.join(PROJECT_ROOT, "contracts", "out")
FOUNDRY_BIN   = os.path.expanduser("~/.foundry/bin")

RPC_URL = "http://127.0.0.1:19545"

PROVIDER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
CLIENT_KEY   = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

MODEL_ID_STR  = "MnistMLP/v2-steady"
NUM_OUTPUTS   = 10
H_DUMMY       = 0
AMOUNT        = 1_000_000
DEPOSIT       = 50_000_000
PROVE_WIN_SEC = 10


def load_artifact(name: str, path_hint: str = None) -> dict:
    if path_hint:
        path = os.path.join(CONTRACTS_OUT, path_hint)
    else:
        path = os.path.join(CONTRACTS_OUT, f"{name}.sol", f"{name}.json")
    with open(path) as f:
        return json.load(f)


def start_anvil(port: int = 19545):
    proc = subprocess.Popen(
        [os.path.join(FOUNDRY_BIN, "anvil"), "--port", str(port), "--block-time", "1", "--silent"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    deadline = time.time() + 20
    from web3 import Web3
    while time.time() < deadline:
        try:
            w3 = Web3(Web3.HTTPProvider(f"http://127.0.0.1:{port}"))
            if w3.is_connected():
                return proc
        except Exception:
            pass
        time.sleep(0.3)
    proc.terminate()
    raise RuntimeError("Anvil did not start")


def deploy_contract(w3, artifact, *ctor_args, key: str) -> str:
    from eth_account import Account as EthAccount
    acct = EthAccount.from_key(key)
    contract = w3.eth.contract(abi=artifact["abi"], bytecode=artifact["bytecode"]["object"])
    tx = contract.constructor(*ctor_args).build_transaction({
        "from": acct.address,
        "nonce": w3.eth.get_transaction_count(acct.address),
    })
    tx["gas"] = int(w3.eth.estimate_gas(tx) * 1.3)
    signed = EthAccount.sign_transaction(tx, key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    assert receipt.status == 1, "deploy reverted"
    return receipt.contractAddress


def send_tx(w3, contract, fn_name: str, *args, key: str, gas_override=None):
    from eth_account import Account as EthAccount
    acct = EthAccount.from_key(key)
    fn = getattr(contract.functions, fn_name)
    tx = fn(*args).build_transaction({
        "from": acct.address,
        "nonce": w3.eth.get_transaction_count(acct.address),
    })
    tx["gas"] = gas_override if gas_override else int(w3.eth.estimate_gas(tx) * 1.3)
    signed = EthAccount.sign_transaction(tx, key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    assert receipt.status == 1, f"{fn_name} reverted (tx {tx_hash.hex()})"
    return receipt


def etch_code(w3, address: str, bytecode_hex: str):
    checksum = w3.to_checksum_address(address)
    w3.provider.make_request("anvil_setCode", [checksum, "0x" + bytecode_hex])


def erc3009_typehash():
    from web3 import Web3
    return Web3.keccak(text=(
        "ReceiveWithAuthorization(address from,address to,uint256 value,"
        "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    ))


def voucher_v2_typehash():
    from web3 import Web3
    return Web3.keccak(text=(
        "VoucherV2(bytes32 channelId,uint64 seq,bytes32 modelId,"
        "uint256 inputCommitment,uint256 amount,uint256 cumAmount,uint64 proveBy)"
    ))


def sign_erc3009(w3, key, domain_sep, from_addr, to_addr, value, valid_before, nonce):
    from eth_abi import encode as abi_encode
    from eth_account import Account as EthAccount
    from eth_account.messages import SignableMessage
    th = erc3009_typehash()
    struct_hash = w3.keccak(abi_encode(
        ['bytes32', 'address', 'address', 'uint256', 'uint256', 'uint256', 'bytes32'],
        [th, from_addr, to_addr, value, 0, valid_before, nonce],
    ))
    signed = EthAccount.from_key(key).sign_message(
        SignableMessage(version=b'\x01', header=domain_sep, body=bytes(struct_hash))
    )
    return signed.v, signed.r.to_bytes(32, 'big'), signed.s.to_bytes(32, 'big')


def sign_voucher_v2(w3, key, domain_sep, channel_id, seq, model_id, input_commitment,
                     amount, cum_amount, prove_by):
    from eth_abi import encode as abi_encode
    from eth_account import Account as EthAccount
    from eth_account.messages import SignableMessage
    th = voucher_v2_typehash()
    struct_hash = w3.keccak(abi_encode(
        ['bytes32', 'bytes32', 'uint64', 'bytes32', 'uint256', 'uint256', 'uint256', 'uint64'],
        [th, channel_id, seq, model_id, input_commitment, amount, cum_amount, prove_by],
    ))
    signed = EthAccount.from_key(key).sign_message(
        SignableMessage(version=b'\x01', header=domain_sep, body=bytes(struct_hash))
    )
    return signed.v, signed.r.to_bytes(32, 'big'), signed.s.to_bytes(32, 'big')


def deploy_stack(w3, model_id_str, batch_verifier_bytecode_hex=None, batch_verifier_artifact=None,
                  batch_verifier_ctor_args=(), num_outputs=NUM_OUTPUTS, h_dummy=H_DUMMY):
    """Deploy MockERC3009 + ZkInferenceEscrowV2, register a model with the given
    batch verifier (either etched bytecode at a fixed scratch address, or a real
    deployed contract from an artifact). Returns dict of addrs/contracts."""
    from eth_account import Account as EthAccount

    provider_acct = EthAccount.from_key(PROVIDER_KEY)
    client_acct   = EthAccount.from_key(CLIENT_KEY)

    usdc_artifact = load_artifact("MockERC3009")
    usdc_addr = deploy_contract(w3, usdc_artifact, "Mock USDC", "USDC", key=PROVIDER_KEY)
    usdc = w3.eth.contract(address=usdc_addr, abi=usdc_artifact["abi"])

    escrow_artifact = load_artifact("ZkInferenceEscrowV2")
    escrow_addr = deploy_contract(
        w3, escrow_artifact, "0x0000000000000000000000000000000000000000", key=PROVIDER_KEY
    )
    escrow = w3.eth.contract(address=escrow_addr, abi=escrow_artifact["abi"])

    if batch_verifier_artifact is not None:
        vk_batch_addr = deploy_contract(w3, batch_verifier_artifact, *batch_verifier_ctor_args, key=PROVIDER_KEY)
    else:
        # etch at a scratch address derived from the model id string so parallel
        # deployments in the same anvil session don't collide
        scratch_seed = abs(hash(model_id_str)) % (2**32)
        vk_batch_addr = "0x" + format(0xB00000000000000000000000 + scratch_seed, "040x")
        etch_code(w3, vk_batch_addr, batch_verifier_bytecode_hex)

    vk_solo_addr = vk_batch_addr  # never called by settleChannelBatch; any nonzero addr is fine

    model_id = w3.keccak(text=model_id_str)
    send_tx(
        w3, escrow, "registerModel",
        model_id, w3.to_checksum_address(vk_solo_addr), w3.to_checksum_address(vk_batch_addr),
        num_outputs, h_dummy, key=PROVIDER_KEY,
    )

    return {
        "usdc": usdc, "usdc_addr": usdc_addr,
        "escrow": escrow, "escrow_addr": escrow_addr,
        "vk_batch_addr": vk_batch_addr,
        "model_id": model_id,
        "provider_acct": provider_acct, "client_acct": client_acct,
    }


def open_8_channels(w3, stack, salt_base: int, deposit=DEPOSIT):
    usdc = stack["usdc"]; escrow = stack["escrow"]
    provider_acct = stack["provider_acct"]; client_acct = stack["client_acct"]
    model_id = stack["model_id"]

    send_tx(w3, usdc, "mint", client_acct.address, 8 * deposit + AMOUNT * 100, key=PROVIDER_KEY)

    usdc_domain_sep   = bytes(usdc.functions.DOMAIN_SEPARATOR().call())
    escrow_domain_sep = bytes(escrow.functions.DOMAIN_SEPARATOR().call())
    valid_before = w3.eth.get_block("latest")["timestamp"] + 7200

    channel_ids = []
    open_receipts = []
    for i in range(8):
        salt = (salt_base + i).to_bytes(32, 'big')
        open_params = (
            client_acct.address, provider_acct.address, usdc.address, model_id,
            deposit, salt, PROVE_WIN_SEC,
        )
        channel_id = escrow.functions.channelIdOf(open_params).call()
        channel_ids.append(channel_id)
        nonce_bytes = bytes(channel_id)
        v, r, s = sign_erc3009(
            w3, CLIENT_KEY, usdc_domain_sep, client_acct.address, escrow.address,
            deposit, valid_before, nonce_bytes,
        )
        receipt = send_tx(w3, escrow, "openChannel", open_params, valid_before, v, r, s, key=CLIENT_KEY)
        open_receipts.append(receipt)

    return channel_ids, open_receipts, usdc_domain_sep, escrow_domain_sep


def build_frames(w3, stack, channel_ids, escrow_domain_sep, seq: int, lane_commitments,
                  prove_by=None):
    if prove_by is None:
        prove_by = w3.eth.get_block("latest")["timestamp"] + 3600
    model_id = stack["model_id"]
    frames = []
    for i in range(8):
        commitment = lane_commitments[i]
        cum_amount = seq * AMOUNT
        v, r, s = sign_voucher_v2(
            w3, CLIENT_KEY, escrow_domain_sep, bytes(channel_ids[i]), seq,
            bytes(model_id), commitment, AMOUNT, cum_amount, prove_by,
        )
        frames.append((channel_ids[i], seq, commitment, AMOUNT, cum_amount, prove_by, v, r, s))
    return frames


def cast_receipt_gas_used(tx_hash_hex: str, rpc_url: str = RPC_URL) -> int:
    out = subprocess.run(
        [os.path.join(FOUNDRY_BIN, "cast"), "receipt", tx_hash_hex, "gasUsed", "--rpc-url", rpc_url],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        raise RuntimeError(f"cast receipt failed: {out.stderr}")
    val = out.stdout.strip()
    return int(val, 16) if val.startswith("0x") else int(val)
