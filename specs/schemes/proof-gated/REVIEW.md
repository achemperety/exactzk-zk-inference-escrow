# Review list for the proof-condition draft

Every requirement (MUST, MUST NOT, SHOULD, MAY) in the specification files, and every number in them, with where it holds in the reference implementation or where it was measured. Line numbers are those of the files in the same commit as this list.

| Key | File | Status |
|---|---|---|
| C | [proof_condition.md](proof_condition.md) | Normative |
| P | [auth_capture_policy_evm.md](auth_capture_policy_evm.md) | Normative profile |
| B | [batch_settlement_claim_evm.md](batch_settlement_claim_evm.md) | Proposal: it states no requirement, so only its numbers are listed |
| R | [reference_evm.md](reference_evm.md) | Normative where it says MUST; otherwise a description of the reference contracts |

"Spec only" marks a requirement that no code in this repository implements yet. There is no facilitator, and no client or server for the policy route: `ProofCapturePolicy` and `PolicyCaptureOperator` are exercised by Forge tests against the escrow built from source, not by the x402 run.

## Requirements

| # | Where | Requirement | Holds in | Evidence |
|---:|---|---|---|---|
| 1 | C:28 | A host scheme MUST keep the three outcomes apart | `ProofCheck` returns `Valid`, `Invalid`, `Unverifiable`; `ProofCapturePolicy` answers three distinct words; the native contracts and the gate revert with `ProofInvalid()` or `VerifierUnavailable(bytes32)` | `test/ProofCheck.t.sol`; `test/ProofCapturePolicy.t.sol` (`test_an_invalid_proof_is_refused_with_proof_invalid`, `test_an_unknown_entry_is_refused_with_verifier_unavailable_never_proof_invalid`); `ProofClaimGate.t.sol` `test_a_check_that_cannot_run_is_unavailable_not_invalid` |
| 2 | C:36 | "Could not be checked" MUST NOT degrade into "invalid"; Invalid only in the case the table names; an unclassified failure MUST NOT be reported as Invalid | `ProofCheck.checkOne`, `checkOneInMemory`: the entry and code are checked before the verifier runs, so a tampered proof against an unknown entry or changed code is `Unverifiable` | `test_an_unknown_entry_…_never_proof_invalid` and `test_changed_code_is_refused_with_verifier_unavailable_never_proof_invalid` (each with a tampered proof as well); mutations PP3, PP6, PC1–PC3 (`test/MUTATIONS.md`) |
| 3 | C:38 | Policies, gates and operators MUST use the words of P and define none | `PolicyStatus` (`src/ICapturePolicyStatus.sol`); `PolicyCaptureOperator` passes the word on unchanged. The prototype gate reverts with the two contract errors, which R maps to the words | `test_the_operator_refuses_every_word_but_authorized`; `test_the_status_words_and_the_salt_follow_the_derivation`; mutations PP14, PP15, PO3 |
| 4 | C:42 | Funds MUST reach the server only in a transaction that verified a valid proof for the signed verifier and commitment; that transaction MUST carry the output | `SoloSettlement.settle`, `release`; `ChannelSettlement.settleBatch`; `AuthCaptureProofOperator.captureWithProof`, `chargeWithProof`; `PolicyCaptureOperator.captureWithPolicy`, `chargeWithPolicy` (output in the call data; the event carries `keccak256(policyData)`); `ProofClaimGate.claimWithProof` (`ClaimProven` carries the output) | `test/SoloSettlementOneTransaction.t.sol`, `test/SoloSettlementEscrow.t.sol`, `test/AuthCaptureProofOperator.t.sol`; `test_a_valid_proof_authorizes_and_anyone_captures_for_the_receiver`; `test_a_proven_request_at_its_signed_position_is_claimed_and_paid_out` |
| 5 | C:43 | Who presents MUST NOT change where funds go; anyone MAY present where the host lets anyone submit | No sender check in any of the calls in row 4; payment to `terms.payTo`, `paymentInfo.receiver`, or the gate's fixed payee | `test_a_valid_proof_authorizes_and_anyone_captures_for_the_receiver` (a stranger captures, the receiver is paid); gate test of row 4 (a stranger claims, the payee is paid); `test/ChannelInvariant.t.sol` |
| 6 | C:44 | An invalid and an uncheckable proof MUST leave the payment as it was, MUST NOT be recorded, and MUST be two distinct `errorReason` values | Every failure reverts; the words map to two reasons in P; the reference middleware maps the native selectors to two reasons | `test_a_refused_attempt_leaves_the_authorization_capturable`; `test_an_invalid_proof_is_refused_and_the_position_stays_open`; `test/ProofCheck.t.sol`; `clients/e2e/run.sh`, `x402/run_e2e.sh` (native). The facilitator mapping for the policy route: spec only |
| 7 | C:45 | A failed check MUST NOT end an authorization, a hold or a voucher | Refusals revert before the escrow or channel is called | `test_a_refused_attempt_leaves_the_authorization_capturable` (three refusals, then a capture one second before the deadline); `test_after_refusals_the_payer_reclaims_from_the_capture_deadline_on`; `test_a_refused_charge_moves_nothing_and_the_authorization_stays_usable`; `test_an_invalid_proof_is_refused_and_the_position_stays_open` |
| 8 | C:46 | Recorded history MUST be terminal only | Native events: `Settled`, `Refunded`; `FrameSettled`, `FrameWaived`, `ChannelFinalized`, `HoldSwept`. `auth-capture`: `CapturedWithProof`, `CapturedWithPolicy`, `ChargedWithPolicy`, `VoidedByReceiver`, the escrow's `PaymentReclaimed`. Gate: `ClaimProven` | `docs/spec-notes.md`; `test/ChannelClose.t.sol`; `test/SoloSettlementReplay.t.sol` `test_row5_…` |
| 9 | C:47 | When one proof covers several requests: checked first and once; on failure the whole call MUST revert | `ChannelSettlement.settleBatch` calls `ProofCheck.check` before reading any lane. The gate checks one-lane proofs only (B, open point 6) | `test/ChannelSettlement.t.sol` `test_v1_09_an_invalid_proof_reverts`, `test_v1_14_…` |
| 10 | C:48 | The verifier MUST get its entry's full gas; a transaction that cannot supply it MUST revert as such | `ProofCheck._call` (`InsufficientGasForVerifier` below `verifyGas + verifyGas/63 + 5,000`), on every path including `checkOneInMemory` | `test/ProofCheck.t.sol` `test_insufficient_gas_reverts_with_a_typed_error`, `test_adapter_always_receives_its_full_allowance`; `test_too_little_gas_reverts_with_a_typed_error_not_a_refusal`; `test_the_verifier_receives_exactly_its_allowance_through_the_policy` |
| 11 | C:49, R:37, R:39 | Entries immutable; the id commits to the listed fields; code checked at registration and on every use; EIP-7702 delegations refused | `VerifierRegistry` (no update or removal; `computeId`; `_requireCode`); `ProofCheck._codeMatches` | `test/VerifierRegistry.t.sol`; `test/ProofCheck.t.sol` `test_target_whose_code_changed_is_unverifiable`; `test_changed_code_is_refused_with_verifier_unavailable_never_proof_invalid` (target and adapter) |
| 12 | C:50, R:82 | The client MUST draw fresh randomness after the verifier is named, and MUST refuse a later offer naming another verifier | `clients/ts/src/pay.ts` (commit flow) | `clients/e2e/run.sh`, server fault `switch-verifier` |
| 13 | C:51 | The condition MUST NOT weaken the host's fund safety or replay protection | The policy and the gate only add a check before the host's own call; the escrow and the channel contract keep every check of their own | `test_a_hold_is_captured_once`; `test_a_payment_for_another_operator_cannot_be_captured_here`; `test_one_proof_claims_one_unit_and_a_position_counts_once`; `test_without_the_gate_nobody_claims_or_signs_for_its_channel`; `test/SoloSettlementReplay.t.sol` |
| 14 | C:91 | Every host binding MUST specify seven items | P: registry (through R:Verifier registry), statement (R:What binds what), binding (P:Binding the terms), check (P:The route today, P:Under the `"policy"` type), outcomes (P:Status words), refusals (P:What each outcome does), commitment format (P:98) | review |
| 15 | P:42 | A policy MUST advertise the ERC-165 id; a facilitator MUST refuse a non-zero `extra.policy` that does not | `ProofCapturePolicy.supportsInterface`; facilitator: spec only | `test_supports_its_interface_and_erc165_only`; mutation PP13 |
| 16 | P:43 | A policy MAY implement the boolean hooks; they MUST be true exactly when the status is `Authorized` | `authorizeCapture`, `authorizeCharge` | `test_the_boolean_hooks_are_true_only_for_authorized`; mutations PP9, PP10 |
| 17 | P:58 | A policy or an operator MUST NOT define reasons of its own | `PolicyCaptureOperator` has one refusal error, `PolicyRefused(bytes32)`, carrying the policy's word | `test_the_operator_refuses_every_word_but_authorized` |
| 18 | P:60 | A policy MUST answer a status for every outcome it can name and MUST NOT revert to express one | `ProofCapturePolicy._status` returns a word for each outcome; it reverts only on undecodable `policyData` and on `InsufficientGasForVerifier` | `test_an_invalid_proof_…`, `test_an_unknown_entry_…`, `test_changed_code_…`, `test_terms_the_payer_did_not_sign_are_denied_not_proof_invalid`, `test_a_salt_bound_to_another_policy_is_denied` (each calls `captureStatus` directly); `test_arguments_that_do_not_fit_the_entry_are_invalid_through_the_policy` |
| 19 | P:61 | `"ProofInvalid"` only in the table's case; no default degradation | As row 2, through `checkOneInMemory` | As row 2 |
| 20 | P:62 | An operator MUST consult the check after its own unconditional checks and MUST revert with `PolicyRefused(word)` on anything but `Authorized` | `PolicyCaptureOperator._require`. Its own checks are the full-amount rule on `authorize` and the receiver check on `voidByReceiver`; capture and charge have none of their own before the policy, and the escrow's run after it | `test_the_operator_refuses_every_word_but_authorized` (zero, the three refusal words, a lower-case "authorized", all ones); mutations PO1–PO3, PO7 |
| 21 | P:63 | A facilitator MUST map words through the table and MUST NOT map an unknown word or revert to `proof_invalid` | Spec only | |
| 22 | P:78 | On `InsufficientGasForVerifier` a facilitator MUST raise its gas limit and MUST NOT report the proof invalid | Contract side: the error bubbles out of the policy unchanged. Facilitator: spec only | `test_too_little_gas_reverts_with_a_typed_error_not_a_refusal` |
| 23 | P:96 | A client MUST derive the salt nonce from the terms; a server MUST check the binding before running the resource | On chain the policy answers `"Denied"` to anything else. Client and server: spec only | `test_terms_the_payer_did_not_sign_are_denied_not_proof_invalid`; `test_the_status_words_and_the_salt_follow_the_derivation`; mutations PP1, PP7, PP8 |
| 24 | P:98 | Before signing, a client MUST check `extra.inputCommitment` and `extra.verifierId` | For the native and terms-authorizer routes: `clients/ts/src/pay.ts` `refusal`, `direct.ts` `checkedEntry`. For the policy route: spec only | `clients/ts/test/refusal.test.ts` |
| 25 | R:40 | A transaction MUST carry at least `verifyGas + verifyGas/63 + 5,000` gas at the check | `ProofCheck._call` (`CALL_MARGIN = 5_000`) | As row 10 |
| 26 | R:54 | Commitments MUST be unique | The client's nonce elements, inside the Poseidon commitment | `clients/ts/src/commitment.ts`; `SECURITY.md` |
| 27 | R:76 | Clients SHOULD default to a 10-minute prove window and a 24-hour challenge window | Spec only for clients; the contract enforces 60 s and 300 s floors | `src/ChannelSettlement.sol` `MIN_PROVE_WINDOW`, `MIN_CHALLENGE_WINDOW`; `test/ChannelSettlement.t.sol` |
| 28 | R:80–81 | A client MUST accept only known verifier ids and check the entry's code | `clients/ts/src/direct.ts` `checkedEntry`; `pay.ts` `refusal` | `refusal.test.ts` "refuses a verifier it does not accept" |

