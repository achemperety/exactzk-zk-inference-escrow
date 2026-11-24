/**
 * Paying the deployment directly, without a server: the payer holds a published proof and settles
 * against it in one transaction (`SoloSettlement.settle`). The quickstart's published-proof mode.
 */
import { decodeEventLog, type Account, type Address, type Chain, type Hex, type PublicClient, type Transport, type WalletClient } from "viem";
import { ABI, CHAIN_ID, codeHash, reasonOf, tokenDomain, USDC, type Deployment } from "./chain.js";
import { random32, requestId, signReceive, termsArg, type Signer, type Terms } from "./terms.js";

export type Result = {
  outcome: "settled" | "not settled";
  reason?: string;
  transaction?: Hex;
  block?: bigint;
  gasUsed?: bigint;
  output?: Hex;
  requestId?: Hex;
};

export type DirectArgs = {
  pub: PublicClient;
  wallet: WalletClient<Transport, Chain, Account>;
  signer: Signer;
  deployment: Deployment;
  verifierId: Hex;
  inputCommitment: Hex;
  output: Hex;
  proof: Hex;
  payTo: Address;
  amount: bigint;
  proveWindowSeconds?: number;
};

/** The registered entry of `verifierId`, after checking that its code is the code it names. */
export async function checkedEntry(pub: PublicClient, d: Deployment, verifierId: Hex) {
  const e = await pub.readContract({ address: d.contracts.VerifierRegistry, abi: ABI.registry, functionName: "entry", args: [verifierId] });
  if (e.adapter === "0x0000000000000000000000000000000000000000") throw new Error(`verifier ${verifierId} is not registered`);
  if ((await codeHash(pub, e.adapter)) !== e.adapterCodeHash) throw new Error("the adapter's code is not the registered code");
  if ((await codeHash(pub, e.target)) !== e.targetCodeHash) throw new Error("the verifier's code is not the registered code");
  return e;
}

export async function settleWithProof(a: DirectArgs): Promise<Result> {
  const settlement = a.deployment.contracts.SoloSettlement;
  const entry = await checkedEntry(a.pub, a.deployment, a.verifierId);
  const now = Math.floor(Date.now() / 1000);
  const terms: Terms = {
    payer: a.signer.address,
    payTo: a.payTo,
    asset: USDC,
    amount: a.amount.toString(),
    verifierId: a.verifierId,
    inputCommitment: a.inputCommitment,
    proveBy: now + (a.proveWindowSeconds ?? 600),
    salt: random32(),
  };
  const id = requestId(CHAIN_ID, settlement, "authorization", terms);
  const onChain = await a.pub.readContract({ address: settlement, abi: ABI.settlement, functionName: "paymentRequestId", args: [termsArg(terms)] });
  if (onChain !== id) throw new Error("the settlement contract computes another request id for these terms");
  const validBefore = String(terms.proveBy);
  const sig = await signReceive(a.signer, await tokenDomain(a.pub, USDC), {
    from: terms.payer, to: settlement, value: terms.amount, validAfter: "0", validBefore, nonce: id,
  });

  const args = [termsArg(terms), entry, BigInt(validBefore), sig, a.output, a.proof] as const;
  try {
    const { request } = await a.pub.simulateContract({ account: a.wallet.account, address: settlement, abi: ABI.settlement, functionName: "settle", args });
    const hash = await a.wallet.writeContract(request);
    const r = await a.pub.waitForTransactionReceipt({ hash });
    if (r.status !== "success") return { outcome: "not settled", reason: "invalid_proof_gated_evm_transaction_reverted", transaction: hash, requestId: id };
    for (const log of r.logs) {
      if (log.address.toLowerCase() !== settlement.toLowerCase()) continue;
      const ev = decodeEventLog({ abi: ABI.settlement, data: log.data, topics: log.topics });
      if (ev.eventName === "Settled" && ev.args.requestId === id) {
        return { outcome: "settled", transaction: hash, block: r.blockNumber, gasUsed: r.gasUsed, output: ev.args.output, requestId: id };
      }
    }
    return { outcome: "not settled", reason: "no Settled event for this request", transaction: hash, requestId: id };
  } catch (err) {
    const reason = reasonOf(err);
    if (!reason) throw err;
    return { outcome: "not settled", reason, requestId: id };
  }
}
