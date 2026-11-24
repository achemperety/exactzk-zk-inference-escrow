# Cases ported from the V1 solo suite

The previous version's solo suite (`ZkInferenceEscrow.t.sol`, 22 test functions) is ported here case by case, once for each solo flow: the one-transaction flow (`test/SoloSettlementOneTransaction.t.sol`) and the escrow flow (`test/SoloSettlementEscrow.t.sol`). A ported test is named `test_v1_NN_…` after the V1 case number. A case that no longer applies to a flow has a one-line reason.

Some V1 checks are now done by the proof itself. In V1 the input commitment and the instance count were compared with stored values before the verifier ran. In v3 the commitment comes from the payer-signed terms and the adapter builds the instance array, so a mismatch shows up as an invalid proof (`ProofInvalid`) instead of a separate error.

| # | V1 test | One-transaction flow | Escrow flow |
|---|---|---|---|
| 1 | `test_settle_valid_proof` | `test_v1_01_valid_proof_pays_the_provider_in_one_transaction` | `test_v1_01_open_locks_and_a_valid_proof_releases_to_the_provider` |
| 2 | `test_settle_wrong_commitment_reverts` | `test_v1_02_terms_with_another_input_commitment_are_proof_invalid` | `test_v1_02_terms_with_another_input_commitment_are_proof_invalid` |
| 3 | `test_settle_tampered_instance_array_reverts` | `test_v1_03_changed_output_is_proof_invalid` | `test_v1_03_changed_output_is_proof_invalid` |
| 4 | `test_settle_bad_proof_reverts` | `test_v1_04_changed_proof_is_proof_invalid` | `test_v1_04_changed_proof_is_proof_invalid` |
| 5 | `test_refund_after_deadline` | Does not apply: nothing is locked, so there is nothing to refund. Case 11 shows the payer is not charged after the deadline. | `test_v1_05_anyone_refunds_the_payer_after_prove_by` |
| 6 | `test_settle_after_refund_reverts` | Does not apply: there is no refund in this flow. | `test_v1_06_release_after_refund_reverts` |
| 7 | `test_refund_after_settle_reverts` | `test_v1_07_refund_cannot_reach_a_one_transaction_payment` | `test_v1_07_refund_after_release_reverts` |
| 8 | `test_double_settle_reverts` | `test_v1_08_the_same_authorization_cannot_settle_twice` | `test_v1_08_second_release_reverts` |
| 9 | `test_open_replay_reverts` | `test_v1_09_a_one_transaction_authorization_cannot_open_an_escrow` (there is no `open` in this flow; the nearest replay is this authorization used to open one) | `test_v1_09_second_open_with_the_same_terms_reverts` |
| 10 | `test_refund_before_deadline_reverts` | Does not apply: there is no refund in this flow. | `test_v1_10_refund_up_to_and_at_prove_by_reverts` |
| 11 | `test_settle_past_deadline_reverts` | `test_v1_11_settle_after_prove_by_reverts_and_charges_nothing` | `test_v1_11_release_after_prove_by_reverts` |
| 12 | `test_settle_wrong_instance_count_reverts` | `test_v1_12_output_of_the_wrong_length_is_proof_invalid` | `test_v1_12_output_of_the_wrong_length_is_proof_invalid` |
| 13 | `test_open_past_prove_by_reverts` | `test_v1_13_terms_that_expired_before_submission_revert` | `test_v1_13_open_with_prove_by_not_in_the_future_reverts` |
| 14 | `test_gas_open_only` | `SoloGasFirstTest`, `SoloGasSteadyTest` (`test/SoloSettlementGas.t.sol`) | the same, plus `SoloGasReleaseFirstTest` and `SoloGasReleaseSteadyTest` |
| 15 | `test_erc8004_settle_writes_response_100` | Does not apply: settlement no longer writes to an ERC-8004 registry; that moves to a separate validator contract. | Same reason. |
| 16 | `test_erc8004_refund_writes_response_0` | Does not apply, as 15. The behaviour is also dropped on purpose: a missed deadline is not a failed validation, so the validator will write 0 only for a contradicting proof. | Same reason. |
| 17 | `test_erc8004_registry_failure_does_not_block_settle` | Does not apply: settlement makes no outside call that could fail independently of the payment (only the verifier registry, the adapter, the verifier and the token). | Same reason. |
| 18 | `test_erc8004_registry_failure_does_not_block_refund` | Does not apply, as 17. `refund` calls only the token. | Same reason. |
| 19 | `testCloseRace_ClientStealsInference` | Does not apply: channel case, ported with the channel close machinery. | Same reason. |
| 20 | `testSettleDuringDraining` | Does not apply: channel case, ported with the channel close machinery. | Same reason. |
| 21 | `testIntake_RejectsShortProveBy` | Does not apply: channel case, ported with the channel close machinery. | Same reason. |
| 22 | `testProveByBound_ExploitViaShortNotice` | Does not apply: channel case, ported with the channel close machinery. | Same reason. |

