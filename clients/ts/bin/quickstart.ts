/**
 * Quickstart (run it through ../../../quickstart.sh):
 *
 *   published   (default) Create a throwaway testnet key, wait until it is funded from faucets, then pay
 *               this repository's Base Sepolia deployment for the one published input with the
 *               published solo proof, in one transaction. No proving on this machine.
 *   live <url> <input.json>
 *               Buy one inference of your own input from a running prover (an x402 server built
 *               with clients/python). Draws fresh nonces for the input commitment after the server
 *               has named its verifier; needs the optional @ezkljs/engine package for the commitment.
 */
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, createWalletClient, formatEther, formatUnits, http, keccak256, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { ABI, USDC, baseSepolia, decodeOutput, loadDeployment, pay, settleWithProof } from "../src/index.js";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const RPC = process.env.RPC_URL ?? "https://sepolia.base.org";
const KEY_FILE = process.env.QUICKSTART_KEY ?? join(ROOT, ".quickstart", "key");
const MIN_ETH = 100_000_000_000_000n; // 0.0001 ETH; one settlement uses about 770,000 gas
const WAIT_LIMIT_S = Number(process.env.QUICKSTART_WAIT ?? 3600);
const t0 = Date.now();
const seconds = (ms: number) => (ms / 1000).toFixed(1);

const pub = createPublicClient({ chain: baseSepolia, transport: http(RPC) });

function throwawayAccount() {
  if (!existsSync(KEY_FILE)) {
    mkdirSync(dirname(KEY_FILE), { recursive: true });
    writeFileSync(KEY_FILE, generatePrivateKey() + "\n", { mode: 0o600 });
    console.log(`Created a throwaway testnet key in ${KEY_FILE}. Use it for nothing else.`);
  }
  chmodSync(KEY_FILE, 0o600);
  return privateKeyToAccount(readFileSync(KEY_FILE, "utf8").trim() as Hex);
}

async function waitForFunds(address: Hex, usdcNeeded: bigint) {
  const start = Date.now();
  let shown = 0;
  for (;;) {
    const [eth, usdc] = await Promise.all([
      pub.getBalance({ address }),
      pub.readContract({ address: USDC, abi: ABI.token, functionName: "balanceOf", args: [address] }),
    ]);
    if (eth >= MIN_ETH && usdc >= usdcNeeded) return Date.now() - start;
    if (Date.now() - shown > 60_000) {
      shown = Date.now();
      console.log(`  waiting for funds: ${formatEther(eth)} ETH (need ${formatEther(MIN_ETH)}), ${formatUnits(usdc, 6)} USDC (need ${formatUnits(usdcNeeded, 6)})`);
    }
    if (Date.now() - start > WAIT_LIMIT_S * 1000) throw new Error(`not funded after ${WAIT_LIMIT_S} s; run the same command again once it is`);
    await new Promise(r => setTimeout(r, 10_000));
  }
}

function showOutput(output: Hex, scale: number) {
  const logits = decodeOutput(output, scale);
  const best = logits.indexOf(Math.max(...logits));
  console.log(`  output (10 logits, fixed point 2^-${scale}): ${logits.map(v => v.toFixed(3)).join(" ")}`);
  console.log(`  the model's answer: digit ${best}`);
}

async function main() {
  const [mode = "published", url, inputFile] = process.argv.slice(2);
  const d = loadDeployment(ROOT);
  const q = JSON.parse(readFileSync(join(ROOT, "deployments", "base-sepolia-quickstart.json"), "utf8"));
  const price = BigInt(q.price);
  const account = throwawayAccount();
  console.log(`Payer (throwaway, Base Sepolia only): ${account.address}`);
  console.log(`Fund it with at least ${formatUnits(price, 6)} USDC and ${formatEther(MIN_ETH)} ETH:`);
  console.log("  USDC: https://faucet.circle.com (choose Base Sepolia)");
  console.log("  ETH:  any Base Sepolia faucet listed at https://docs.base.org/chain/network-faucets");
  const waited = await waitForFunds(account.address, price);
  console.log(`Funded (waited ${seconds(waited)} s).`);
  const wallet = createWalletClient({ account, chain: baseSepolia, transport: http(RPC) });

  if (mode === "published") {
    const p = JSON.parse(readFileSync(join(ROOT, "clients", "ts", "published", "solo-proof.json"), "utf8"));
    const manifest = readFileSync(join(ROOT, "circuits", "spike-mlp", "MANIFEST.md"), "utf8");
    if (!manifest.includes(keccak256(p.proof as Hex))) throw new Error("the published proof is not the one MANIFEST.md pins");
    console.log(`Paying ${formatUnits(price, 6)} USDC to ${q.payee} through SoloSettlement ${d.contracts.SoloSettlement},`);
    console.log(`released only by a valid proof from verifier ${d.verifierIds.solo} for input commitment ${p.inputCommitment}.`);
    const r = await settleWithProof({
      pub, wallet, signer: account, deployment: d, verifierId: d.verifierIds.solo,
      inputCommitment: p.inputCommitment, output: p.output, proof: p.proof, payTo: q.payee, amount: price,
    });
    console.log(`Outcome: ${r.outcome}${r.reason ? ` (${r.reason})` : ""}`);
    if (r.transaction) console.log(`  settlement transaction: ${r.transaction} (block ${r.block}, ${r.gasUsed} gas)\n  https://sepolia.basescan.org/tx/${r.transaction}`);
    if (r.output) showOutput(r.output, p.outputScale);
    report(waited);
    process.exit(r.outcome === "settled" ? 0 : 1);
  }

  if (mode === "live") {
    if (!url || !inputFile) throw new Error("usage: quickstart.sh live <prover url> <input.json>");
    const x: number[] = JSON.parse(readFileSync(inputFile, "utf8")).input_data[0].slice(0, 784);
    const { commitment } = await import("../src/commitment.js");
    const r = await pay(url, {
      body: { input: x },
      commit: async () => {
        const nonces = Array.from(crypto.getRandomValues(new Uint32Array(5)), v => v / 2 ** 31 - 1); // in [-1, 1)
        return { commitment: await commitment([...x, ...nonces]), body: { input: x, nonces } };
      },
    }, { signer: account, pub, deployment: d, verifierIds: [d.verifierIds.solo], maxAmount: price });
    console.log(`Outcome: ${r.outcome}${r.reason ? ` (${r.reason})` : ""}${r.choice ? `, paid with ${r.choice}` : ""}`);
    if (r.transaction) console.log(`  transaction: ${r.transaction}\n  https://sepolia.basescan.org/tx/${r.transaction}`);
    if (r.output) showOutput(r.output, 13);
    report(waited);
    process.exit(r.outcome === "settled" ? 0 : 1);
  }
  throw new Error(`unknown mode ${mode}`);
}

function report(waited: number) {
  const total = Date.now() - t0;
  console.log(`Time: ${seconds(total)} s in this program, of which ${seconds(waited)} s waiting for funds, ${seconds(total - waited)} s the rest.`);
}

main().catch(e => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
