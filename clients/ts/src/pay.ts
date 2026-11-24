/**
 * `pay(url, input)`: buy one proof-gated inference from an x402 version 2 server.
 *
 * Before it signs, the client checks the offer against what it knows, not what the server says:
 * the network, the token, the price ceiling, the settlement contract or escrow and operator of this
 * deployment, a verifier it accepts, and for x402's `auth-capture` scheme that `receiverAuthorizer`
 * is `termsAuthorizer(verifierId, inputCommitment)` for its own commitment (docs/spec-notes.md).
 * When the input commitment is drawn per request, the server names the verifier first and the client
 * draws its randomness after that, then refuses any later offer that names another verifier.
 * After a successful answer it reads the transaction from the chain and takes the output from the
 * contract's event, not from the server's body.
 */
import { decodeEventLog, getAddress, parseAbi, type Address, type Hex, type PublicClient } from "viem";
import { ABI, CHAIN_ID, COLLECTOR, ESCROW, NETWORK, USDC, ZERO, tokenDomain, type Deployment } from "./chain.js";
import { boundSalt, random32, requestId, signReceive, termsAuthorizer, type Flow, type Signer, type Terms } from "./terms.js";
import { HEADER, decodeHeader, encodeHeader, type PaymentPayload, type PaymentRequired, type PaymentRequirements, type SettleResponse } from "./x402.js";

/** What the server needs to run the model, and the commitment the proof will carry. */
export type Input =
  | { body: Record<string, unknown>; commitment: Hex }
  | { body: Record<string, unknown>; commit: (verifierId: Hex) => Promise<{ commitment: Hex; body: Record<string, unknown> }> };

export type Choice = "proof-gated/authorization" | "proof-gated/escrow" | "auth-capture";

export type PayOptions = {
  signer: Signer;
  pub: PublicClient;
  deployment: Deployment;
  verifierIds: Hex[];
  maxAmount: bigint;
  prefer?: Choice[];
  /** The token's ERC-712 name and version; read from the token when not given. */
  tokenDomain?: { name: string; version: string };
};

export type PayResult = {
  outcome: "settled" | "not settled" | "refused";
  reason?: string;
  transaction?: Hex;
  output?: Hex;
  choice?: Choice;
  settle?: SettleResponse;
};

const OPERATOR_EVENTS = parseAbi(["event CapturedWithProof(bytes32 indexed paymentInfoHash, bytes32 indexed claimDigest, uint256 amount, bytes output)"]);
const choiceOf = (r: PaymentRequirements): Choice =>
  r.scheme === "auth-capture" ? "auth-capture" : (`proof-gated/${String(r.extra.paymentFlow)}` as Choice);
const same = (a: unknown, b: string) => typeof a === "string" && a.toLowerCase() === b.toLowerCase();

/** Why this client will not sign `r` for `commitment`, or undefined if it will. */
export function refusal(r: PaymentRequirements, commitment: Hex | undefined, o: PayOptions, token: { name: string; version: string }): string | undefined {
  const x = r.extra;
  if (r.network !== NETWORK) return `network ${r.network}`;
  if (!same(r.asset, USDC)) return `asset ${r.asset} is not USDC`;
  if (BigInt(r.amount) > o.maxAmount) return `price ${r.amount} above ${o.maxAmount}`;
  if (!same(x.name, token.name) || !same(x.version, token.version)) return "token domain differs from the token's own";
  if (!o.verifierIds.some(v => same(x.verifierId, v))) return `verifier ${String(x.verifierId)} not accepted`;
  if (r.scheme === "proof-gated") {
    if (!same(x.settlement, o.deployment.contracts.SoloSettlement)) return `settlement ${String(x.settlement)} is not this deployment's`;
    if (x.paymentFlow !== "authorization" && x.paymentFlow !== "escrow") return `payment flow ${String(x.paymentFlow)}`;
    const w = Number(x.proveWindowSeconds);
    if (!(w > 0 && w <= 86_400)) return `prove window ${String(x.proveWindowSeconds)}`;
    return undefined;
  }
  if (r.scheme !== "auth-capture") return `scheme ${r.scheme}`;
  if (!same(x.authCaptureEscrow, ESCROW) || x.operatorType !== "custom") return "not x402's escrow with a custom operator";
  if (!same(x.captureAuthorizer, o.deployment.contracts.AuthCaptureProofOperator)) return "operator is not this deployment's";
  if (x.policy !== undefined && !same(x.policy, ZERO)) return "a policy is set";
  if (Number(x.maxFeeBps) !== 0) return "fees are not zero";
  if (commitment === undefined) return "no input commitment yet";
  if (!same(x.inputCommitment, commitment)) return "the offer names another input commitment";
  if (!same(x.receiverAuthorizer, termsAuthorizer(x.verifierId as Hex, commitment))) {
    return "receiverAuthorizer is not bound to the terms";
  }
  return undefined;
}

