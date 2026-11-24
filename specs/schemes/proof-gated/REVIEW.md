# Review list for the `proof-gated` draft

Every requirement (MUST, MUST NOT, SHOULD, MAY, REQUIRED and "Required: Yes") in the two specification files, and every number in them, with where it holds in the reference implementation or where it was measured. Line numbers are those of the files in the same commit as this list. `O` is [scheme_proof_gated.md](scheme_proof_gated.md), `E` is [scheme_proof_gated_evm.md](scheme_proof_gated_evm.md).

"Spec only" marks a requirement that no code in this repository implements yet: there is no facilitator, and the reference server (`clients/python`, `x402/server`) settles on chain itself.

## Requirements

| # | Where | Requirement | Holds in | Evidence |
|---:|---|---|---|---|
| 1 | O:28 | `paymentFlow` REQUIRED, no default | Middleware writes it in every offer and refuses a payload without a known flow | `clients/python/exactzk_x402/middleware.py` (`accepts`, `proof_gated`); `clients/ts/test/refusal.test.ts` "refuses an unknown payment flow" |
| 2 | O:36 | Funds MUST reach the server only in a transaction that verified a valid proof for the signed verifier and commitment; that transaction MUST publish the output | `SoloSettlement.settle`, `release`; `ChannelSettlement.settleBatch`; `AuthCaptureProofOperator.captureWithProof`, `chargeWithProof` (proof check before any payment; `Settled`, `BatchSettled`, `CapturedWithProof`, `ChargedWithProof` carry the output) | `test/SoloSettlementOneTransaction.t.sol` `test_v1_01…`, `_02…` to `_04…`; `test/SoloSettlementEscrow.t.sol` `test_v1_01…` to `_04…`; `test/AuthCaptureProofOperator.t.sol` |
| 3 | O:37 | Anyone MAY present a proof | `settle`, `release`, `refund`, `settleBatch`, `captureWithProof`, `chargeWithProof`: no sender check | `test/SoloSettlementEscrow.t.sol` `test_v1_05_anyone_refunds_the_payer_after_prove_by`; `test/AuthCaptureProofOperator.t.sol` `test_anyone_places_the_hold_and_a_valid_proof_captures_it_for_the_receiver` |
| 4 | O:37 | Who presents MUST NOT change where funds go | Payment goes to `terms.payTo`, the channel's `payTo`, or `paymentInfo.receiver` | the same tests; `test/ChannelInvariant.t.sol` |
| 5 | O:38 | Invalid and uncheckable proofs MUST leave the payment as it was and MUST NOT be recorded | Both revert (`ProofInvalid()`, `VerifierUnavailable(bytes32)`); no event, no state | `test/ProofCheck.t.sol` (`…is_invalid_and_does_not_revert`, `…is_unverifiable`); `test/SoloSettlementEscrow.t.sol` `test_if_the_verifier_code_changes_release_is_unavailable_and_refund_still_works` |
| 6 | O:38 | The two MUST be distinct `errorReason` values | Middleware `ERROR_REASONS` maps the two selectors to `invalid_proof_gated_evm_invalid_proof` and `…_verifier_unavailable` | `clients/e2e/run.sh` (tampered proof, wrong entry); `x402/run_e2e.sh` |
| 7 | O:39 | Recorded history MUST be terminal only: settled against a proof, released by the payee, refunded after the deadline (channel: returned at finalize or after the hold) | Events: `Settled`, `Refunded`; `FrameSettled`, `FrameWaived`, `ChannelFinalized`, `HoldSwept`; `CapturedWithProof`, `VoidedByReceiver`, the escrow's `PaymentReclaimed` | `docs/spec-notes.md` (tables); `test/ChannelClose.t.sol`; `test/SoloSettlementReplay.t.sol` `test_row5_…` |
| 8 | O:40 | In a batch, the proof MUST be checked first and once; on failure the whole batch MUST revert | `settleBatch` calls `ProofCheck.check` before reading any lane | `test/ChannelSettlement.t.sol` `test_v1_09_an_invalid_proof_reverts`, `test_v1_14_…settles_nothing_until_anyone_registers_it` |
| 9 | O:41 | The verifier MUST be given its entry's full gas; a transaction that cannot supply it MUST revert as such | `ProofCheck._call`: `InsufficientGasForVerifier` below `verifyGas + verifyGas/63 + 5,000` | `test/ProofCheck.t.sol` `test_insufficient_gas_reverts_with_a_typed_error`, `test_no_gas_amount_turns_a_valid_real_proof_invalid`; `test/SoloSettlementOneTransaction.t.sol` `test_too_little_gas_reverts_with_a_typed_error_not_proof_invalid` |
| 10 | O:42 | An entry MUST be immutable; its id MUST commit to proof system, key hash, both code hashes, shape and gas allowance | `VerifierRegistry`: no update or removal; `computeId` | `test/VerifierRegistry.t.sol` `test_id_is_computed_from_content`, `test_every_field_but_the_addresses_changes_the_id`, `test_gas_allowance_is_part_of_the_id`; `scripts/test_verify_entry.py` `Ids` |
| 11 | O:42, E:31, E:33 | Code MUST be checked at registration and on every use; EIP-7702 delegations MUST be refused | `VerifierRegistry._requireCode`; `ProofCheck._codeMatches` | `test/VerifierRegistry.t.sol` `test_wrong_adapter_code_hash_reverts`, `test_wrong_target_code_hash_reverts`, `test_delegated_account_reverts`; `test/ProofCheck.t.sol` `test_target_whose_code_changed_is_unverifiable` |
| 12 | O:43, E:113 | The client MUST draw fresh randomness after the verifier is named, and MUST refuse a later offer naming another verifier | `clients/ts/src/pay.ts` (commit flow) | `clients/e2e/run.sh`, server fault `switch-verifier` |
| 13 | O:44 | At most the signed amount MUST move, only to the signed recipient; each authorization MUST be usable once | ERC-3009 nonce = request id; `escrowState` | `test/SoloSettlementReplay.t.sol` (`test_row1_authorization_used_in_the_other_flow` and the matrix); `test/ChannelInvariant.t.sol` |
| 14 | O:85–92 | Every binding MUST specify seven items | The EVM file: registry (E: Verifier registry), statement (E: What binds what), client authorization (E: Client payment payload), settlement (E: Settlement), errors (E: Error codes), deadlines (E: Verification step 3, Settlement), commitment format (E: `extra` table) | review |
| 15 | E:31 | `register` MUST revert on an existing id, missing or other code, or a delegation | `VerifierRegistry.register` | `test/VerifierRegistry.t.sol` |
| 16 | E:34 | A transaction MUST carry at least `verifyGas + verifyGas/63 + 5,000` gas at the check | `ProofCheck._call` (`CALL_MARGIN = 5_000`) | as row 9 |
| 17 | E:48 | Commitments MUST be unique | Client's nonce elements (five, inside the Poseidon commitment) | `clients/ts/src/commitment.ts`; `SECURITY.md` |
| 18 | E:74–79 | `name`, `version`, `paymentFlow`, `settlement`, `verifierId`, `inputCommitmentFormat`, `proveWindowSeconds` required | Middleware writes all seven | `middleware.py` `accepts`; `x402/client/conformance.ts` |
| 19 | E:79 | `proveBy` MUST be at most `now + proveWindowSeconds + maxTimeoutSeconds` | Middleware `proof_gated` (`invalid_proof_gated_evm_prove_by`) | `clients/ts/test/refusal.test.ts` "refuses a prove window of zero or over a day" (client side) |
| 20 | E:82 | A server SHOULD set `proveWindowSeconds` to at least its proving time plus two blocks | Spec only (the reference server uses 600) | |
| 21 | E:112 | Client MUST accept only known verifier ids and check the entry's code | `clients/ts/src/direct.ts` `checkedEntry`; `pay.ts` `refusal` | `refusal.test.ts` "refuses a verifier it does not accept" |
| 22 | E:114 | Client MUST set `validAfter` 0 and `validBefore` to `now + maxTimeoutSeconds` or later | `pay.ts` (`validBefore = now + maxTimeoutSeconds`) | `clients/e2e/run.sh` |
| 23 | E:132–139 | Facilitator verification steps 1–7, in order | Partly: the middleware checks 1, 2, 4 and the `proveBy` part of 3, and simulates (7), which covers 5 and 6 on chain. Explicit signature check (5), `registry.exists` before simulation (6) and the `validAfter`/`validBefore` checks in 3: spec only | `middleware.py` `proof_gated`, `send` |
| 24 | E:152 | Facilitator MUST re-verify, cover `verifyGas` in its gas limit, wait for the receipt, return the hash | Middleware simulates, estimates gas, waits for the receipt; no separate facilitator | `middleware.py` `send` |
| 25 | E:154 | `SettlementResponse.extra` of the first `escrow` settle SHOULD carry the request id | Not yet: the middleware returns the `open` transaction hash | spec only |
| 26 | E:168 | A server MUST use one of the facilitator's `settlements` | Spec only (no `/supported`) | |
| 27 | E:169 | A facilitator MUST refuse an entry above `maxVerifyGas` | Spec only | |
| 28 | E:218 | Clients SHOULD default to a 10-minute prove window and a 24-hour challenge window | Spec only for clients (no channel client yet); the contract enforces 60 s and 300 s floors | `src/ChannelSettlement.sol` `MIN_PROVE_WINDOW`, `MIN_CHALLENGE_WINDOW`; `test/ChannelSettlement.t.sol` |

