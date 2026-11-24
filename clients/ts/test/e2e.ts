/**
 * The TypeScript client against the Python middleware on a local node (clients/e2e/run.sh). Every way
 * of paying succeeds with the real proof; a tampered proof and a wrong verifier entry fail with their
 * distinct errorReason values and move nothing to the payee; the client refuses an auth-capture offer
 * whose receiverAuthorizer is not bound to the terms, and an offer whose verifier changes once its
 * commitment is known.
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ABI, USDC, baseSepolia, pay, type Choice, type Deployment, type Input } from "../src/index.js";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const URL = process.env.SERVER_URL ?? "http://127.0.0.1:8402/infer";
const s = JSON.parse(readFileSync(join(ROOT, "x402", ".state", "deployment.json"), "utf8"));
const deployment = {
  chainId: 84532, commit: "local",
  contracts: { SoloSettlement: s.settlement, AuthCaptureProofOperator: s.operator, VerifierRegistry: s.registry },
  verifierIds: { solo: s.verifierId, k8: s.verifierId },
} as unknown as Deployment;
const OTHER: Hex = `0x${"ab".repeat(32)}`;
// The local node's published default account 1: a public test key, worthless on any real network.
const payer = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const pub = createPublicClient({ chain: baseSepolia, transport: http(RPC) });
const balance = (a: Address) => pub.readContract({ address: USDC, abi: ABI.token, functionName: "balanceOf", args: [a] });
// The test token has no name() or version(); its ERC-712 domain is USDC's.
const opts = (prefer: Choice[], verifierIds: Hex[] = [s.verifierId]) =>
  ({ signer: payer, pub, deployment, verifierIds, maxAmount: 1_000_000n, prefer, tokenDomain: { name: "USD Coin", version: "2" } });
const fixed = (serve?: string): Input => ({ body: serve ? { serve } : {}, commitment: s.inputCommitment });
const reasons: Record<string, string | undefined> = {};
let failed = 0;

function expect(ok: boolean, what: string) {
  console.log(`  ${ok ? "ok  " : "FAIL"} ${what}`);
  if (!ok) failed++;
}

async function main() {
  for (const c of ["proof-gated/authorization", "proof-gated/escrow", "auth-capture"] as Choice[]) {
    console.log(`${c}: the real proof`);
    let [p0, r0] = [await balance(payer.address), await balance(s.payTo)];
    const r = await pay(URL, fixed(), opts([c]));
    expect(r.outcome === "settled" && r.choice === c, `settled with ${c} (${r.reason ?? r.transaction})`);
    expect(r.output === s.output, "the output read from the contract's event is the proof's");
    expect((await balance(payer.address)) === p0 - 1_000_000n && (await balance(s.payTo)) === r0 + 1_000_000n, "1 USDC from payer to payee");
    for (const serve of ["tampered", "wrong-entry"]) {
      console.log(`${c}: the server presents a ${serve === "tampered" ? "tampered proof" : "wrong verifier entry"}`);
      [p0, r0] = [await balance(payer.address), await balance(s.payTo)];
      const f = await pay(URL, fixed(serve), opts([c]));
      reasons[`${c}/${serve}`] = f.reason;
      expect(f.outcome === "not settled", `not settled: ${f.reason}`);
      const held = c === "proof-gated/authorization" ? 0n : 1_000_000n;
      expect((await balance(s.payTo)) === r0 && (await balance(payer.address)) === p0 - held, held ? "payee unpaid; the payment stays locked or held for the payer" : "nothing moved");
    }
  }

  console.log("auth-capture: an offer whose receiverAuthorizer is not bound to the terms");
  let p0 = await balance(payer.address);
  const u = await pay(URL, fixed("unbound-authorizer"), opts(["auth-capture"]));
  expect(u.outcome === "refused" && (u.reason ?? "").includes("receiverAuthorizer is not bound"), `refused: ${u.reason}`);
  expect((await balance(payer.address)) === p0, "nothing signed, nothing moved");

  console.log("proof-gated/authorization: the server's answer claims another output than the chain recorded");
  const lie = await pay(URL, fixed("lie-output"), opts(["proof-gated/authorization"]));
  expect(lie.outcome === "settled" && lie.output === s.output, "the client reports the output from the contract's event");

  console.log("proof-gated/authorization: the prover returns a proof about another input");
  p0 = await balance(payer.address);
  const other = await pay(URL, fixed("other-commitment"), opts(["proof-gated/authorization"]));
  reasons["proof-gated/authorization/other-commitment"] = other.reason;
  expect(other.outcome === "not settled" && other.reason === "invalid_proof_gated_evm_prover_commitment_mismatch", `not settled: ${other.reason}`);
  expect((await balance(payer.address)) === p0, "nothing moved");

  console.log("auth-capture: a commitment drawn after the server named its verifier");
  let asked: Hex | undefined;
  const fresh = (serve?: string): Input => ({
    body: serve ? { serve } : {},
    commit: async (verifierId: Hex) => {
      asked = verifierId; // a live client draws its nonces here; the published input has none
      return { commitment: s.inputCommitment, body: serve ? { serve } : {} };
    },
  });
  const f = await pay(URL, fresh(), opts(["auth-capture"]));
  expect(asked === s.verifierId, "the client knew the verifier before it committed");
  expect(f.outcome === "settled", `settled: ${f.reason ?? f.transaction}`);

  console.log("auth-capture: the verifier changes once the commitment is known");
  p0 = await balance(payer.address);
  const w = await pay(URL, fresh("switch-verifier"), opts(["auth-capture"], [s.verifierId, OTHER]));
  expect(w.outcome === "refused" && w.reason === "the verifier changed after the commitment", `refused: ${w.reason}`);
  expect((await balance(payer.address)) === p0, "nothing moved");

  console.log("errorReason values:", JSON.stringify(reasons, null, 2));
  for (const [k, v] of Object.entries(reasons)) {
    if (k.endsWith("other-commitment")) continue;
    const want = k.endsWith("tampered") ? "invalid_proof_gated_evm_invalid_proof" : "invalid_proof_gated_evm_verifier_unavailable";
    expect(v === want, `${k} -> ${want}`);
  }
  if (failed) throw new Error(`${failed} check(s) failed`);
  console.log("all checks passed");
}

main().catch(e => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
