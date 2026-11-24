# Client: paying for proof-gated inference

TypeScript, Node 20 or later. One run-time dependency, `viem`; `tsx` runs the TypeScript directly. `@ezkljs/engine` (EZKL's WebAssembly build) is optional and only needed to compute input commitments in live mode.

```
npm ci
npm run typecheck
npm test                      # the checks the client makes before it signs (no chain)
npm run check-commitment      # the client's commitment of the published input equals the proof's
```

## `pay(url, input, options)`

Buys one inference from an x402 version 2 server (`src/pay.ts`). It returns `{ outcome, reason, transaction, output, choice, settle }`, where `outcome` is `settled`, `not settled` (the server or the chain said no; `reason` is the `errorReason`), or `refused` (the client would not sign; `reason` says why).

It pays with the first offer, in the order of `options.prefer`, that passes every check of `refusal()`:

| Checked against what the client knows | Both schemes | `proof-gated` | `auth-capture` |
|---|---|---|---|
| Network is Base Sepolia, asset is USDC, price at most `maxAmount` | yes | | |
| The token's ERC-712 name and version are the token's own | yes | | |
| The verifier is one of `verifierIds` | yes | | |
| The settlement contract is this deployment's `SoloSettlement` | | yes | |
| Payment flow is `authorization` or `escrow`; prove window between 1 s and a day | | yes | |
| x402's canonical escrow, a custom operator that is this deployment's `AuthCaptureProofOperator`, no policy, no fees | | | yes |
| The offer names this client's input commitment, and `receiverAuthorizer = termsAuthorizer(verifierId, inputCommitment)` | | | yes |

`input` is either `{ body, commitment }`, for an input whose commitment is fixed (the published input), or `{ body, commit }`, for a fresh one. With `commit`, the client first asks the server without a commitment. Any offer that names an accepted verifier tells it which verifier the server will prove with. Only then does it call `commit(verifierId)`, which draws the nonce values and returns the commitment. It asks again with the commitment, and refuses if the verifier has changed (`docs/spec-notes.md`, "What binds the terms").

After a successful answer the client does not take the server's word: it waits for the reported transaction, and takes the output from the contract's `Settled` (or the operator's `CapturedWithProof`) event, for this payment's request id.

## `settleWithProof(args)`

Pays the deployment directly, without a server, with a proof the payer already holds (`src/direct.ts`): `SoloSettlement.settle` in one transaction, sent by the payer. Before signing it reads the verifier's entry from the registry, checks that the adapter and the verifier run the code the entry names, and checks that the contract computes the same request id for the terms as the client. The quickstart's published-proof mode is this function with `published/solo-proof.json`.

## Files

| Path | What |
|---|---|
| `src/x402.ts` | x402 version 2 wire types and header encoding; `x402/client/conformance.ts` checks them against x402's own types |
| `src/terms.ts` | Request ids, `termsAuthorizer`, x402's bound salt, the ERC-3009 signature |
| `src/chain.ts` | The deployment record, ABIs, error-to-`errorReason` mapping, output decoding |
| `src/pay.ts`, `src/direct.ts` | The two ways to pay |
| `src/commitment.ts` | The input commitment (EZKL's hashed/public input visibility) for live mode |
| `bin/quickstart.ts` | The quickstart (`../../quickstart.sh`) |
| `bin/measure.ts` | The testnet measurements of `measurements/2026-11-24-testnet/` |
| `bin/check-commitment.ts` | The commitment check against the published proof |
| `published/` | The stored solo and K=8 proofs with their public inputs, from `test/fixtures/` |
| `test/refusal.test.ts` | One test per check before signing (19) |
| `test/e2e.ts` | Against the Python middleware on a local node (`bash clients/e2e/run.sh`) |

## The end-to-end run

`bash clients/e2e/run.sh` (Foundry, `npm install` here, and the Python environment of `x402/server`) starts a local node with the chain state of `script/X402LocalChain.s.sol`, the middleware with a test server that can be told to misbehave, and `test/e2e.ts`. It pays with each of `proof-gated` authorization, `proof-gated` escrow and `auth-capture`. Each settles against the real proof, and the output is read from the chain. A tampered proof and a wrong verifier entry fail with `invalid_proof_gated_evm_invalid_proof` and `invalid_proof_gated_evm_verifier_unavailable`, and the payee gets nothing. A prover that returns a proof about another input is refused. The client refuses an unbound `receiverAuthorizer`, and a verifier that changes after its commitment. It reports the chain's output when the server's answer claims another. 36 checks.
