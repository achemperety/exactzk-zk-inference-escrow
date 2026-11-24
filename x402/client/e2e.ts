/**
 * End-to-end over HTTP against x402/server/server.py on a local node (x402/README.md):
 *
 *   proof-gated, paymentFlow "authorization"   paid with ProofGatedEvmScheme (this directory)
 *   proof-gated, paymentFlow "escrow"          the same scheme, open before the resource, release after
 *   auth-capture, operatorType "custom"        paid with x402's own AuthCaptureEvmScheme, unmodified
 *
 * plus, for each scheme, a server that presents a tampered proof and one that presents an entry that
 * is not the registered one: no payment moves, and the two failures arrive as distinct errorReason
 * values. The last scenario lets an auth-capture hold go uncaptured and reclaims it after the capture
 * deadline. Every PaymentRequired, PaymentPayload and SettleResponse is validated against x402's
 * definitions (x402Checks.ts). The x402 auth-capture payment that was captured is written to
 * x402/.state/stock-client-payment.json for test/AuthCaptureStockClient.t.sol.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { x402Client } from "@x402/core/client";
import { x402HTTPClient } from "@x402/core/http";
import type { PaymentRequirements, SettleResponse } from "@x402/core/types";
import { AuthCaptureEvmScheme } from "@x402/evm/auth-capture/client";
import { createPublicClient, http, parseAbi, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ProofGatedEvmScheme, termsAuthorizer } from "./proofGated";
import { checkPaymentPayload, checkPaymentRequired, checkSettleResponse, counts } from "./x402Checks";

// x402's packages are CommonJS (no "type" in their package.json), so this directory is too.
const STATE = join(__dirname, "..", ".state");
const SERVER = process.env.SERVER_URL ?? "http://127.0.0.1:8402/infer";
const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const d = JSON.parse(readFileSync(join(STATE, "deployment.json"), "utf8"));

// The local node's published default account 1: a public test key, worthless on any real network.
const payer = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const chain = { id: 84532, name: "local", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } } as const;
const pub = createPublicClient({ chain, transport: http(RPC) });
const erc20 = parseAbi(["function balanceOf(address) view returns (uint256)"]);
const balance = (a: Address) => pub.readContract({ address: d.token, abi: erc20, functionName: "balanceOf", args: [a] });

type Want = { scheme: string; flow: string; serve?: "tampered" | "wrong-entry" | "unbound-authorizer" };

function client(want: Want): x402HTTPClient {
  // x402Client prefers "authorization" offers whenever one is left; a policy (which runs before
  // that preference) narrows the offers to the one this scenario wants.
  const c = new x402Client()
    .register("eip155:84532", new ProofGatedEvmScheme(payer, d.inputCommitment as Hex))
    .register("eip155:84532", new AuthCaptureEvmScheme(payer))
    .registerPolicy((_v, accepts) =>
      accepts.filter(x => x.scheme === want.scheme && (x.extra as { paymentFlow?: string }).paymentFlow === want.flow),
    );
  // A proof-aware wrapper around the stock auth-capture client: before signing, check that the
  // receiverAuthorizer the server asks to bind is derived from the terms it advertises.
  c.onBeforePaymentCreation(async ({ selectedRequirements: r }) => {
    if (r.scheme !== "auth-capture") return;
    const x = r.extra as { receiverAuthorizer: string; verifierId: Hex; inputCommitment: Hex };
    if (x.inputCommitment.toLowerCase() !== (d.inputCommitment as string).toLowerCase()) return { abort: true, reason: "not my input" };
    if (x.receiverAuthorizer.toLowerCase() !== termsAuthorizer(x.verifierId, x.inputCommitment).toLowerCase()) {
      return { abort: true, reason: "receiverAuthorizer is not bound to the advertised terms" };
    }
  });
  return new x402HTTPClient(c);
}

async function pay(want: Want) {
  const h = client(want);
  const body = JSON.stringify({ inputCommitment: d.inputCommitment, ...(want.serve ? { serve: want.serve } : {}) });
  const first = await fetch(SERVER, { method: "POST", body, headers: { "Content-Type": "application/json" } });
  if (first.status !== 402) throw new Error(`expected 402, got ${first.status}`);
  const pr = checkPaymentRequired(h.getPaymentRequiredResponse(n => first.headers.get(n), await first.json()));
  const payload = checkPaymentPayload(await h.createPaymentPayload(pr));
  const second = await fetch(SERVER, {
    method: "POST",
    body,
    headers: { "Content-Type": "application/json", ...h.encodePaymentSignatureHeader(payload) },
  });
  const settle = checkSettleResponse(h.getPaymentSettleResponse(n => second.headers.get(n)));
  return { status: second.status, settle, payload, accepted: payload.accepted as PaymentRequirements, body: await second.json() };
}

function expect(cond: boolean, what: string) {
  if (!cond) throw new Error(`FAILED: ${what}`);
  console.log(`  ok  ${what}`);
}

async function scenario(name: string, f: () => Promise<void>) {
  console.log(name);
  await f();
}

async function main() {
  const payTo = d.payTo as Address;
  const reasons: Record<string, string> = {};

  for (const flow of ["authorization", "escrow"]) {
    await scenario(`proof-gated, ${flow}: paid against the real proof`, async () => {
      const [p0, r0] = [await balance(payer.address), await balance(payTo)];
      const r = await pay({ scheme: "proof-gated", flow });
      expect(r.status === 200 && r.settle.success, "200 with a successful PAYMENT-RESPONSE");
      expect(r.body.output === d.output, "the output is delivered");
      expect((await balance(payer.address)) === p0 - 1_000_000n && (await balance(payTo)) === r0 + 1_000_000n, "1 USDC moved from payer to payTo");
    });
    for (const serve of ["tampered", "wrong-entry"] as const) {
      await scenario(`proof-gated, ${flow}: the server presents a ${serve === "tampered" ? "tampered proof" : "wrong verifier entry"}`, async () => {
        const [p0, r0] = [await balance(payer.address), await balance(payTo)];
        const r = await pay({ scheme: "proof-gated", flow, serve });
        expect(r.status === 402 && !r.settle.success, "402 with a failing PAYMENT-RESPONSE");
        reasons[`proof-gated/${flow}/${serve}`] = r.settle.errorReason ?? "";
        console.log(`      errorReason ${r.settle.errorReason}`);
        expect(r.body.output === undefined, "no output delivered");
        const locked = flow === "escrow" ? 1_000_000n : 0n;
        expect((await balance(payer.address)) === p0 - locked && (await balance(payTo)) === r0, flow === "escrow" ? "the payment stays locked, payTo unpaid" : "no payment moved");
      });
    }
  }

  let stock: Awaited<ReturnType<typeof pay>> | undefined;
  await scenario("auth-capture (x402's own client), custom operator: held, then captured against the real proof", async () => {
    const [p0, r0] = [await balance(payer.address), await balance(payTo)];
    const r = await pay({ scheme: "auth-capture", flow: "escrow" });
    expect(r.status === 200 && r.settle.success, "200 with a successful PAYMENT-RESPONSE");
    expect(r.body.output === d.output, "the output is delivered");
    expect((await balance(payer.address)) === p0 - 1_000_000n && (await balance(payTo)) === r0 + 1_000_000n, "1 USDC moved from payer to payTo");
    stock = r;
  });
  writeFileSync(
    join(STATE, "stock-client-payment.json"),
    JSON.stringify({ accepted: stock!.accepted, payload: stock!.payload.payload, paymentInfo: (stock!.settle.extra as Record<string, unknown>).paymentInfo }, null, 2),
  );

  await scenario("auth-capture: a server that advertises a receiverAuthorizer not bound to its terms is not paid", async () => {
    const p0 = await balance(payer.address);
    let refused = "";
    try {
      await pay({ scheme: "auth-capture", flow: "escrow", serve: "unbound-authorizer" });
    } catch (e) {
      refused = String(e);
    }
    expect(refused.includes("receiverAuthorizer is not bound"), "the client refuses to sign");
    expect((await balance(payer.address)) === p0, "nothing moved");
  });

  await scenario("auth-capture: the server presents a wrong verifier entry", async () => {
    const r = await pay({ scheme: "auth-capture", flow: "escrow", serve: "wrong-entry" });
    expect(r.status === 402 && !r.settle.success, "402 with a failing PAYMENT-RESPONSE");
    reasons["auth-capture/wrong-entry"] = r.settle.errorReason ?? "";
    console.log(`      errorReason ${r.settle.errorReason}`);
  });

  await scenario("auth-capture: a tampered proof cannot capture; the payer reclaims after the deadline", async () => {
    const [p0, r0] = [await balance(payer.address), await balance(payTo)];
    const r = await pay({ scheme: "auth-capture", flow: "escrow", serve: "tampered" });
    expect(r.status === 402 && !r.settle.success, "402 with a failing PAYMENT-RESPONSE");
    reasons["auth-capture/tampered"] = r.settle.errorReason ?? "";
    console.log(`      errorReason ${r.settle.errorReason}`);
    expect((await balance(payer.address)) === p0 - 1_000_000n && (await balance(payTo)) === r0, "the payment is held, payTo unpaid");
    const extra = r.settle.extra as { paymentInfo: Record<string, string>; reclaimFrom: number };
    await reclaim(extra.paymentInfo, extra.reclaimFrom);
    expect((await balance(payer.address)) === p0, "after the capture deadline the payer has it all back");
  });

  console.log("\nerrorReason values seen:", JSON.stringify(reasons, null, 2));
  console.log("validated against x402's definitions:", JSON.stringify(counts));
  for (const [k, v] of Object.entries(reasons)) {
    const want = k.endsWith("tampered") ? "invalid_auth_capture_evm_proof_invalid" : "invalid_auth_capture_evm_verifier_unavailable";
    expect(v === want, `${k} -> ${want}`);
  }
}

/** Move the node's clock to the capture deadline and reclaim the hold as the payer. */
async function reclaim(info: Record<string, string>, from: number) {
  const rpc = (method: string, params: unknown[]) =>
    fetch(RPC, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) }).then(x => x.json());
  await rpc("evm_setNextBlockTimestamp", [from]);
  await rpc("evm_mine", []);
  const { createWalletClient } = await import("viem");
  const wallet = createWalletClient({ account: payer, chain, transport: http(RPC) });
  const abi = parseAbi([
    "struct PaymentInfo { address operator; address payer; address receiver; address token; uint120 maxAmount; uint48 preApprovalExpiry; uint48 authorizationExpiry; uint48 refundExpiry; uint16 minFeeBps; uint16 maxFeeBps; address feeReceiver; uint256 salt; }",
    "function reclaim(PaymentInfo paymentInfo)",
  ]);
  const p = {
    operator: info.operator as Address, payer: info.payer as Address, receiver: info.receiver as Address, token: info.token as Address,
    maxAmount: BigInt(info.maxAmount), preApprovalExpiry: Number(info.preApprovalExpiry), authorizationExpiry: Number(info.authorizationExpiry),
    refundExpiry: Number(info.refundExpiry), minFeeBps: Number(info.minFeeBps), maxFeeBps: Number(info.maxFeeBps),
    feeReceiver: info.feeReceiver as Address, salt: BigInt(info.salt),
  };
  const hash = await wallet.writeContract({ address: d.escrow, abi, functionName: "reclaim", args: [p] });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  expect(receipt.status === "success", `the payer reclaims the hold (${hash})`);
}

main().catch(e => {
  console.error(e);
  process.exit(1);
});