Ported: 11 cases in the one-transaction flow and 14 in the escrow flow, counting case 14 as the gas suites. Cases 15 to 22 apply to neither solo flow.

## Added beyond the V1 cases

- `test/SoloSettlementReplay.t.sol`: the replay matrix, 15 tests in five rows.
- Both flows: ERC-1271 payers (accepted, and refused when the wallet says no); a token whose `transfer` returns `false`; an authorization for one flow refused by the other.
- One-transaction suite: every field of the terms is covered by the signature; a signature by someone other than the payer; entries that are not the registered one, an unknown verifier, a wrong-sized output or a multi-lane entry refused even by an adapter that accepts anything; too little gas surfaces as a typed error, not as an invalid proof.
- Escrow suite: a lock whose verifier's code changes cannot be released and can still be refunded; changed terms name a lock that was never opened; a token that re-enters during `release` or `refund` cannot pay twice.
- `test/SoloSettlementFork.t.sol`: the same flows against the testnet's real USDC on a fork, opt-in.

# Cases ported from the V1 batch suite

The previous version's batch suite (`ZkChannelBatch.t.sol`, 15 test functions, real K=8 proof) is ported to `test/ChannelSettlement.t.sol`. A ported test is named `test_v1_NN_…` after the V1 case number.

What changed underneath the cases: a channel's terms are no longer stored but passed with each batch and hashed into the channel id; frames no longer carry the input commitment or the cumulative amount (the voucher signature covers both, and the contract takes them from the proof's public inputs and from storage); skip reasons are one result byte per lane in `BatchSettled` instead of strings; and a batch in which no lane settles reverts with every lane's result instead of succeeding and paying nothing.