async function post(url: string, body: unknown, headers: Record<string, string> = {}) {
  const res = await fetch(url, { method: "POST", body: JSON.stringify(body), headers: { "Content-Type": "application/json", ...headers } });
  return { res, json: (await res.json().catch(() => ({}))) as Record<string, unknown> };
}

async function offers(url: string, body: Record<string, unknown>): Promise<PaymentRequired> {
  const { res } = await post(url, body);
  const h = res.headers.get(HEADER.required);
  if (res.status !== 402 || !h) throw new Error(`expected 402 with ${HEADER.required}, got ${res.status}`);
  const pr = decodeHeader<PaymentRequired>(h);
  if (pr.x402Version !== 2) throw new Error(`x402Version ${pr.x402Version}`);
  return pr;
}

export async function pay(url: string, input: Input, o: PayOptions): Promise<PayResult> {
  const prefer = o.prefer ?? ["proof-gated/authorization", "proof-gated/escrow", "auth-capture"];
  const token = o.tokenDomain ? { address: USDC, chainId: CHAIN_ID, ...o.tokenDomain } : await tokenDomain(o.pub, USDC);
  const pick = (pr: PaymentRequired, commitment: Hex | undefined): { r?: PaymentRequirements; c?: Choice; why: string[] } => {
    const why: string[] = [];
    for (const c of prefer) {
      const r = pr.accepts.find(a => choiceOf(a) === c);
      if (!r) continue;
      const no = refusal(r, commitment, o, token);
      if (!no) return { r, c, why };
      why.push(`${c}: ${no}`);
    }
    return { why };
  };

  let commitment = "commitment" in input ? input.commitment : undefined;
  let body = { ...input.body, ...(commitment ? { inputCommitment: commitment } : {}) };
  let pr = await offers(url, body);
  let chosen = pick(pr, commitment);
  // With a per-request commitment, the auth-capture offer can only be checked once the commitment exists.
  if ("commit" in input) {
    // Any offer that names an accepted verifier says which verifier the server proves with.
    const first = pr.accepts.find(a => o.verifierIds.some(v => same(a.extra.verifierId, v)));
    if (!first) return { outcome: "refused", reason: "no offer names an accepted verifier" };
    const verifierId = first.extra.verifierId as Hex;
    const fresh = await input.commit(verifierId); // randomness drawn after the server named the verifier
    commitment = fresh.commitment;
    body = { ...fresh.body, inputCommitment: commitment };
    pr = await offers(url, body);
    chosen = pick(pr, commitment);
    if (chosen.r && !same(chosen.r.extra.verifierId, verifierId)) return { outcome: "refused", reason: "the verifier changed after the commitment" };
  }
  if (!chosen.r || !chosen.c) return { outcome: "refused", reason: chosen.why.join("; ") || "no offer this client accepts" };
  const { r, c } = chosen as { r: PaymentRequirements; c: Choice };

  const now = Math.floor(Date.now() / 1000);
  const payer = o.signer.address;
  let payload: Record<string, unknown>;
  let expectId: Hex | undefined;
  if (r.scheme === "proof-gated") {
    const flow = r.extra.paymentFlow as Flow;
    const terms: Terms = {
      payer, payTo: getAddress(r.payTo), asset: USDC, amount: r.amount, verifierId: r.extra.verifierId as Hex,
      inputCommitment: commitment!, proveBy: now + Number(r.extra.proveWindowSeconds), salt: random32(),
    };
    expectId = requestId(CHAIN_ID, o.deployment.contracts.SoloSettlement, flow, terms);
    const authorization = { from: payer, to: o.deployment.contracts.SoloSettlement, value: r.amount, validAfter: "0", validBefore: String(now + r.maxTimeoutSeconds), nonce: expectId };
    payload = { terms, authorization, signature: await signReceive(o.signer, token, authorization) };
  } else {
    const x = r.extra;
    const saltNonce = random32();
    const salt = boundSalt(x.receiverAuthorizer as Address, ZERO, saltNonce);
    const info = {
      operator: getAddress(x.captureAuthorizer as string), payer, receiver: getAddress(r.payTo), token: USDC,
      maxAmount: BigInt(r.amount), preApprovalExpiry: now + r.maxTimeoutSeconds, authorizationExpiry: Number(x.captureDeadline),
      refundExpiry: Number(x.refundDeadline), minFeeBps: Number(x.minFeeBps), maxFeeBps: Number(x.maxFeeBps),
      feeReceiver: getAddress(x.feeRecipient as string), salt: BigInt(salt),
    };
    const nonce = await o.pub.readContract({ address: ESCROW, abi: ABI.escrow, functionName: "getHash", args: [{ ...info, payer: ZERO }] });
    const authorization = { from: payer, to: COLLECTOR, value: r.amount, validAfter: "0", validBefore: String(info.preApprovalExpiry), nonce };
    payload = { authorization, signature: await signReceive(o.signer, token, authorization), salt, saltNonce };
  }

  const pp: PaymentPayload = { x402Version: 2, resource: pr.resource, accepted: r, payload };
  const { res, json } = await post(url, body, { [HEADER.signature]: encodeHeader(pp) });
  const h = res.headers.get(HEADER.response);
  if (!h) return { outcome: "not settled", reason: `no ${HEADER.response} (HTTP ${res.status})`, choice: c };
  const settle = decodeHeader<SettleResponse>(h);
  if (!settle.success) return { outcome: "not settled", reason: settle.errorReason, choice: c, settle };

  // Trust the chain: the transaction must have succeeded and carry the output.
  const receipt = await o.pub.waitForTransactionReceipt({ hash: settle.transaction as Hex });
  if (receipt.status !== "success") return { outcome: "not settled", reason: "the reported transaction reverted", choice: c, settle };
  for (const log of receipt.logs) {
    try {
      if (r.scheme === "proof-gated" && same(log.address, o.deployment.contracts.SoloSettlement)) {
        const ev = decodeEventLog({ abi: ABI.settlement, data: log.data, topics: log.topics });
        if (ev.eventName === "Settled" && ev.args.requestId === expectId) {
          return { outcome: "settled", transaction: receipt.transactionHash, output: ev.args.output, choice: c, settle };
        }
      } else if (r.scheme === "auth-capture" && same(log.address, o.deployment.contracts.AuthCaptureProofOperator)) {
        const ev = decodeEventLog({ abi: OPERATOR_EVENTS, data: log.data, topics: log.topics });
        return { outcome: "settled", transaction: receipt.transactionHash, output: ev.args.output, choice: c, settle };
      }
    } catch {
      // another event of the same contract
    }
  }
  return { outcome: "not settled", reason: "the reported transaction settled nothing for this payment", choice: c, settle };
}
