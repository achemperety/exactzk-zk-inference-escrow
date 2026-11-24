/**
 * The wire types of clients/ts (which needs no x402 package at run time) against x402's own types at
 * the pinned commit. Checked by `npm run typecheck` in this directory:
 *
 * - what the client sends (`PaymentPayload`) must be a valid x402 object;
 * - what it receives (`PaymentRequired`, `PaymentRequirements`, `SettleResponse`) must fit its types.
 */
import type { PaymentPayload, PaymentRequired, PaymentRequirements, SettleResponse } from "@x402/core/types";
import type * as Client from "../../clients/ts/src/x402";

type Assert<T extends true> = T;
type Fits<A, B> = [A] extends [B] ? true : false;

export type Sends = Assert<Fits<Client.PaymentPayload, PaymentPayload>>;
export type ReceivesRequired = Assert<Fits<PaymentRequired, Client.PaymentRequired>>;
export type ReceivesRequirements = Assert<Fits<PaymentRequirements, Client.PaymentRequirements>>;
export type ReceivesSettle = Assert<Fits<SettleResponse, Client.SettleResponse>>;
// The requirements the client echoes back in `accepted` are the server's own, so both directions hold.
export type EchoesRequirements = Assert<Fits<Client.PaymentRequirements, PaymentRequirements>>;