## Numbers

| Where | Number | Source |
|---|---|---|
| C:18 | 0.01 USDC per inference; 52,650 parameters | `deployments/base-sepolia-quickstart.json` (`price` 10000, six decimals); `circuits/spike-mlp/MANIFEST.md` |
| C:24 | 11 public inputs, 320 bytes of output | `circuits/spike-mlp/MANIFEST.md`; entry `outputSize` |
| C:66, R:158, P:169–170 | 899,361 and 841,355 gas (policy route, USDC) | `test/ProofCapturePolicyGas.t.sol`, fork suite at block 62,638,490: 148,643 + 750,718; 841,355 |
| C:66, B:45, R:159 | 769,210 gas per claim, steady | `ProofClaimGate.t.sol` `test_gas_claim_with_proof_steady` |
| C:66, B:47, R:154 | 768,174 gas | `MEASUREMENTS.md`, `test/SoloSettlementFork.t.sol` |
| C:81 | model, settings, SRS SHA-256; `vkHash`; `targetCodeHash`; solc 0.8.20, 1 run; 53-byte trailer | `circuits/spike-mlp/MANIFEST.md`; `scripts/verify_entry.py`; `measurements/2026-11-24-verify-entry/` |
| C:85 | 2^13 | `circuits/spike-mlp/MANIFEST.md` (`input_scale`, `param_scale` 13) |
| P:48 | 32 bytes per status word | `src/ICapturePolicyStatus.sol` |
| P:76 | 1 USDC; one hour; one second before the deadline | `test/AuthCaptureBase.sol` (`AMOUNT`, `CAPTURE_DEADLINE = T0 + 3600`); `test_a_refused_attempt_leaves_the_authorization_capturable` (`CAPTURE_DEADLINE - 1`) |
| P:95 | 256 and 160 bits; 2^256; 2^128 | `ProofCapturePolicy.saltNonce` (full keccak256 word); the bounds follow from the hash's width under the random-function assumption stated with them |
| P:163 | block 62,638,490 | The fork block of every USDC row in `MEASUREMENTS.md` |
| P:167–170 | 126,385; 148,643; 739,872; 750,718; 866,257; 899,361; 816,774; 841,355 | `test/ProofCapturePolicyGas.t.sol` (pins in the steady suite; fork suite opt-in) |
| P:167–170 | 126,385; 148,600; 735,804; 746,650; 862,189; 895,250; 812,420; 836,981 | `test/AuthCaptureGas.t.sol`; `MEASUREMENTS.md` |
| P:172 | about 4,100 gas more | 899,361 − 895,250 = 4,111 (USDC); 866,257 − 862,189 = 4,068 (test token); charge 4,354 and 4,374 |
| P:172, R:161 | 577,544 | `test/FixtureBaseline.t.sol` |
| B:16 | commit `d7d0a435` | `test/external/README.md` (x402 `batch-settlement`) |
| B:18, B:60 | `version` "0"; leaf tag "v0" | `test/experimental/batch-gate/ProofClaimGate.sol` |
| B:38 | 15 tests | `ProofClaimGate.t.sol` |
| B:44 | 797,428 gas | `test_gas_claim_with_proof_first_claim_of_the_channel` |
| B:52 | 15 minutes | `x402BatchSettlement.MIN_WITHDRAW_DELAY` |
| B:59 | 96 and 64 bytes | Leaf preimage: three 32-byte words; node preimage: two |
| R:40 | `verifyGas/63 + 5,000` | `src/ProofCheck.sol` (`CALL_MARGIN`) |
| R:42 | lanes 1, outputSize 320, verifyGas 600,000, the hashes, id | registry `entry()` on Base Sepolia (`measurements/2026-11-24-verify-entry/ve-solo.json`); `circuits/spike-mlp/MANIFEST.md` |
| R:74 | one storage read instead of six; 3,840 bytes | `src/ProofCheck.sol` (the entry occupies six slots; the cheap path reads `entryHash` only); `circuits/spike-mlp/MANIFEST.md` |
| R:76 | 60 s, 300 s; 10 minutes, 24 hours | `src/ChannelSettlement.sol`; `README.md` (reasons) |
| R:96 | 160 bits; 2^160; 2^80 | `src/AuthCaptureProofOperator.sol` `termsAuthorizer`; derivation in `docs/spec-notes.md` |
| R:120, R:136 | chain id 84532 | `deployments/base-sepolia.json` |
| R:136–146 | addresses; verifyGas 600,000 and 660,000; 766,226; 839,705; 860,315 gas | `deployments/base-sepolia.json`; `script/DeployBaseSepolia.s.sol`; `measurements/2026-11-24-testnet/README.md` |
| R:154–159 | 768,174; 841,293; 113,661; 71,066; 895,250; 836,981; 899,361; 841,355; 769,210; 797,428 | `MEASUREMENTS.md` and the tests named there |

## Open points for the review

- **The reserved type.** P assumes two changes to `auth-capture`'s `"policy"` appendix: a status word instead of a `bool`, and a `policyData` parameter and payload field. Neither is agreed.
- **Clients.** No client derives the salt nonce from the terms yet; rows 23 and 24 are spec only for the policy route.
- **Facilitator.** Rows 15, 21 and 22 have no implementation.
- **`batch-settlement`.** B is a proposal with a prototype; its open points are listed in B.
