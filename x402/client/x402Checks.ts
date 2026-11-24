/**
 * Validation of every x402 object this directory produces or receives, against x402's own
 * definitions at the pinned commit (vendor/x402):
 *
 * - PaymentRequired, PaymentRequirements and PaymentPayload: x402's zod schemas (`@x402/core/schemas`),
 *   at run time; and their TypeScript types (`@x402/core/types`), at compile time (`npm run typecheck`).
 * - SettleResponse: x402 defines only a TypeScript type for it. The zod schema below mirrors that
 *   type, and a compile-time check fails `npm run typecheck` if the two ever differ.
 */
import { z } from "zod";
import type { Network, PaymentPayload, PaymentRequired, SettleResponse } from "@x402/core/types";
import { validatePaymentPayload, validatePaymentRequired, validatePaymentRequirements } from "@x402/core/schemas";

const NetworkSchema = z.custom<Network>(v => typeof v === "string" && /^[-a-z0-9]{3,8}:[-_a-zA-Z0-9]{1,32}$/.test(v));

export const SettleResponseSchema = z
  .object({
    success: z.boolean(),
    errorReason: z.string().optional(),
    errorMessage: z.string().optional(),
    payer: z.string().optional(),
    transaction: z.string(),
    network: NetworkSchema,
    amount: z.string().optional(),
    extensions: z.record(z.string(), z.unknown()).optional(),
    extensionResponses: z.record(z.string(), z.unknown()).optional(),
    extra: z.record(z.string(), z.unknown()).optional(),
  })
  .strict();

// Compile-time: the schema's type and x402's SettleResponse are the same type.
type Same<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;
const settleSchemaIsX402Type: Same<z.infer<typeof SettleResponseSchema>, SettleResponse> = true;
void settleSchemaIsX402Type;

export const counts = { paymentRequired: 0, paymentRequirements: 0, paymentPayload: 0, settleResponse: 0 };

// x402's zod schemas are looser than its TypeScript types (any string for `network`, `extra`
// optional), so a value is checked against both: the schema at run time, the type here.
export function checkPaymentRequired(value: unknown): PaymentRequired {
  const pr = validatePaymentRequired(value) as PaymentRequired;
  if (pr.x402Version !== 2) throw new Error("PaymentRequired is not x402Version 2");
  counts.paymentRequired++;
  for (const a of pr.accepts) {
    validatePaymentRequirements(a);
    counts.paymentRequirements++;
  }
  return pr;
}

export function checkPaymentPayload(value: unknown): PaymentPayload {
  const p = validatePaymentPayload(value) as PaymentPayload;
  if (p.x402Version !== 2) throw new Error("PaymentPayload is not x402Version 2");
  validatePaymentRequirements(p.accepted);
  counts.paymentPayload++;
  return p;
}

export function checkSettleResponse(value: unknown): SettleResponse {
  const r = SettleResponseSchema.parse(value);
  counts.settleResponse++;
  return r;
}