| # | V1 test | v3 test | Change |
|---|---|---|---|
| 1 | `test_open_channel_state` | `test_v1_01_open_stores_the_deposit_in_one_slot_and_pulls_it` | Also checks that opening writes exactly one storage slot. |
| 2 | `test_open_channel_duplicate_reverts` | `test_v1_02_opening_the_same_config_twice_reverts` | `ChannelExists(id)` instead of a string. |
| 3 | `test_close_channel` | `test_v1_03_request_close_then_finalize_returns_the_deposit` (`test/ChannelClose.t.sol`) | V1 waited a notice period derived from the prove window; v3 waits the channel's own challenge window, and anyone may finalize. The payer gets the whole deposit back and the channel ends `Closed`. |
| 4 | `test_settle_batch_full_8lanes` | `test_v1_04_a_k8_batch_settles_all_eight_lanes` | The provider's share accrues; no token moves until it withdraws. |
| 5 | `test_settle_batch_dummy_slot` | `test_v1_05_a_padding_lane_is_reported_and_not_paid` | The padding value is the registry entry's `emptyLane`; the padding lane has no frame and is reported as `Padding`. |
| 6 | `test_settle_batch_tampered_frame_commitment_skipped` | `test_v1_06_a_voucher_signed_for_another_commitment_is_skipped` | The frame has no commitment to tamper with; the nearest case is a voucher signed for another commitment, reported as `BadSignature`. |
| 7 | `test_settle_batch_bad_sig_skipped` | `test_v1_07_a_corrupted_voucher_signature_is_skipped` | `BadSignature`. |
| 8 | `test_settle_batch_replay_all_skipped` | `test_v1_08_resubmitting_a_settled_batch_reverts_and_names_every_lane` | Inverted on purpose: V1 accepted a batch that paid nothing; v3 reverts with `NothingSettled`, every lane `WrongSeq`, so a batch never succeeds without paying. |
| 9 | `test_settle_batch_invalid_proof_reverts` | `test_v1_09_an_invalid_proof_reverts` | `ProofInvalid`. |
| 10 | `test_settle_solo_escape_hatch` | `test_v1_10_the_solo_proof_settles_one_voucher_through_the_channels_solo_entry` | No separate function: the channel's verifier set includes the solo entry, and `settleBatch` with that one-lane entry is the escape hatch. |
| 11 | `test_settle_solo_replay_reverts` | `test_v1_11_resubmitting_the_solo_settlement_reverts` | `NothingSettled` with `WrongSeq`. |
| 12 | `test_settle_batch_expired_frame_skipped` | `test_v1_12_an_expired_voucher_is_skipped` | `Expired`. |
| 13 | `test_settle_batch_insufficient_balance_skipped` | `test_v1_13_a_voucher_above_the_balance_is_skipped` | V1 emptied the channel by closing it; here the channel is opened with less than one voucher's amount. `InsufficientBalance`. |
| 14 | `test_open_channel_unregistered_model_reverts` | `test_v1_14_a_verifier_that_is_not_registered_settles_nothing_until_anyone_registers_it` | Opening no longer checks: a channel signs a hash of content-addressed verifier ids, so an id can be registered later by anyone and means the same circuit. The test shows the batch reverting with `VerifierUnavailable` until the entry is registered, and settling after. |
| 15 | `test_register_model_non_owner_reverts` | Does not apply: there is no owner. Registration is permissionless and entries never change; `test/VerifierRegistry.t.sol` covers re-registration and code-hash checks. | |

Ported: 14 of 15 (case 3 with the close functions, in `test/ChannelClose.t.sol`); case 15 has no counterpart.

## Added beyond the V1 batch cases

- Four cases required for this version: a voucher for one channel cannot settle in another; a frame against an entry outside its channel's verifier set is skipped as `VerifierNotAllowed`; a batch mixing settled and skipped lanes reports every lane (two batches covering all ten results); an ERC-1271 payer's voucher is accepted, and a wrong contract signature (another signer, or a wallet that says no) is refused.
- Vouchers: a single-channel batch settles eight vouchers in order; vouchers of one channel settle only in sequence; the cumulative amount must continue from the accounted total; `proveBy` is inclusive and bounded by the channel's `proveWindow`; a voucher signed for another chain or contract is refused; a channel is unknown on another chain, and a channel opened there uses that chain's voucher domain; a zero commitment is not padding when the entry declares none; the same proof settles later vouchers that name the same commitments (by design).
- Opening: window minimums; zero or oversized deposits and a zero provider; the deposit authorization binds the config, the chain and the contract; an ERC-1271 payer opens through the token, and a refusing wallet cannot.
- The batch call: a lane whose channel pays in another asset than the batch's is skipped as `OtherProvider`, and settles in a batch of its own asset; a set index outside the set; an entry that is not the named verifier's; frames that do not parse; too little gas for the verifier is a typed error; a settled lane writes only its channel's slot, and the batch one accrual.
- Withdrawing: the provider withdraws what accrued and no more; a token that reports failure; a token that re-enters cannot withdraw twice.
- `test/ChannelSettlementFork.t.sol`: the same contract against the testnet's real USDC on a fork, opt-in.

# Cases ported from the V2 channel and integration suites

The previous version's channel suite (`ZkChannelV2.t.sol`, 15 test functions) and integration suite (`ZkInferenceEscrowV2Integration.t.sol`, 9) are ported to `test/ChannelClose.t.sol`, named `test_v2_…` and `test_it…` after the V2 groups. They use two registered entries whose verifier accepts every proof (one lane and four lanes), behind the real EZKL adapter, so a test can choose its own commitments; V2 used a mock verifier the same way.