Error codes (E:171–193). Implemented by the middleware: all but two. `invalid_proof_gated_evm_signature` (the middleware relies on the token's check in simulation, which surfaces as `…_simulation_failed`) and `invalid_proof_gated_evm_verify_gas_too_high` are spec only. The middleware also maps the operator's `TermsMismatch()`, `PartialAuthorization` and `WrongOperator()`, which belong to the `auth-capture` composition and are not in the table.

## Numbers

| Where | Number | Source |
|---|---|---|
| O:13 | 0.01 USDC per inference | `deployments/base-sepolia-quickstart.json` (`price` 10000, six decimals) |
| O:13 | 52,650 parameters | `circuits/spike-mlp/MANIFEST.md` |
| O:19 | 11 public inputs, 320 bytes of output | `circuits/spike-mlp/MANIFEST.md`; entry `outputSize` (`deployments/base-sepolia.json`, read by `scripts/verify_entry.py`) |
| O:28 | 20 s proving | `measurements/2026-11-24-prover/README.md` (20.10 s, 2 vCPUs of an Intel Xeon Gold 5220R); an example, not a requirement |
| O:58 | 895,250; 836,981 gas | `MEASUREMENTS.md`, `test/AuthCaptureGas.t.sol` (USDC, local) |
| O:58 | 113,661 per request at K=8; 71,066 at K=16 | `MEASUREMENTS.md` headline (909,289 / 8; 1,137,050 / 16), `test/ChannelSettlementGas.t.sol`, `test/ChannelSettlementK16Gas.t.sol` |
| O:58 | 768,174 gas | `MEASUREMENTS.md`, `test/SoloSettlementFork.t.sol` |
| O:75 | model, settings, SRS SHA-256; `vkHash`; `targetCodeHash` | `circuits/spike-mlp/MANIFEST.md`; `measurements/2026-11-24-verify-entry/` |
| O:75 | solc 0.8.20, 1 run; 53-byte trailer | `scripts/verify_entry.py` (`SOLC_VERSION`, `SOLC_ARGS`, `split_trailer`); reproduced in `measurements/2026-11-24-verify-entry/` |
| O:79 | 2^13 | `circuits/spike-mlp/MANIFEST.md` (`input_scale`, `param_scale` 13) |
| E:34 | `verifyGas/63 + 5,000` | `src/ProofCheck.sol` (`CALL_MARGIN`) |
| E:36 | lanes 1, outputSize 320, verifyGas 600,000, the hashes, id | registry `entry()` on Base Sepolia (`measurements/2026-11-24-verify-entry/ve-solo.json`); `circuits/spike-mlp/MANIFEST.md` |
| E:55–67 | chain 84532, amount 10000, 600 s windows | `deployments/base-sepolia.json`; the quickstart's price; middleware defaults (`prove_window=600`, `max_timeout=600`) |
| E:92, E:96 | 1795509622 | Illustrative timestamp |
| E:122 | one storage read instead of six | `src/ProofCheck.sol` (the entry occupies six slots; the cheap path reads `entryHash` only) |
| E:124 | 3,840-byte proof | `circuits/spike-mlp/MANIFEST.md` |
| E:162 | `maxVerifyGas` 1,000,000 | Illustrative |
| E:214 | 160 bits; 2^160; 2^80 | `src/AuthCaptureProofOperator.sol` `termsAuthorizer`; derivation in `docs/spec-notes.md` |
| E:218 | 909,289 gas, 113,661 per request | `MEASUREMENTS.md`, `test/ChannelSettlementGas.t.sol` |
| E:218 | 60 s, 300 s; 10 minutes, 24 hours | `src/ChannelSettlement.sol`; `README.md` (reasons) |
| E:242 | verifyGas 600,000 and 660,000 | `deployments/base-sepolia.json` entries; `script/DeployBaseSepolia.s.sol` |
| E:242 | 766,226; 839,705; 860,315 gas | `measurements/2026-11-24-testnet/README.md` (Base Sepolia receipts) |
| E:232–240 | addresses | `deployments/base-sepolia.json`; `docs/deployment-notes.md` |

## Open points for the review

- **Shape.** The draft specifies a dedicated scheme plus the `auth-capture` composition. Whether x402 wants (a), (b) or (c) is the maintainers' question (O, Relationship).
- **Facilitator.** Rows 20 and 23–27 have no implementation. A reference facilitator would be the next code.
- **Batches on the wire.** `ChannelSettlement` exists and is measured, but its x402 wire format is left to the `batch-settlement` composition.
- **Name.** `proof-gated` is a working name.
