/**
 * The deployment on Base Sepolia (deployments/base-sepolia-v3.1.json; v3.0 in base-sepolia.json), the
 * parts of its ABIs the client uses, and how a contract error becomes an x402 `errorReason` (docs/spec-notes.md, rule 2).
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  BaseError, ContractFunctionRevertedError, defineChain, keccak256, parseAbi,
  type Address, type Hex, type PublicClient,
} from "viem";

export const CHAIN_ID = 84532;
/** Base Sepolia, without viem's OP-stack formatters, so clients have the plain client types. */
export const baseSepolia = defineChain({
  id: CHAIN_ID,
  name: "Base Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://sepolia.base.org"] } },
  blockExplorers: { default: { name: "Basescan", url: "https://sepolia.basescan.org" } },
  testnet: true,
});
export const NETWORK = "eip155:84532" as const;
export const USDC: Address = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
export const ESCROW: Address = "0xf96815976523E00e65Be8f34cA5e64b4f41EB19c";
export const COLLECTOR: Address = "0x8612dfdc421f80336cd14E8EF9cb1E765dB5ab88";
export const ZERO: Address = "0x0000000000000000000000000000000000000000";

export type Deployment = {
  chainId: number;
  commit: string;
  contracts: Record<
    "VerifierRegistry" | "soloVerifier" | "k8Verifier" | "SoloSettlement" | "ChannelSettlement" | "ProofEvaluator8183" |
      "AuthCaptureProofOperator",
    Address
  > &
    // v3.0 has Halo2EzklAdapter and ProofValidator8004; v3.1 has Halo2EzklAdapterV2, its validator still to come.
    Partial<Record<"Halo2EzklAdapter" | "Halo2EzklAdapterV2" | "ProofValidator8004", Address>>;
  verifierIds: { solo: Hex; k8: Hex };
};

/** `deployments/<name>.json` of this repository; by default the current one, v3.1 (`base-sepolia.json` is v3.0). */
export function loadDeployment(repoRoot: string, name = "base-sepolia-v3.1"): Deployment {
  return JSON.parse(readFileSync(join(repoRoot, "deployments", `${name}.json`), "utf8"));
}

const ENTRY = "(address adapter, uint32 lanes, uint32 outputSize, uint32 verifyGas, address target, bytes32 adapterCodeHash, bytes32 targetCodeHash, bytes32 vkHash, bytes32 emptyLane)";
const TERMS = "(address payer, address payTo, address asset, uint256 amount, bytes32 verifierId, bytes32 inputCommitment, uint64 proveBy, bytes32 salt)";

export const ABI = {
  registry: parseAbi([`function entry(bytes32 verifierId) view returns (${ENTRY})`]),
  settlement: parseAbi([
    `function settle(${TERMS} t, ${ENTRY} e, uint256 validBefore, bytes paymentSig, bytes output, bytes proof)`,
    `function open(${TERMS} t, uint256 validBefore, bytes paymentSig) returns (bytes32)`,
    `function release(${TERMS} t, ${ENTRY} e, bytes output, bytes proof)`,
    `function paymentRequestId(${TERMS} t) view returns (bytes32)`,
    "event Settled(bytes32 indexed requestId, bytes32 indexed verifierId, address indexed payTo, bytes output)",
    "error ProofInvalid()",
    "error VerifierUnavailable(bytes32 verifierId)",
    "error Expired()",
    "error NotExpired()",
    "error AlreadyOpened(bytes32 requestId)",
    "error NotOpen(bytes32 requestId)",
    "error TransferFailed()",
    "error TermsMismatch()",
    "error InsufficientGasForVerifier(uint256 provided, uint256 required)",
  ]),
  token: parseAbi([
    "function name() view returns (string)",
    "function version() view returns (string)",
    "function balanceOf(address) view returns (uint256)",
  ]),
  escrow: parseAbi([
    "struct PaymentInfo { address operator; address payer; address receiver; address token; uint120 maxAmount; uint48 preApprovalExpiry; uint48 authorizationExpiry; uint48 refundExpiry; uint16 minFeeBps; uint16 maxFeeBps; address feeReceiver; uint256 salt; }",
    "function getHash(PaymentInfo paymentInfo) view returns (bytes32)",
  ]),
};

/** The agreed `errorReason` for each contract error; the first two are the distinct pair of rule 2, named
 * as the specification names them (`auth_capture_policy_evm.md`, "Status words"). */
export const ERROR_REASONS: Record<string, string> = {
  ProofInvalid: "invalid_auth_capture_evm_proof_invalid",
  VerifierUnavailable: "invalid_auth_capture_evm_verifier_unavailable",
  Expired: "invalid_proof_gated_evm_expired",
  AlreadyOpened: "invalid_proof_gated_evm_payment_already_used",
  NotOpen: "invalid_proof_gated_evm_not_open",
  TermsMismatch: "invalid_proof_gated_evm_terms_mismatch",
  TransferFailed: "invalid_proof_gated_evm_transfer_failed",
  InsufficientGasForVerifier: "invalid_proof_gated_evm_insufficient_gas",
};

/** The `errorReason` for a failed simulation or transaction, or undefined if it is not a revert. */
export function reasonOf(err: unknown): string | undefined {
  if (!(err instanceof BaseError)) return undefined;
  const revert = err.walk(e => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
  if (!revert) return undefined;
  const name = revert.data?.errorName;
  if (name && ERROR_REASONS[name]) return ERROR_REASONS[name];
  return `invalid_proof_gated_evm_reverted${name ? `_${name}` : revert.reason ? `: ${revert.reason}` : ""}`;
}

/** The token's ERC-712 domain, read from the token itself. */
export async function tokenDomain(pub: PublicClient, token: Address) {
  const [name, version] = await Promise.all([
    pub.readContract({ address: token, abi: ABI.token, functionName: "name" }),
    pub.readContract({ address: token, abi: ABI.token, functionName: "version" }),
  ]);
  return { address: token, name, version, chainId: CHAIN_ID };
}

/** keccak256 of the code at `address`: what `EXTCODEHASH` returns. */
export async function codeHash(pub: PublicClient, address: Address): Promise<Hex> {
  const code = await pub.getCode({ address });
  if (!code) throw new Error(`no code at ${address}`);
  return keccak256(code);
}

const R = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;

/** A circuit output (32-byte field elements) as numbers: negative values wrap around the field. */
export function decodeOutput(output: Hex, scale = 13): number[] {
  const words = output.slice(2).match(/.{64}/g) ?? [];
  return words.map(w => {
    const v = BigInt(`0x${w}`);
    return Number(v > R / 2n ? v - R : v) / 2 ** scale;
  });
}