What changed underneath the cases: closing has a fourth state, `Held`, for a channel finalized with a hold; the hold ends `proveWindow` seconds after the challenge window, never at a time the voucher chooses; the amount held is the challenge's claimed cumulative amount less what has been accounted since, so every voucher that settles or is waived shrinks it; failures are typed errors; and waiving accepts only the channel's next voucher, including one that has expired, since vouchers settle strictly in sequence.

## Channel suite (`ZkChannelV2.t.sol`)

| # | V2 test | v3 test | Change |
|---|---|---|---|
| G1.1 | `testG1_CumAmountSigningAndPersistence` | `test_v2_g1_cumulative_amount_persists_across_batches` | The cumulative amount is not in the frame; it is accounted + amount, checked through the signature. |
| G1.2 | `testG1_SameChannelTwoFramesOneCall` | `test_v2_g1_two_vouchers_of_one_channel_settle_in_one_batch` | |
| G1.3 | `testG1_WrongCumAmountSkipped` | `test_v2_g1_a_voucher_signed_with_a_wrong_cumulative_amount_is_skipped` | The lane reads `BadSignature`; as the batch's only lane it makes the batch revert with `NothingSettled`, where V2 succeeded and paid nothing. |
| G2.1 | `testG2_WaiveAdvancesAccountedCum` | `test_v2_g2_waive_advances_seq_and_accounted_and_the_next_voucher_settles` | `waive` instead of `waiveSolo`; no model id. |
| G2.2 | `testG2_ThirdPartyCannotWaive` | `test_v2_g2_only_the_provider_can_waive` | Also refuses the payer. `NotProvider`. |
| G2.3 | `testG2_WaiveWrongCumAmountReverts` | `test_v2_g2_waive_with_a_wrong_cumulative_amount_reverts` | `CumAmountMismatch(expected)`. |
| G3.1 | `testG3_FullChallengeClosePath` | `test_v2_g3_request_challenge_finalize_sweep` | The hold ends at `closingAt + proveWindow`, not at the voucher's `proveBy` plus a margin. Finalize and sweep are open to anyone; the channel goes `Closing`, `Held`, `Closed`. |
| G3.2 | `testG3_NoChallengeFullRefund` | `test_v2_g3_without_a_challenge_finalize_returns_everything` | |
| G3.3 | `testG3_MultipleChallengesHigherWins` | `test_v2_g3_a_higher_challenge_raises_the_claim_and_a_lower_one_reverts` | V2 ignored a lower challenge; v3 reverts it with `NoNewClaim`. |
| G3.4 | `testG3_ChallengeAlreadySettledReverts` | `test_v2_g3_a_challenge_with_a_settled_voucher_reverts` | A settled sequence number reverts as `WrongSeq`; a later one that claims nothing new reverts with `NoNewClaim`. |
| G3.5 | `testG3_ExactClosingAtBoundary` | `test_v2_g3_at_closing_at_the_challenge_reverts_and_finalize_works` | |
| G3.6 | `testG3_ExactHoldExpiryBoundary` | `test_v2_g3_at_hold_expiry_the_sweep_reverts_and_a_second_later_it_works` | |
| G3.7 | `testG3_InsufficientBalancePartialHold` | `test_v2_g3_the_hold_is_capped_at_the_balance` | The channel is opened small instead of drained by 48 settlements. |
| G3.8 | `testG3_SettleDuringDraining` | `test_v2_g3_vouchers_settled_while_closing_shrink_the_hold` | Inverted on purpose: V2 kept the hold at its challenge-time amount after three of five held vouchers settled, locking three units of the payer's free balance until the hold expired. In v3 the hold shrinks to two, and settling the last two closes the channel. |
| G4 | `testG4_HotPathGasBaseline` | Not a functional test here: the gas of opening and of a K=8 batch is pinned in `test/ChannelSettlementGas.t.sol`, and of every close function in `test/ChannelCloseGas.t.sol`. | |

## Integration suite (`ZkInferenceEscrowV2Integration.t.sol`)

