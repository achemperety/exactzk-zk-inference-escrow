/**
 * What a payer signs, for both ways of paying the deployment:
 *
 * - "proof-gated" (this project's scheme, working name): one ERC-3009 `ReceiveWithAuthorization` in
 *   the token's domain whose nonce is the request id, the ERC-712 struct hash of the terms with the
 *   chain id and `SoloSettlement` (`paymentRequestId` / `escrowRequestId`).
 * - "auth-capture" (x402's scheme) with `AuthCaptureProofOperator`: x402's payload, whose salt binds
 *   `receiverAuthorizer = termsAuthorizer(verifierId, inputCommitment)`.
 */
import { encodeAbiParameters, keccak256, toBytes, toHex, type Address, type Hex } from "viem";

export type Flow = "authorization" | "escrow";

/** `SoloSettlement.Terms`. Amounts are decimal strings, as on the wire. */
export type Terms = {
  payer: Address;
  payTo: Address;
  asset: Address;
  amount: string;
  verifierId: Hex;
  inputCommitment: Hex;
  proveBy: number;
  salt: Hex;
};

export type Authorization = { from: Address; to: Address; value: string; validAfter: string; validBefore: string; nonce: Hex };

export type Signer = {
  readonly address: Address;
  signTypedData(message: {
    domain: Record<string, unknown>;
    types: Record<string, readonly { name: string; type: string }[]>;
    primaryType: string;
    message: Record<string, unknown>;
  }): Promise<Hex>;
};

const TERMS_FIELDS =
  "(uint256 chainId,address settlement,address payer,address payTo,address asset," +
  "uint256 amount,bytes32 verifierId,bytes32 inputCommitment,uint64 proveBy,bytes32 salt)";
export const PAYMENT_TYPEHASH = keccak256(toBytes("ProofGatedPayment" + TERMS_FIELDS));
export const ESCROW_TYPEHASH = keccak256(toBytes("ProofGatedEscrow" + TERMS_FIELDS));
export const PROOF_TERMS_TYPEHASH = keccak256(toBytes("ProofGatedTerms(bytes32 verifierId,bytes32 inputCommitment)"));
export const SALT_BINDING_TYPEHASH = keccak256(
  toBytes("x402AuthCaptureSaltBinding(address receiverAuthorizer,address policy,uint256 saltNonce)"),
);

export const random32 = (): Hex => toHex(crypto.getRandomValues(new Uint8Array(32)));

export function chainIdOf(network: string): number {
  const m = /^eip155:(\d+)$/.exec(network);
  if (!m) throw new Error(`not an EVM network: ${network}`);
  return Number(m[1]);
}

/** `SoloSettlement.paymentRequestId` (flow "authorization") or `escrowRequestId` (flow "escrow"). */
export function requestId(chainId: number, settlement: Address, flow: Flow, t: Terms): Hex {
  return keccak256(
    encodeAbiParameters(
      ["bytes32", "uint256", "address", "address", "address", "address", "uint256", "bytes32", "bytes32", "uint64", "bytes32"].map(
        type => ({ type }),
      ),
      [
        flow === "authorization" ? PAYMENT_TYPEHASH : ESCROW_TYPEHASH, BigInt(chainId), settlement, t.payer, t.payTo,
        t.asset, BigInt(t.amount), t.verifierId, t.inputCommitment, BigInt(t.proveBy), t.salt,
      ],
    ),
  );
}

/** The `receiverAuthorizer` that binds an auth-capture payment to proof terms. */
export function termsAuthorizer(verifierId: Hex, inputCommitment: Hex): Address {
  const h = keccak256(
    encodeAbiParameters([{ type: "bytes32" }, { type: "bytes32" }, { type: "bytes32" }], [PROOF_TERMS_TYPEHASH, verifierId, inputCommitment]),
  );
  return `0x${h.slice(-40)}` as Address;
}

/** x402's bound `PaymentInfo.salt`. */
export function boundSalt(receiverAuthorizer: Address, policy: Address, saltNonce: Hex): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "address" }, { type: "address" }, { type: "uint256" }],
      [SALT_BINDING_TYPEHASH, receiverAuthorizer, policy, BigInt(saltNonce)],
    ),
  );
}

/** The payer's ERC-3009 `ReceiveWithAuthorization` signature in the token's ERC-712 domain. */
export function signReceive(signer: Signer, token: { address: Address; name: string; version: string; chainId: number }, a: Authorization): Promise<Hex> {
  return signer.signTypedData({
    domain: { name: token.name, version: token.version, chainId: token.chainId, verifyingContract: token.address },
    types: {
      ReceiveWithAuthorization: [
        { name: "from", type: "address" },
        { name: "to", type: "address" },
        { name: "value", type: "uint256" },
        { name: "validAfter", type: "uint256" },
        { name: "validBefore", type: "uint256" },
        { name: "nonce", type: "bytes32" },
      ],
    },
    primaryType: "ReceiveWithAuthorization",
    message: { ...a, value: BigInt(a.value), validAfter: BigInt(a.validAfter), validBefore: BigInt(a.validBefore) },
  });
}

/** `SoloSettlement.Terms` as the contract's ABI takes it. */
export function termsArg(t: Terms) {
  return { ...t, amount: BigInt(t.amount), proveBy: BigInt(t.proveBy) };
}
