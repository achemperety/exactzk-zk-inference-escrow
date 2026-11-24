/**
 * x402 version 2 wire objects, as plain types: the client needs no x402 package at run time. They
 * mirror x402's TypeScript definitions (`@x402/core/types`), and `x402/client/conformance.ts` fails
 * the type check if the two ever disagree. Headers carry base64 JSON.
 */
export type Network = `${string}:${string}`;

export type ResourceInfo = { url: string; description?: string; mimeType?: string };

export type PaymentRequirements = {
  scheme: string;
  network: Network;
  asset: string;
  amount: string;
  payTo: string;
  maxTimeoutSeconds: number;
  extra: Record<string, unknown>;
};

export type PaymentRequired = {
  x402Version: number;
  error?: string;
  resource: ResourceInfo;
  accepts: PaymentRequirements[];
  extensions?: Record<string, unknown>;
};

export type PaymentPayload = {
  x402Version: number;
  resource?: ResourceInfo;
  accepted: PaymentRequirements;
  payload: Record<string, unknown>;
  extensions?: Record<string, unknown>;
};

export type SettleResponse = {
  success: boolean;
  errorReason?: string;
  errorMessage?: string;
  payer?: string;
  transaction: string;
  network: Network;
  amount?: string;
  extensions?: Record<string, unknown>;
  extra?: Record<string, unknown>;
};

export const HEADER = {
  required: "PAYMENT-REQUIRED",
  signature: "PAYMENT-SIGNATURE",
  response: "PAYMENT-RESPONSE",
} as const;

export function encodeHeader(value: unknown): string {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64");
}

export function decodeHeader<T>(value: string): T {
  return JSON.parse(Buffer.from(value, "base64").toString("utf8")) as T;
}