| # | V2 test | v3 test | Change |
|---|---|---|---|
| IT1.1 | `testIT1_ModelRegisteredCorrectly` | `test_register_stores_the_entry_and_emits_it` (`test/VerifierRegistry.t.sol`) | Covered by the registry suite: there is no model record, only registry entries. |
| IT1.2 | `testIT1_UnregisteredModelRejected` | `test_v1_14_a_verifier_that_is_not_registered_settles_nothing_until_anyone_registers_it` (`test/ChannelSettlement.t.sol`) | Opening does not check registration; the batch does. |
| IT1.3 | `testIT1_ChannelStateAfterMigrationOpen` | `test_it1_a_new_channel_has_its_deposit_and_no_close_state` | The config is not stored; the test reads the hot slot's fields, the close state, and that the cold slot is untouched. |
| IT1.4 | `testIT1_ReRegisterModelUpdates` | `test_it1_re_pointing_a_verifier_is_impossible` | Inverted on purpose: V2's owner could point a model at other verifier contracts. Here the same code at another address has the same id and cannot be registered again; a batch cannot pass the moved entry under the registered id (`VerifierUnavailable`); other code is another id, which the channel's verifier set does not name (`VerifierNotAllowed`); and the entry still settles as registered. |
| IT2.1 | `testFuzz_SigmaTransfersInvariant` | `testFuzz_it2_the_provider_is_paid_exactly_the_settled_vouchers` | Also withdraws and checks the provider's token balance. The stateful suite `test/ChannelInvariant.t.sol` extends the property to random sequences of every function. |
| IT2.2 | `testFuzz_SigmaTransfersInvariant_WithChallengeClose` | `testFuzz_it2_with_a_challenge_close` | Also checks paid + returned = deposit and that the channel ends `Closed`. |
| IT3.1 | `testIT3_MixedBatch_AllLaneTypes` | `test_it3_a_mixed_batch_settles_open_and_closing_channels_and_reports_the_rest` | The lane results are read from `BatchSettled`: settled, settled, `Expired`, `Padding`. |
| IT3.2 | `testIT3_DrainingChannelFinalizableAfterBatchSettle` | `test_it3_a_closing_channel_settled_in_a_batch_finalizes_with_the_rest` | |
| IT3.3 | `testIT3_MixedBatch_HeldLaneInsideBatch` | `test_it3_a_challenged_channel_settles_in_a_batch_and_its_hold_shrinks` | Inverted on purpose, as for G3.8: V2 returned 94 of the remaining 99 and kept the settled unit in the hold; v3 returns 95. |

Ported: 24 of 24. One maps to an existing registry test, one to an existing batch test, and G4 to the gas suites; the other 21 are new tests.

## Added beyond the V2 cases (`test/ChannelClose.t.sol`, `test/ChannelInvariant.t.sol`)

- Behaviour that, before the close functions existed, only the gas pins could notice: a closing channel settles vouchers, and refuses a second close request, a sweep, and finalization before its window ends; a cumulative amount that would need more than 96 bits (reachable by waiving a voucher of 2^96 - 1) never settles, even with a signature over that word, and cannot be waived past either.
- Holds and windows: the hold ends at `closingAt + proveWindow` whatever the presented voucher's `proveBy`; a challenge refuses an expired voucher and one beyond the prove window, and accepts one at the window's edge; a challenge needs the payer's signature and the provider; finalizing after the hold expired returns everything; a held channel refuses a challenge, a close request and a second finalization.
- Waiving: an expired voucher and one above the balance can be waived; only the next voucher, signed by the payer; after finalization, waiving returns what it releases to the payer and closes the channel when nothing is left; while closing, waiving shrinks the hold without paying; after the hold expired it reverts.
- Closed and unknown channels: a closed channel accepts nothing (no lane, waive, challenge, close request, finalization, sweep or reopening, and its two storage slots stay as they were); every close function reverts for a config that was never opened.
- Edge cases: a batch built before the close request still settles; a batch landing after finalization settles only against a hold; a challenge in the last second of the window; at the hold's expiry a held voucher still settles and a second later it does not; waiving a settled voucher reverts; finalizing twice reverts, with and without a hold; a smart-wallet payer closes its channel through its own account, the provider's challenge carries the wallet's ERC-1271 signature, and a wallet that stops accepting cannot be held against.
- Paying back: finalization and the sweep write their state before paying (a re-entering token cannot finalize or sweep twice); finalization reverts when the token reports failure.
- Stateful invariants over random sequences of all eight functions and time jumps: tokens are conserved to the unit; no channel pays out more than its deposit; sequence numbers and accounted amounts never decrease; a closed channel accepts nothing; states only move forward and a held channel holds exactly its balance.
- `test/ChannelSettlementFork.t.sol`: every close function against the testnet's real USDC on a fork, opt-in, and a smart wallet closing a USDC channel.

