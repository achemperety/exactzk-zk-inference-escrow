/**
 * Testnet measurements from real transactions, sent from the quickstart's funded throwaway key
 * (measurements/2026-11-24-testnet/README.md):
 *
 *   escrow   SoloSettlement.open, then release against the published solo proof
 *   batch    ChannelSettlement.openChannel, then two settleBatch calls with the stored K=8 proof:
 *            one channel, its vouchers 1-8 (the provider's first accrual), then 9-16 (steady)
 *
 * The one-transaction `settle` is the quickstart itself. Each transaction is printed with its hash,
 * block and gas used; the figures are read back from the receipts.
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, createWalletClient, encodePacked, http, parseAbi, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ABI, CHAIN_ID, USDC, baseSepolia, checkedEntry, loadDeployment, random32, requestId, signReceive, termsArg, tokenDomain, type Terms } from "../src/index.js";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const RPC = process.env.RPC_URL ?? "https://sepolia.base.org";
const key = readFileSync(process.env.QUICKSTART_KEY ?? join(ROOT, ".quickstart", "key"), "utf8").trim() as Hex;
const account = privateKeyToAccount(key);
const pub = createPublicClient({ chain: baseSepolia, transport: http(RPC) });
const wallet = createWalletClient({ account, chain: baseSepolia, transport: http(RPC) });
const d = loadDeployment(ROOT);
const q = JSON.parse(readFileSync(join(ROOT, "deployments", "base-sepolia-quickstart.json"), "utf8"));
const published = (name: string) => JSON.parse(readFileSync(join(ROOT, "clients", "ts", "published", name), "utf8"));

const CONFIG = "(address payer, address payTo, address asset, bytes32 verifierSetHash, uint40 proveWindow, uint40 challengeWindow, bytes32 salt)";
const ENTRY = "(address adapter, uint32 lanes, uint32 outputSize, uint32 verifyGas, address target, bytes32 adapterCodeHash, bytes32 targetCodeHash, bytes32 vkHash, bytes32 emptyLane)";
const CHANNEL = parseAbi([
  `function channelId(${CONFIG} c) view returns (bytes32)`,
  `function openChannel(${CONFIG} c, uint256 deposit, uint256 validBefore, bytes paymentSig) returns (bytes32)`,
  `function settleBatch(${ENTRY} e, bytes32[] verifierSet, uint256 setIndex, ${CONFIG}[] channels, bytes frames, bytes32[] commitments, bytes outputs, bytes proof)`,
]);

async function send(label: string, request: Parameters<typeof wallet.writeContract>[0]) {
  const hash = await wallet.writeContract(request);
  const r = await pub.waitForTransactionReceipt({ hash });
  console.log(JSON.stringify({ label, hash, block: Number(r.blockNumber), gasUsed: Number(r.gasUsed), status: r.status }));
  if (r.status !== "success") throw new Error(`${label} reverted`);
}

async function escrow() {
  const p = published("solo-proof.json");
  const settlement = d.contracts.SoloSettlement;
  const entry = await checkedEntry(pub, d, d.verifierIds.solo);
  const now = Math.floor(Date.now() / 1000);
  const t: Terms = {
    payer: account.address, payTo: q.payee, asset: USDC, amount: q.price, verifierId: d.verifierIds.solo,
    inputCommitment: p.inputCommitment, proveBy: now + 600, salt: random32(),
  };
  const id = requestId(CHAIN_ID, settlement, "escrow", t);
  const validBefore = BigInt(now + 600);
  const sig = await signReceive(account, await tokenDomain(pub, USDC), {
    from: t.payer, to: settlement, value: t.amount, validAfter: "0", validBefore: validBefore.toString(), nonce: id,
  });
  const args = { address: settlement, abi: ABI.settlement, account, chain: baseSepolia } as const;
  await send("SoloSettlement.open", { ...args, functionName: "open", args: [termsArg(t), validBefore, sig] });
  await send("SoloSettlement.release", { ...args, functionName: "release", args: [termsArg(t), entry, p.output, p.proof] });
}

async function batch() {
  const p = published("k8-proof.json");
  const channel = d.contracts.ChannelSettlement;
  const entry = await checkedEntry(pub, d, d.verifierIds.k8);
  const amount = 1000n; // 0.001 USDC per voucher
  const config = {
    payer: account.address, payTo: q.payee, asset: USDC,
    verifierSetHash: (await import("viem")).keccak256(encodePacked(["bytes32"], [d.verifierIds.k8])),
    proveWindow: 600, challengeWindow: 86_400, salt: random32(),
  };
  const id = await pub.readContract({ address: channel, abi: CHANNEL, functionName: "channelId", args: [config] });
  const now = Math.floor(Date.now() / 1000);
  const deposit = 16n * amount;
  const validBefore = BigInt(now + 600);
  const sig = await signReceive(account, await tokenDomain(pub, USDC), {
    from: account.address, to: channel, value: deposit.toString(), validAfter: "0", validBefore: validBefore.toString(), nonce: id,
  });
  const args = { address: channel, abi: CHANNEL, account, chain: baseSepolia } as const;
  await send("ChannelSettlement.openChannel", { ...args, functionName: "openChannel", args: [config, deposit, validBefore, sig] });

  for (const [label, first] of [["ChannelSettlement.settleBatch, vouchers 1-8, provider's first accrual", 1], ["ChannelSettlement.settleBatch, vouchers 9-16, steady", 9]] as const) {
    const proveBy = Math.floor(Date.now() / 1000) + 300;
    let frames: Hex = "0x";
    for (let lane = 0; lane < 8; lane++) {
      const seq = first + lane;
      const voucher = await account.signTypedData({
        domain: { name: "ChannelSettlement", version: "1", chainId: CHAIN_ID, verifyingContract: channel },
        types: {
          Voucher: [
            { name: "channelId", type: "bytes32" }, { name: "seq", type: "uint48" }, { name: "amount", type: "uint96" },
            { name: "cumAmount", type: "uint96" }, { name: "inputCommitment", type: "bytes32" }, { name: "proveBy", type: "uint40" },
          ],
        },
        primaryType: "Voucher",
        message: { channelId: id, seq, amount, cumAmount: BigInt(seq) * amount, inputCommitment: p.commitments[lane], proveBy },
      });
      frames = `${frames}${encodePacked(["uint16", "uint48", "uint96", "uint40", "uint16", "bytes"], [0, seq, amount, proveBy, 65, voucher]).slice(2)}` as Hex;
    }
    await send(label, { ...args, functionName: "settleBatch", args: [entry, [d.verifierIds.k8], 0n, [config], frames, p.commitments, p.outputs, p.proof] });
  }
}

const what = process.argv[2];
(what === "escrow" ? escrow() : what === "batch" ? batch() : Promise.reject(new Error("usage: measure.ts escrow|batch"))).catch(e => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
