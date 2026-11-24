/**
 * The client's checks before it signs (`refusal`), one test per check. No chain is needed.
 *
 *   node --import tsx --test test/refusal.test.ts
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import type { Hex, PublicClient } from "viem";
import { ESCROW, USDC, ZERO, refusal, termsAuthorizer, type Deployment, type PaymentRequirements, type PayOptions } from "../src/index.js";

const addr = (byte: string) => `0x${byte.repeat(20)}` as const;
const SETTLEMENT = addr("11");
const OPERATOR = addr("22");
const VERIFIER: Hex = `0x${"0c".repeat(32)}`;
const COMMITMENT: Hex = `0x${"0d".repeat(32)}`;
const token = { name: "USDC", version: "2" };
const o = {
  signer: undefined as never,
  pub: undefined as unknown as PublicClient,
  deployment: { contracts: { SoloSettlement: SETTLEMENT, AuthCaptureProofOperator: OPERATOR } } as unknown as Deployment,
  verifierIds: [VERIFIER],
  maxAmount: 10_000n,
} satisfies PayOptions;

const base = { network: "eip155:84532" as const, asset: USDC, amount: "10000", payTo: addr("33"), maxTimeoutSeconds: 600 };
const proofGated = (extra: Record<string, unknown> = {}): PaymentRequirements => ({
  scheme: "proof-gated", ...base,
  extra: { ...token, paymentFlow: "authorization", settlement: SETTLEMENT, verifierId: VERIFIER, proveWindowSeconds: 600, ...extra },
});
const authCapture = (extra: Record<string, unknown> = {}): PaymentRequirements => ({
  scheme: "auth-capture", ...base,
  extra: {
    ...token, authCaptureEscrow: ESCROW, captureAuthorizer: OPERATOR, operatorType: "custom", policy: ZERO, maxFeeBps: 0,
    verifierId: VERIFIER, inputCommitment: COMMITMENT, receiverAuthorizer: termsAuthorizer(VERIFIER, COMMITMENT), ...extra,
  },
});

test("signs a proof-gated offer for this deployment", () => assert.equal(refusal(proofGated(), COMMITMENT, o, token), undefined));
test("signs a bound auth-capture offer", () => assert.equal(refusal(authCapture(), COMMITMENT, o, token), undefined));
test("refuses another network", () => assert.match(refusal({ ...proofGated(), network: "eip155:8453" }, COMMITMENT, o, token)!, /network/));
test("refuses another asset", () => assert.match(refusal({ ...proofGated(), asset: SETTLEMENT }, COMMITMENT, o, token)!, /not USDC/));
test("refuses a price above its ceiling", () => assert.match(refusal({ ...proofGated(), amount: "10001" }, COMMITMENT, o, token)!, /price/));
test("refuses a token domain that is not the token's", () =>
  assert.match(refusal(proofGated({ name: "USD Coin" }), COMMITMENT, o, token)!, /token domain/));
test("refuses a verifier it does not accept", () =>
  assert.match(refusal(proofGated({ verifierId: `0x${"0e".repeat(32)}` }), COMMITMENT, o, token)!, /not accepted/));
test("refuses another settlement contract", () =>
  assert.match(refusal(proofGated({ settlement: OPERATOR }), COMMITMENT, o, token)!, /settlement/));
test("refuses an unknown payment flow", () => assert.match(refusal(proofGated({ paymentFlow: "push" }), COMMITMENT, o, token)!, /payment flow/));
test("refuses a prove window of zero or over a day", () => {
  assert.match(refusal(proofGated({ proveWindowSeconds: 0 }), COMMITMENT, o, token)!, /prove window/);
  assert.match(refusal(proofGated({ proveWindowSeconds: 86_401 }), COMMITMENT, o, token)!, /prove window/);
});
test("refuses a scheme it does not know", () => assert.match(refusal({ ...proofGated(), scheme: "exact" }, COMMITMENT, o, token)!, /scheme/));
test("refuses another escrow", () => assert.match(refusal(authCapture({ authCaptureEscrow: OPERATOR }), COMMITMENT, o, token)!, /escrow/));
test("refuses another operator", () => assert.match(refusal(authCapture({ captureAuthorizer: SETTLEMENT }), COMMITMENT, o, token)!, /operator/));
test("refuses a policy", () => assert.match(refusal(authCapture({ policy: OPERATOR }), COMMITMENT, o, token)!, /policy/));
test("refuses fees", () => assert.match(refusal(authCapture({ maxFeeBps: 1 }), COMMITMENT, o, token)!, /fees/));
test("refuses an auth-capture offer before it has a commitment", () => assert.match(refusal(authCapture(), undefined, o, token)!, /commitment/));
test("refuses an offer for another input", () =>
  assert.match(refusal(authCapture(), `0x${"0f".repeat(32)}`, o, token)!, /another input commitment/));
test("refuses a receiverAuthorizer that is not bound to the terms", () =>
  assert.match(refusal(authCapture({ receiverAuthorizer: `0x${"11".repeat(20)}` }), COMMITMENT, o, token)!, /not bound/));
test("refuses a receiverAuthorizer bound to another verifier", () =>
  assert.match(refusal(authCapture({ receiverAuthorizer: termsAuthorizer(`0x${"0e".repeat(32)}`, COMMITMENT) }), COMMITMENT, o, token)!, /not bound/));
