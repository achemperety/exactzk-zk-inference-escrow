/**
 * The client side of the "proof-gated" scheme (working name) on EVM, as an x402 `SchemeNetworkClient`,
 * so that x402's own `x402Client` can register it next to its other schemes.
 *
 * The payer signs one ERC-3009 `ReceiveWithAuthorization` in the token's domain whose nonce is the
 * request id: the ERC-712 struct hash of the terms with the chain id and the settlement contract
 * (`SoloSettlement.paymentRequestId` for paymentFlow "authorization", `escrowRequestId` for
 * "escrow"). The terms name the verifier and the input commitment, so the payment can only be
 * released by a valid proof for exactly that circuit and input.
 */
import type {
  PaymentPayloadContext,
  PaymentPayloadResult,
  PaymentRequirements,
  SchemeNetworkClient,
} from "@x402/core/types";
import { findDefaultAsset } from "@x402/evm";
import { encodeAbiParameters, keccak256, toBytes, toHex, type Address, type Hex } from "viem";

export const PROOF_GATED = "proof-gated";

export const PAYMENT_TYPEHASH = keccak256(
  toBytes(
    "ProofGatedPayment(uint256 chainId,address settlement,address payer,address payTo,address asset," +
      "uint256 amount,bytes32 verifierId,bytes32 inputCommitment,uint64 proveBy,bytes32 salt)",
  ),
);
export const ESCROW_TYPEHASH = keccak256(
  toBytes(
    "ProofGatedEscrow(uint256 chainId,address settlement,address payer,address payTo,address asset," +
      "uint256 amount,bytes32 verifierId,bytes32 inputCommitment,uint64 proveBy,bytes32 salt)",
  ),
);

/** `PaymentRequirements.extra` of a proof-gated offer. */
export type ProofGatedExtra = {
  name: string; // EIP-712 token-domain name
  version: string; // EIP-712 token-domain version
  paymentFlow: "authorization" | "escrow";
  settlement: Address;
  verifierId: Hex;
  inputCommitmentFormat: string;
  proveWindowSeconds: number;
};

/** The terms the payer signs, through the request id. Amounts are decimal strings. */
export type ProofGatedTerms = {
  payer: Address;
  payTo: Address;
  asset: Address;
  amount: string;
  verifierId: Hex;
  inputCommitment: Hex;
  proveBy: number;
  salt: Hex;
};

/** `PaymentPayload.payload` of a proof-gated payment. */
export type ProofGatedPayload = {
  terms: ProofGatedTerms;
  authorization: {
    from: Address;
    to: Address;
    value: string;
    validAfter: string;
    validBefore: string;
    nonce: Hex;
  };
  signature: Hex;
};

export type TypedDataSigner = {
  readonly address: Address;
  signTypedData(message: {
    domain: Record<string, unknown>;
    types: Record<string, unknown>;
    primaryType: string;
    message: Record<string, unknown>;
  }): Promise<Hex>;
};

export function chainIdOf(network: string): number {
  const m = /^eip155:(\d+)$/.exec(network);
  if (!m) throw new Error(`not an EVM network: ${network}`);
  return Number(m[1]);
}

export function requestId(chainId: number, settlement: Address, flow: "authorization" | "escrow", t: ProofGatedTerms): Hex {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" }, { type: "uint256" }, { type: "address" }, { type: "address" }, { type: "address" },
        { type: "address" }, { type: "uint256" }, { type: "bytes32" }, { type: "bytes32" }, { type: "uint64" },
        { type: "bytes32" },
      ],
      [
        flow === "authorization" ? PAYMENT_TYPEHASH : ESCROW_TYPEHASH, BigInt(chainId), settlement, t.payer, t.payTo,
        t.asset, BigInt(t.amount), t.verifierId, t.inputCommitment, BigInt(t.proveBy), t.salt,
      ],
    ),
  );
}

export class ProofGatedEvmScheme implements SchemeNetworkClient {
  readonly scheme = PROOF_GATED;
  // x402's own lookup, as its EVM schemes use: lets x402Client's spend controls price the asset.
  findDefaultAsset = findDefaultAsset;

  /**
   * @param signer - The payer.
   * @param inputCommitment - The commitment to the input this client sends with its request.
   */
  constructor(
    private readonly signer: TypedDataSigner,
    private readonly inputCommitment: Hex,
  ) {}

  async createPaymentPayload(
    x402Version: number,
    requirements: PaymentRequirements,
    _?: PaymentPayloadContext,
  ): Promise<PaymentPayloadResult> {
    if (x402Version !== 2) throw new Error(`Unsupported x402Version: ${x402Version}`);
    const extra = requirements.extra as unknown as ProofGatedExtra;
    for (const k of ["name", "version", "paymentFlow", "settlement", "verifierId", "proveWindowSeconds"] as const) {
      if (extra[k] === undefined) throw new Error(`'${k}' is required in payment requirements extra`);
    }
    const chainId = chainIdOf(requirements.network);
    const now = Math.floor(Date.now() / 1000);
    const salt = toHex(crypto.getRandomValues(new Uint8Array(32)));
    const terms: ProofGatedTerms = {
      payer: this.signer.address,
      payTo: requirements.payTo as Address,
      asset: requirements.asset as Address,
      amount: requirements.amount,
      verifierId: extra.verifierId,
      inputCommitment: this.inputCommitment,
      proveBy: now + extra.proveWindowSeconds,
      salt,
    };
    const authorization = {
      from: this.signer.address,
      to: extra.settlement,
      value: requirements.amount,
      validAfter: "0",
      validBefore: String(now + requirements.maxTimeoutSeconds),
      nonce: requestId(chainId, extra.settlement, extra.paymentFlow, terms),
    };
    const signature = await this.signer.signTypedData({
      domain: { name: extra.name, version: extra.version, chainId, verifyingContract: requirements.asset },
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
      message: {
        ...authorization,
        value: BigInt(authorization.value),
        validAfter: 0n,
        validBefore: BigInt(authorization.validBefore),
      },
    });
    const payload: ProofGatedPayload = { terms, authorization, signature };
    return { x402Version, payload: payload as unknown as Record<string, unknown> };
  }
}

/** The `receiverAuthorizer` that binds an auth-capture payment to proof terms (AuthCaptureProofOperator). */
export function termsAuthorizer(verifierId: Hex, inputCommitment: Hex): Address {
  const h = keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "bytes32" }, { type: "bytes32" }],
      [keccak256(toBytes("ProofGatedTerms(bytes32 verifierId,bytes32 inputCommitment)")), verifierId, inputCommitment],
    ),
  );
  return `0x${h.slice(-40)}` as Address;
}