# Cases carried over from the previous validation-registry suite

The previous version tested its ERC-8004 integration against a mock Validation Registry of its own (`MockValidationRegistry.t.sol`, 11 test functions). That mock let anyone open a request and had a lookup for the response URI that the ERC does not define. It is replaced by the ERC authors' own registries, built from source (`test/external/README.md`), and the properties that still mean something are tested through `ProofValidator8004` in `test/ProofValidator8004.t.sol`.

| # | Previous test | Now | Notes |
|---:|---|---|---|
| 1 | `test_pg3_progressive_response_updates_lastUpdate` | `test_respond_is_open_to_anyone_and_repeatable` | A second answer rewrites the record and moves `lastUpdate`. |
| 2 | `test_pg3_progressive_response_counted_once_in_summary` | `test_respond_is_open_to_anyone_and_repeatable` | One request is counted once, however often it is answered. |
| 3 | `test_pg3_getSummary_filters_by_tag_and_attester` | `test_the_summary_is_pulled_down_only_by_a_proven_contradiction`, `test_a_summary_filtered_to_this_validator_ignores_other_validators` | Filtering by validator and by tag. Added: a tag is no protection, because any validator can write the same tag; only the validator filter is. |
| 4 | `test_pg3_explicit_zero_distinguishable_from_no_response` | `test_an_invalid_proof_writes_nothing_whatever_the_claim`, `test_a_valid_proof_of_another_output_is_answered_0` | Changed: in the reference registry `lastUpdate` is the time of the request until the first answer, so it no longer tells "not answered" from "answered 0". For this validator's answers the tag and the response hash do: an unanswered request has an empty tag and a zero hash. |
| 5 | `test_pg3_explicit_zero_counted_in_summary_pending_not` | `test_the_summary_is_pulled_down_only_by_a_proven_contradiction` | A proven contradiction (0) counts; requests nobody answered, and requests whose proofs failed, do not. |
| 6 | `test_gap1_overwriting_a_responded_to_request_reverts` | `test_a_request_recorded_for_another_agent_is_not_answered` | Stricter now: a request is answered only if the registry recorded the agent its hash commits to. |
| 7 | `test_gap1_request_mutable_before_any_response` | Does not apply | The reference registry never lets a request be opened again. |
| 8–11 | `test_getResponseURI_…` (four tests) | Do not apply | The reference registry has no response-URI lookup; the URI is only in the event. The validator writes an empty URI: the response hash is the claim's digest, and the output is in the transaction's calldata. |

## Added beyond the previous cases (`test/ProofValidator8004.t.sol`, `test/ProofEvaluator8183.t.sol`)

- Caller rules of the reference registry: a request opened by anyone but the agent's owner, an operator for all its tokens, or the address approved for that token is refused; so is a request for an agent that does not exist; a request naming another validator is not answered by this one.
- The request hash: the typed hash of the request, bound to the chain and the validator's address; every argument is part of it; answering a request nobody opened reverts before any proof is checked.
- ERC-8183: every acceptance check of the evaluator against the reference job contract (valid proof completes and pays the provider the budget and the evaluator fee; invalid or uncheckable proofs revert and change nothing; no completion at or after `expiredAt`; only the provider forfeits; nobody can end a job with a garbage proof; terms set once, by the client, while Open), plus the job contract's own departures from the ERC's text where they meet the evaluator.
