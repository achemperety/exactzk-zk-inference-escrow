/**
 * The client's own map from a contract error to an `errorReason` (`reasonOf`), used when it settles
 * directly. Real revert data, encoded from the settlement contract's ABI. No chain is needed.
 *
 *   node --import tsx --test test/reasons.test.ts
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import { BaseError, ContractFunctionRevertedError, encodeErrorResult } from "viem";
import { ABI, reasonOf } from "../src/index.js";

const reverted = (errorName: string, args: readonly unknown[] = []) =>
  new ContractFunctionRevertedError({
    abi: ABI.settlement,
    functionName: "settle",
    data: encodeErrorResult({ abi: ABI.settlement, errorName, args } as never),
  });

test("an invalid proof is reported with the specification's name", () => {
  assert.equal(reasonOf(reverted("ProofInvalid")), "invalid_auth_capture_evm_proof_invalid");
});

test("an uncheckable proof is reported with the specification's name, never as invalid", () => {
  const reason = reasonOf(reverted("VerifierUnavailable", [`0x${"0c".repeat(32)}`]));
  assert.equal(reason, "invalid_auth_capture_evm_verifier_unavailable");
});

test("the revert is found inside a wrapping error", () => {
  const wrapped = new BaseError("simulation failed", { cause: reverted("ProofInvalid") });
  assert.equal(reasonOf(wrapped), "invalid_auth_capture_evm_proof_invalid");
});

test("something that is not a revert has no reason", () => {
  assert.equal(reasonOf(new Error("network down")), undefined);
});
