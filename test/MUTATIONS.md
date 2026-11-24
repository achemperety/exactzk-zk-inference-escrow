# Mutation record

A property test is accepted here only after it has been seen to fail against a deliberately broken version of what it guards. This file records each breakage, the tests that caught it and the message they failed with. Every mutation was applied to a clean tree, run with `forge test`, and reverted.

To repeat one, make the change described, run `forge test`, and undo it.

## Fixtures and baseline (`test/FixtureBaseline.t.sol`)

Run on 2026-11-22. The suite has 9 tests; all pass on the clean tree.

| Id | Deliberate breakage | Tests that failed | Failure |
|---|---|---|---|
| FB1 | One hex digit of the stored solo proof changed (`test/fixtures/Fixtures.sol`) | `test_solo_proof_verifies_on_generated_verifier`, `test_verifier_gas_baseline_solo` | `EvmError: Revert` in both |
| FB2 | One hex digit of the K=8 verifier bytecode changed (`test/fixtures/FixturesK8.sol`) | `test_k8_proof_verifies_on_generated_verifier`, `test_verifier_gas_baseline_k8`, `test_pinned_bytecode_hashes` | `EvmError: Revert`; `K=8 verifier bytecode changed: 0x8c49… != 0x471c…` |
| FB3 | One hex digit of `test/fixtures/verifier_runtime.hex` changed | `test_pinned_bytecode_hashes` | `verifier_runtime.hex differs from Fixtures.sol: 0xe21c… != 0x8cd0…` |
| FB4 | Solo verifier replaced by code that returns `true` for any input (`vm.etch(SOLO, hex"600160005260206000f3")` in `setUp`) | `test_tampered_proof_is_rejected`, `test_wrong_output_is_rejected`, `test_proof_for_one_circuit_fails_on_the_other`, `test_pinned_bytecode_hashes`, `test_verifier_gas_baseline_solo` | `assertion failed` (three times); `solo verifier bytecode changed`; `solo verifyProof gas moved: 18 != 577544` |
| FB5 | K=8 fixture made to claim that outputs start at instance 9 (`OUT_BASE = 9`) | `test_instance_layout` | `assertion failed: 9 != 8` |
| FB6 | Tests run under the Cancun gas schedule (`evm_version = "cancun"`) | `test_verifier_gas_baseline_solo`, `test_verifier_gas_baseline_k8` | `solo verifyProof gas moved: 569447 != 577544`; `K=8 verifyProof gas moved: 627710 != 635807` |

Every one of the 9 tests appears in the third column at least once.

FB6 is also a finding: the difference is exactly 8,097 gas, three modexp calls repriced from 1,349 to 4,048 each. The baseline figures 577,544 and 635,807 are therefore Osaka-schedule figures. On a chain that still prices modexp the older way, the same verification costs 569,447 and 627,710.

## Proof-system core (`src/`, tests in `test/Halo2EzklAdapter.t.sol`, `test/VerifierRegistry.t.sol`, `test/ProofCheck.t.sol`)

Run on 2026-11-22. The three suites have 58 tests; with the 9 fixture tests the whole suite is 67, and all pass on the clean tree. 61 mutations were run, each against the whole suite. 58 were caught. Every one of the 67 tests fails under at least one mutation recorded in this file.

### `src/Halo2EzklAdapter.sol`

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| A1 | Field check removed | 2: `test_canonical_boundary`, `test_noncanonical_word_rejected_at_every_position` |
| A2 | A word equal to the modulus passes (word-by-word loop) | 1: `test_canonical_boundary` |
| A3 | Word-by-word loop stops one word early | 2: `test_canonical_boundary`, `test_noncanonical_word_rejected_at_every_position` |
| A4 | Eight-word pass checks seven words | 1: `test_noncanonical_word_rejected_at_every_position` |
| A5 | Outputs written before commitments | 6: `test_calldata_is_the_abi_encoding_of_verifyProof`, `test_k8_fixture_is_valid`, `test_k8_fixture_verifies_through_adapter`, `test_no_gas_amount_turns_a_valid_real_proof_invalid`, `test_solo_fixture_is_valid`, `test_solo_fixture_verifies_through_adapter` |
| A6 | Instance count omits the outputs | 14: `test_adapter_overhead_k8_target_cold`, `test_adapter_overhead_k8_target_warm`, `test_adapter_overhead_solo_target_cold`, `test_adapter_overhead_solo_target_warm`, `test_calldata_is_the_abi_encoding_of_verifyProof`, `test_check_overhead_k8`, `test_check_overhead_k8_by_id`, `test_check_overhead_solo`, `test_check_overhead_solo_by_id`, `test_k8_fixture_is_valid`, `test_k8_fixture_verifies_through_adapter`, `test_no_gas_amount_turns_a_valid_real_proof_invalid`, `test_solo_fixture_is_valid`, `test_solo_fixture_verifies_through_adapter` |
| A7 | Wrong function selector | 14: `test_adapter_overhead_k8_target_cold`, `test_adapter_overhead_k8_target_warm`, `test_adapter_overhead_solo_target_cold`, `test_adapter_overhead_solo_target_warm`, `test_calldata_is_the_abi_encoding_of_verifyProof`, `test_check_overhead_k8`, `test_check_overhead_k8_by_id`, `test_check_overhead_solo`, `test_check_overhead_solo_by_id`, `test_k8_fixture_is_valid`, `test_k8_fixture_verifies_through_adapter`, `test_no_gas_amount_turns_a_valid_real_proof_invalid`, `test_solo_fixture_is_valid`, `test_solo_fixture_verifies_through_adapter` |
| A8 | Shape check removed | 1: `test_shape_mismatch_returns_false` |
| A9 | Zero lanes accepted | 1: `test_shape_mismatch_returns_false` |
| A10 | Target's return data ignored | 2: `test_failing_targets_return_false`, `test_misbehaving_targets_behind_the_ezkl_adapter_never_give_valid` |
| A11 | Target's success flag ignored | 2: `test_failing_targets_return_false`, `test_misbehaving_targets_behind_the_ezkl_adapter_never_give_valid` |
| A12 | Target's return size not checked | 2: `test_failing_targets_return_false`, `test_misbehaving_targets_behind_the_ezkl_adapter_never_give_valid` |
| A13 | Any non-zero return word accepted | 2: `test_failing_targets_return_false`, `test_misbehaving_targets_behind_the_ezkl_adapter_never_give_valid` |
| A14 | Proof-system tag changed | 3: `test_id_is_computed_from_content`, `test_proof_system_tag`, `test_same_code_at_other_addresses_cannot_replace_an_entry` |
| A15 | Adapter says yes whatever the target answers | 11: `test_failing_targets_return_false`, `test_lanes_swapped_returns_false`, `test_misbehaving_targets_behind_the_ezkl_adapter_never_give_valid`, `test_proof_checked_against_the_other_circuit_is_invalid`, `test_real_verifier_out_of_gas_returns_false_without_reverting`, `test_tampered_proof_is_invalid_and_does_not_revert`, `test_tampered_proof_returns_false`, `test_target_that_burns_all_gas_returns_false_without_reverting`, `test_wrong_commitment_returns_false`, `test_wrong_output_is_invalid_and_does_not_revert`, `test_wrong_output_returns_false` |
| A16 | Proof not padded to a whole word | 1: `test_calldata_is_the_abi_encoding_of_verifyProof` |
| A17 | Adapter reverts when the target fails | 7: `test_failing_targets_return_false`, `test_lanes_swapped_returns_false`, `test_real_verifier_out_of_gas_returns_false_without_reverting`, `test_tampered_proof_returns_false`, `test_target_that_burns_all_gas_returns_false_without_reverting`, `test_wrong_commitment_returns_false`, `test_wrong_output_returns_false` |
| A18 | Field check run twice (wasted gas) | 8: `test_adapter_overhead_k8_target_cold`, `test_adapter_overhead_k8_target_warm`, `test_adapter_overhead_solo_target_cold`, `test_adapter_overhead_solo_target_warm`, `test_check_overhead_k8`, `test_check_overhead_k8_by_id`, `test_check_overhead_solo`, `test_check_overhead_solo_by_id` |
| A19 | Compiler set to 200 optimizer runs | 8: `test_adapter_overhead_k8_target_cold`, `test_adapter_overhead_k8_target_warm`, `test_adapter_overhead_solo_target_cold`, `test_adapter_overhead_solo_target_warm`, `test_check_overhead_k8`, `test_check_overhead_k8_by_id`, `test_check_overhead_solo`, `test_check_overhead_solo_by_id` |
| A20 | Padding word of the proof not cleared | **none: survived, see below** |
| A21 | Scratch word not cleared before the call | **none: survived, see below** |

A19 is a change to `foundry.toml`, not to the adapter: at 200 optimizer runs the compiler stops writing the 32-byte field modulus out in full and the K=8 overhead rises from 5,441 to 8,023.

### `src/VerifierRegistry.sol`

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| R1 | An existing id can be registered again | 2: `test_registering_the_same_entry_again_reverts`, `test_same_code_at_other_addresses_cannot_replace_an_entry` |
| R2 | Code hash not compared at registration | 2: `test_wrong_adapter_code_hash_reverts`, `test_wrong_target_code_hash_reverts` |
| R3 | Account without code accepted | 1: `test_account_without_code_reverts` |
| R4 | Delegated account accepted | 1: `test_delegated_account_reverts` |
| R5 | Adapter code hash left out of the id | 5: `test_always_true_adapter_is_valid_and_always_false_is_invalid`, `test_always_true_and_always_false_adapters_have_distinct_ids`, `test_every_field_but_the_addresses_changes_the_id`, `test_id_is_computed_from_content`, `test_same_code_at_other_addresses_cannot_replace_an_entry` |
| R6 | Gas allowance left out of the id | 5: `test_always_true_and_always_false_adapters_have_distinct_ids`, `test_every_field_but_the_addresses_changes_the_id`, `test_gas_allowance_is_part_of_the_id`, `test_id_is_computed_from_content`, `test_same_code_at_other_addresses_cannot_replace_an_entry` |
| R7 | Target code hash left out of the id | 4: `test_always_true_and_always_false_adapters_have_distinct_ids`, `test_every_field_but_the_addresses_changes_the_id`, `test_id_is_computed_from_content`, `test_same_code_at_other_addresses_cannot_replace_an_entry` |
| R8 | Key hash left out of the id | 4: `test_always_true_and_always_false_adapters_have_distinct_ids`, `test_every_field_but_the_addresses_changes_the_id`, `test_id_is_computed_from_content`, `test_same_code_at_other_addresses_cannot_replace_an_entry` |
| R9 | Lane count left out of the id | 4: `test_always_true_and_always_false_adapters_have_distinct_ids`, `test_every_field_but_the_addresses_changes_the_id`, `test_id_is_computed_from_content`, `test_same_code_at_other_addresses_cannot_replace_an_entry` |
| R10 | Output size left out of the id | 4: `test_always_true_and_always_false_adapters_have_distinct_ids`, `test_every_field_but_the_addresses_changes_the_id`, `test_id_is_computed_from_content`, `test_same_code_at_other_addresses_cannot_replace_an_entry` |
| R11 | Proof system left out of the id | 4: `test_always_true_and_always_false_adapters_have_distinct_ids`, `test_every_field_but_the_addresses_changes_the_id`, `test_id_is_computed_from_content`, `test_same_code_at_other_addresses_cannot_replace_an_entry` |
| R12 | Empty-lane marker left out of the id | 4: `test_always_true_and_always_false_adapters_have_distinct_ids`, `test_every_field_but_the_addresses_changes_the_id`, `test_id_is_computed_from_content`, `test_same_code_at_other_addresses_cannot_replace_an_entry` |
| R13 | Zero lanes accepted | 1: `test_zero_lanes_reverts` |
| R14 | Zero gas allowance accepted | 1: `test_zero_verify_gas_reverts` |
| R15 | Target hash accepted without a target | 1: `test_target_hash_without_target_reverts` |
| R16 | Entry hash stored wrongly | 17: `test_adapter_always_receives_its_full_allowance`, `test_adapter_cannot_spend_more_than_its_allowance`, `test_always_true_adapter_is_valid_and_always_false_is_invalid`, `test_arguments_that_do_not_fit_the_entry_are_invalid`, `test_check_overhead_k8`, `test_check_overhead_solo`, `test_insufficient_gas_reverts_with_a_typed_error`, `test_k8_fixture_is_valid`, `test_misbehaving_adapters_never_give_valid`, `test_misbehaving_targets_behind_the_ezkl_adapter_never_give_valid`, `test_no_gas_amount_turns_a_valid_real_proof_invalid`, `test_proof_checked_against_the_other_circuit_is_invalid`, `test_register_stores_the_entry_and_emits_it`, `test_same_code_at_other_addresses_cannot_replace_an_entry`, `test_solo_fixture_is_valid`, `test_tampered_proof_is_invalid_and_does_not_revert`, `test_wrong_output_is_invalid_and_does_not_revert` |
| R17 | Entry stored for a different id | 15: `test_always_true_adapter_is_valid_and_always_false_is_invalid`, `test_always_true_and_always_false_adapters_have_distinct_ids`, `test_arguments_that_do_not_fit_the_entry_are_invalid`, `test_check_overhead_k8_by_id`, `test_check_overhead_solo_by_id`, `test_gas_allowance_is_part_of_the_id`, `test_insufficient_gas_reverts_with_a_typed_error`, `test_k8_fixture_is_valid`, `test_misbehaving_adapters_never_give_valid`, `test_misbehaving_targets_behind_the_ezkl_adapter_never_give_valid`, `test_register_stores_the_entry_and_emits_it`, `test_same_code_at_other_addresses_cannot_replace_an_entry`, `test_solo_fixture_is_valid`, `test_tampered_proof_is_invalid_and_does_not_revert`, `test_wrong_output_is_invalid_and_does_not_revert` |
| R18 | Event carries the wrong adapter | 1: `test_register_stores_the_entry_and_emits_it` |
| R19 | Exists() always true | 1: `test_unknown_id_reads_as_empty` |
| R20 | Only the deployer may register | 2: `test_anyone_can_register`, `test_registering_the_same_entry_again_reverts` |
| R21 | Entry written to storage twice (wasted gas) | 1: `test_registration_gas` |

### `src/ProofCheck.sol`

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| P1 | Supplied entry not compared with the registered one | 1: `test_supplied_entry_that_is_not_the_registered_one_is_unverifiable` |
| P2 | Unknown id not refused when the entry is supplied | 1: `test_unknown_id_is_unverifiable` |
| P3 | Unknown id not refused when the entry is read | 1: `test_unknown_id_is_unverifiable` |
| P4 | Adapter code not re-checked on use | 1: `test_adapter_whose_code_changed_is_unverifiable` |
| P5 | Target code not re-checked on use | 2: `test_target_whose_code_changed_is_unverifiable`, `test_target_whose_code_was_removed_is_unverifiable` |
| P6 | Arguments not checked against the entry | 1: `test_arguments_that_do_not_fit_the_entry_are_invalid` |
| P7 | Lane count not checked against the entry | 1: `test_arguments_that_do_not_fit_the_entry_are_invalid` |
| P8 | Output length not checked against the entry | 1: `test_arguments_that_do_not_fit_the_entry_are_invalid` |
| P9 | Gas rule removed | 3: `test_adapter_always_receives_its_full_allowance`, `test_insufficient_gas_reverts_with_a_typed_error`, `test_no_gas_amount_turns_a_valid_real_proof_invalid` |
| P10 | Gas rule without the fixed margin | 1: `test_adapter_always_receives_its_full_allowance` |
| P11 | Gas rule without the 64/63 term | 1: `test_adapter_always_receives_its_full_allowance` |
| P12 | Adapter handed all remaining gas | 1: `test_adapter_cannot_spend_more_than_its_allowance` |
| P13 | Adapter's return data ignored | 6: `test_always_true_adapter_is_valid_and_always_false_is_invalid`, `test_misbehaving_adapters_never_give_valid`, `test_misbehaving_targets_behind_the_ezkl_adapter_never_give_valid`, `test_proof_checked_against_the_other_circuit_is_invalid`, `test_tampered_proof_is_invalid_and_does_not_revert`, `test_wrong_output_is_invalid_and_does_not_revert` |
| P14 | Adapter's success flag ignored | 1: `test_misbehaving_adapters_never_give_valid` |
| P15 | Adapter's return size not checked | 1: `test_misbehaving_adapters_never_give_valid` |
| P16 | Any non-zero return word accepted | 1: `test_misbehaving_adapters_never_give_valid` |
| P17 | Status order changed so that zero means Valid | 1: `test_zero_value_of_the_status_is_invalid` |
| P18 | Scratch word not cleared before the call | **none: survived, see below** |
| P19 | Check answers Valid without asking the adapter | 7: `test_adapter_cannot_spend_more_than_its_allowance`, `test_always_true_adapter_is_valid_and_always_false_is_invalid`, `test_misbehaving_adapters_never_give_valid`, `test_misbehaving_targets_behind_the_ezkl_adapter_never_give_valid`, `test_proof_checked_against_the_other_circuit_is_invalid`, `test_tampered_proof_is_invalid_and_does_not_revert`, `test_wrong_output_is_invalid_and_does_not_revert` |

### Survivors

Three mutations changed nothing that any test can observe. Each removes a line that is redundant by construction, kept as a second line of defence:

| Id | Line removed | Why no test can see it |
|---|---|---|
| A20 | The adapter clears the last word of the proof's padded region before copying the proof into it | The region is in memory the call frame has not used, which is zero already. The line matters only if code that writes memory is ever added before it. |
| A21 | The adapter clears its 32-byte return buffer before calling the target | The result is accepted only if the target returned exactly 32 bytes, and then the buffer has been overwritten in full. |
| P18 | The same clearing in `ProofCheck` before calling the adapter | Same reason. |

These lines are not covered by a test and are marked as defensive in the source.

### Not yet ported

The K=2 instance-layout canary from the previous test suite needs a K=2 fixture, which is not in this repository. `test_calldata_is_the_abi_encoding_of_verifyProof` pins the layout the adapter produces for one lane, two lanes and eight lanes.

## Solo settlement (`src/SoloSettlement.sol`, `ProofCheck.checkOne`, tests in `test/SoloSettlement*.t.sol`)

Run on 2026-11-23. Solo settlement adds 64 tests that run in CI (one-transaction flow 20, escrow flow 21, replay matrix 15, gas 8) and 10 opt-in tests against the testnet's USDC on a fork. With the 67 earlier tests the CI suite is 131 tests, all passing on the clean tree. 45 mutations were run against the whole suite and 5 more against the fork suite (`FORK_RPC_URL` set to the testnet's public endpoint, `FORK_BLOCK=62638490`). 49 were caught and one survived. Every one of the 74 new tests fails under at least one mutation recorded here.

Where a mutation broke more than six tests, the table gives the count, from forge's own summary line, and a few names.

### `src/SoloSettlement.sol`

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| S1 | settle: deadline not checked | 2: `test_v1_11_settle_after_prove_by_reverts_and_charges_nothing`, `test_v1_13_terms_that_expired_before_submission_revert` |
| S2 | settle: the last second (proveBy itself) refused | 1: `test_v1_11_settle_after_prove_by_reverts_and_charges_nothing` |
| S3 | both flows use one type, so an authorization fits either | 33 (including `setUp` of suites that open a lock there), among them `test_a_token_that_reenters_cannot_refund_twice`, `test_a_token_that_reenters_cannot_release_twice`, `test_a_token_whose_transfer_returns_false_cannot_release_or_refund` |
| S4 | request id carries a fixed chain id instead of block.chainid | 1: `test_row3_authorization_submitted_on_another_chain` |
| S5 | request id carries the registry address instead of this contract's | 44 (including `setUp` of suites that open a lock there), among them `test_a_token_that_reenters_cannot_refund_twice`, `test_a_token_that_reenters_cannot_release_twice`, `test_a_token_whose_transfer_returns_false_cannot_release_or_refund` |
| S6 | settle: proof not checked | 13, among them `test_entry_that_is_not_the_registered_one_is_unavailable`, `test_entry_with_more_than_one_lane_cannot_settle_a_solo_request`, `test_output_of_the_wrong_size_is_invalid_even_if_the_adapter_accepts_anything` |
| S7 | Unverifiable accepted as if valid | 6: `test_entry_that_is_not_the_registered_one_is_unavailable`, `test_if_the_verifier_code_changes_release_is_unavailable_and_refund_still_works`, `test_row4_always_true_entry_against_terms_naming_the_solo_circuit`, `test_row4_real_proof_with_the_solo_entry_against_terms_naming_another_entry`, `test_row4_solo_proof_against_terms_naming_the_k8_circuit`, `test_unknown_verifier_is_unavailable` |
| S8 | Unverifiable reported as ProofInvalid | 6: `test_entry_that_is_not_the_registered_one_is_unavailable`, `test_if_the_verifier_code_changes_release_is_unavailable_and_refund_still_works`, `test_row4_always_true_entry_against_terms_naming_the_solo_circuit`, `test_row4_real_proof_with_the_solo_entry_against_terms_naming_another_entry`, `test_row4_solo_proof_against_terms_naming_the_k8_circuit`, `test_unknown_verifier_is_unavailable` |
| S9 | settle pays the payer instead of payTo | 12, among them `test_every_field_of_the_terms_is_signed`, `test_gas_settle_first_payment_to_the_provider`, `test_gas_settle_steady` |
| S10 | settle keeps the payment in the contract | 13, among them `test_a_token_whose_transfer_returns_false_cannot_settle`, `test_every_field_of_the_terms_is_signed`, `test_gas_settle_first_payment_to_the_provider` |
| S11 | Settled event names the payer as recipient | 1: `test_v1_01_valid_proof_pays_the_provider_in_one_transaction` |
| S12 | open: deadline not checked | 1: `test_v1_13_open_with_prove_by_not_in_the_future_reverts` |
| S13 | open allowed at proveBy itself | 1: `test_v1_13_open_with_prove_by_not_in_the_future_reverts` |
| S14 | open: existing lock not refused | 3: `test_row1_escrow_authorization_used_again_after_release`, `test_row1_escrow_authorization_used_twice`, `test_v1_09_second_open_with_the_same_terms_reverts` |
| S15 | Opened event with amount 0 | 1: `test_v1_01_open_locks_and_a_valid_proof_releases_to_the_provider` |
| S16 | release: lock state not checked | 5: `test_a_token_that_reenters_cannot_release_twice`, `test_release_with_changed_terms_finds_no_lock`, `test_row5_release_after_refund`, `test_v1_06_release_after_refund_reverts`, `test_v1_08_second_release_reverts` |
| S17 | release: deadline not checked | 1: `test_v1_11_release_after_prove_by_reverts` |
| S18 | release: the last second refused | 1: `test_v1_11_release_after_prove_by_reverts` |
| S19 | release: deadline checked before lock state | 1: `test_v1_06_release_after_refund_reverts` |
| S20 | release: proof not checked | 9, among them `test_if_the_verifier_code_changes_release_is_unavailable_and_refund_still_works`, `test_row2_same_proof_second_request_other_commitment_escrow`, `test_row4_always_true_entry_against_terms_naming_the_solo_circuit` |
| S21 | release: state not recorded | 5: `test_a_token_that_reenters_cannot_release_twice`, `test_row5_refund_after_release`, `test_v1_01_open_locks_and_a_valid_proof_releases_to_the_provider`, `test_v1_07_refund_after_release_reverts`, `test_v1_08_second_release_reverts` |
| S22 | release: state recorded after paying | 1: `test_a_token_that_reenters_cannot_release_twice` |
| S23 | release pays the payer | 9, among them `test_a_token_that_reenters_cannot_release_twice`, `test_gas_release_first_payment_to_the_provider`, `test_gas_release_steady` |
| S24 | refund: lock state not checked | 4: `test_a_token_that_reenters_cannot_refund_twice`, `test_row5_refund_after_release`, `test_v1_07_refund_after_release_reverts`, `test_v1_07_refund_cannot_reach_a_one_transaction_payment` |
| S25 | refund: deadline not checked | 1: `test_v1_10_refund_up_to_and_at_prove_by_reverts` |
| S26 | refund allowed at proveBy itself | 1: `test_v1_10_refund_up_to_and_at_prove_by_reverts` |
| S27 | refund: state not recorded | 5: `test_a_token_that_reenters_cannot_refund_twice`, `test_if_the_verifier_code_changes_release_is_unavailable_and_refund_still_works`, `test_row5_release_after_refund`, `test_v1_05_anyone_refunds_the_payer_after_prove_by`, `test_v1_06_release_after_refund_reverts` |
| S28 | refund: state recorded after paying | 1: `test_a_token_that_reenters_cannot_refund_twice` |
| S29 | refund pays payTo | 7, among them `test_a_token_that_reenters_cannot_refund_twice`, `test_gas_refund_last_lock`, `test_gas_refund_steady` |
| S30 | _pay ignores the token's answer | 2: `test_a_token_whose_transfer_returns_false_cannot_release_or_refund`, `test_a_token_whose_transfer_returns_false_cannot_settle` |
| S31 | EscrowState zero value is Open | 38 (including `setUp` of suites that open a lock there), among them `test_a_token_that_reenters_cannot_refund_twice`, `test_a_token_that_reenters_cannot_release_twice`, `test_a_token_whose_transfer_returns_false_cannot_release_or_refund` |

### Gas pins (`test/SoloSettlementGas.t.sol`)

Each mutation adds one redundant event, which costs 1,125 to 4,947 gas. Every pin sits about 300 gas above its measurement.

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| G1 | settle emits Settled twice (gas) | 2: `test_gas_settle_first_payment_to_the_provider`, `test_gas_settle_steady` |
| G2 | open emits Opened twice (gas) | 2: `test_gas_open_first_lock_held_by_the_contract`, `test_gas_open_steady` |
| G3 | release emits Settled twice (gas) | 2: `test_gas_release_first_payment_to_the_provider`, `test_gas_release_steady` |
| G4 | refund emits Refunded twice (gas) | 2: `test_gas_refund_last_lock`, `test_gas_refund_steady` |

### `src/ProofCheck.sol`

When solo settlement was added, the body of `_run` was split into `_codeMatches` and `_call` so that the new one-lane path, `checkOne`, shares them. P4, P5 and P9 of the first batch were re-run on the new code as P4b, P5b and P9b.

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| C1 | checkOne: supplied entry not compared with the registered one | 4: `test_entry_that_is_not_the_registered_one_is_unavailable`, `test_row4_always_true_entry_against_terms_naming_the_solo_circuit`, `test_row4_real_proof_with_the_solo_entry_against_terms_naming_another_entry`, `test_row4_solo_proof_against_terms_naming_the_k8_circuit` |
| C2 | checkOne: unknown id not refused by itself | **none: survived, see below** |
| C3 | checkOne: code hashes not re-checked | 1: `test_if_the_verifier_code_changes_release_is_unavailable_and_refund_still_works` |
| C4 | checkOne: lane count not checked | 1: `test_entry_with_more_than_one_lane_cannot_settle_a_solo_request` |
| C5 | checkOne: output size not checked | 1: `test_output_of_the_wrong_size_is_invalid_even_if_the_adapter_accepts_anything` |
| C6 | checkOne: commitment not passed to the adapter | 32, among them `test_a_token_that_reenters_cannot_release_twice`, `test_a_token_whose_transfer_returns_false_cannot_release_or_refund`, `test_a_token_whose_transfer_returns_false_cannot_settle` |
| P4b | _codeMatches: adapter code not checked | 1: `test_adapter_whose_code_changed_is_unverifiable` |
| P5b | _codeMatches: target code not checked | 3: `test_if_the_verifier_code_changes_release_is_unavailable_and_refund_still_works`, `test_target_whose_code_changed_is_unverifiable`, `test_target_whose_code_was_removed_is_unverifiable` |
| P9b | _call: gas rule removed | 4: `test_adapter_always_receives_its_full_allowance`, `test_insufficient_gas_reverts_with_a_typed_error`, `test_no_gas_amount_turns_a_valid_real_proof_invalid`, `test_too_little_gas_reverts_with_a_typed_error_not_proof_invalid` |

### Test token (`test/mocks/MockERC3009.sol`)

In the one-transaction flow nothing is stored: an authorization cannot be used twice only because the token records its nonce, which USDC does. T1 shows that the replay tests would notice a token that does not.

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| T1 | test token does not mark an authorization used | 3: `test_row1_one_transaction_authorization_used_twice`, `test_v1_01_valid_proof_pays_the_provider_in_one_transaction`, `test_v1_08_the_same_authorization_cannot_settle_twice` |

### Fork suite (`test/SoloSettlementFork.t.sol`, real USDC)

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| FK1 | settle pays the payer instead of payTo (fork) | 3: `test_fork_settle_first_payment_to_the_provider`, `test_fork_settle_steady`, `test_fork_smart_wallet_payer_settles_through_real_usdc` |
| FK2 | release pays the payer (fork) | 2: `test_fork_release_first_payment_to_the_provider`, `test_fork_release_steady` |
| FK3 | refund pays payTo (fork) | 2: `test_fork_refund_last_lock`, `test_fork_refund_steady` |
| FK4 | open pulls one unit less than the terms (fork) | 4 (including `setUp` of suites that open a lock there), among them `test_fork_open_first_lock_held_by_the_contract`, `test_fork_open_steady` |
| FK5 | settle pays without pulling from the payer (fork) | 4: `test_fork_settle_first_payment_to_the_provider`, `test_fork_settle_steady`, `test_fork_smart_wallet_payer_settles_through_real_usdc`, `test_fork_smart_wallet_that_rejects_is_not_charged_by_real_usdc` |

### Survivor

| Id | Change | Why no test can see it |
|---|---|---|
| C2 | `checkOne` no longer refuses an unknown id by its zero entry hash | The next comparison refuses it anyway: an unknown id's stored hash is zero, and no entry hashes to zero. The first batch's P2 broke the same line differently, so that an unknown id was let through, and was caught. |

## Channel settlement (`src/ChannelSettlement.sol`, tests in `test/ChannelSettlement*.t.sol`)

Run on 2026-11-23 and 2026-11-24. Channel settlement adds 63 tests that run in CI (40 in `ChannelSettlement.t.sol`; 23 in `ChannelSettlementGas.t.sol`: nine transactions, twelve K-sweep points and two checks of the fitted line) and 7 opt-in tests against the testnet's USDC on a fork. With the 131 earlier tests the CI suite is 194 tests, all passing on the clean tree.

73 mutations were run: 68 against the channel suites (`--match-path 'test/Channel*.t.sol'`, which holds every test that uses the contract) and 5 against the fork suite (`FORK_RPC_URL` set to the testnet's public endpoint, `FORK_BLOCK=62638490`). Of the 68, 64 were planned; CH40 was run in an equivalent form because deleting its line made the compiler fail (stack too deep); CH11b, CH12b, G7 and T2 were added after the first pass showed four tests that no mutation had failed. Every mutation made at least one test fail. Two of them, CH17 and CH25, were caught only by the gas tests, which pin the sweep's execution to the unit and so notice any change to the bytecode; no functional test can notice them yet (see "Survivors"). Every one of the 70 new tests fails under at least one mutation recorded here.

The twelve sweep tests fail under nearly every mutation for the same reason, so each row says how many of the failures were gas tests and names functional tests first.

### `src/ChannelSettlement.sol`

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| CH1 | open: window minimums not checked | 13 (12 of them gas tests): `test_open_refuses_windows_below_the_minimums` |
| CH2 | open: a challenge window equal to the minimum refused | 1: `test_open_refuses_windows_below_the_minimums` |
| CH3 | open: zero deposit accepted | 1: `test_open_refuses_a_zero_or_oversized_deposit_and_a_zero_provider` |
| CH4 | open: deposit above 96 bits accepted | 1: `test_open_refuses_a_zero_or_oversized_deposit_and_a_zero_provider` |
| CH5 | open: zero provider accepted | 1: `test_open_refuses_a_zero_or_oversized_deposit_and_a_zero_provider` |
| CH6 | open: an existing channel not detected | 1: `test_v1_02_opening_the_same_config_twice_reverts` |
| CH7 | open: state not set to Open | 42 (8 of them gas tests): `setUp` of suites that build on it; `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, … |
| CH8 | open: deposit not recorded | 44 (8 of them gas tests): `setUp` of suites that build on it; `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, … |
| CH9 | open: deposit pulled for another amount | 47 (1 of them gas tests): `setUp` of suites that build on it; `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, … |
| CH10 | channel id ignores the chain | 13 (12 of them gas tests): `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain` |
| CH11 | channel id ignores the contract | 48 (1 of them gas tests): `setUp` of suites that build on it; `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, … |
| CH11b | channel id ignores the contract (rerun for the strengthened binding test) | 49 (1 of them gas tests): `setUp` of suites that build on it; `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, … |
| CH12 | channel id leaves out the salt | 48 (1 of them gas tests): `setUp` of suites that build on it; `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, … |
| CH12b | channel id leaves out the windows and the salt (rerun for the strengthened binding test) | 49 (1 of them gas tests): `setUp` of suites that build on it; `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, … |
| CH13 | lane: another provider's channel not skipped | 14 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped` |
| CH14 | lane: a channel in another asset not skipped | 13 (12 of them gas tests): `test_a_lane_whose_channel_pays_in_another_asset_is_skipped` |
| CH15 | lane: verifier set not checked | 14 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped` |
| CH16 | lane: a channel that was never opened is not skipped | 14 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain` |
| CH17 | lane: a closing channel refused | 12, all gas tests: `test_gas_sweep_first_k01`, `test_gas_sweep_first_k02`, `test_gas_sweep_first_k04`, … |
| CH18 | lane: any later voucher accepted | 14 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_vouchers_of_one_channel_settle_only_in_sequence` |
| CH19 | lane: seq not checked | 16 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_v1_08_resubmitting_a_settled_batch_reverts_and_names_every_lane`, `test_v1_11_resubmitting_the_solo_settlement_reverts`, `test_vouchers_of_one_channel_settle_only_in_sequence` |
| CH20 | lane: the last second (proveBy itself) refused | 13 (12 of them gas tests): `test_prove_by_is_inclusive_and_bounded_by_the_channels_window` |
| CH21 | lane: expiry not checked | 15 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_prove_by_is_inclusive_and_bounded_by_the_channels_window`, `test_v1_12_an_expired_voucher_is_skipped` |
| CH22 | lane: prove window not checked | 14 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_prove_by_is_inclusive_and_bounded_by_the_channels_window` |
| CH23 | lane: the window's edge refused | 13 (12 of them gas tests): `test_prove_by_is_inclusive_and_bounded_by_the_channels_window` |
| CH24 | lane: balance not checked | 14 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_v1_13_a_voucher_above_the_balance_is_skipped` |
| CH25 | lane: cumulative amount above 96 bits not refused | 12, all gas tests: `test_gas_sweep_first_k01`, `test_gas_sweep_first_k02`, `test_gas_sweep_first_k04`, … |
| CH26 | lane: signature not checked | 19 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_voucher_for_one_channel_cannot_settle_in_another`, `test_a_voucher_signed_for_another_chain_or_contract_is_skipped`, `test_an_erc1271_payer_refuses_a_wrong_signature`, … |
| CH27 | lane: any recovered address accepted | 19 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_voucher_for_one_channel_cannot_settle_in_another`, `test_a_voucher_signed_for_another_chain_or_contract_is_skipped`, `test_an_erc1271_payer_refuses_a_wrong_signature`, … |
| CH28 | lane: no ERC-1271 fallback | 13 (12 of them gas tests): `test_an_erc1271_payer_voucher_is_accepted` |
| CH29 | lane: seq not advanced | 27 (15 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_single_channel_batch_settles_eight_vouchers_in_order`, `test_a_voucher_for_one_channel_cannot_settle_in_another`, … |
| CH30 | lane: accounted not advanced | 19 (15 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_single_channel_batch_settles_eight_vouchers_in_order`, `test_the_same_proof_settles_later_vouchers_that_name_the_same_commitments`, `test_v1_04_a_k8_batch_settles_all_eight_lanes` |
| CH31 | lane: balance not reduced | 16 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_single_channel_batch_settles_eight_vouchers_in_order`, `test_v1_04_a_k8_batch_settles_all_eight_lanes`, `test_v1_10_the_solo_proof_settles_one_voucher_through_the_channels_solo_entry` |
| CH32 | lane: state cleared when a lane settles | 21 (15 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_single_channel_batch_settles_eight_vouchers_in_order`, `test_the_same_proof_settles_later_vouchers_that_name_the_same_commitments`, `test_v1_08_resubmitting_a_settled_batch_reverts_and_names_every_lane`, … |
| CH33 | lane: FrameSettled not emitted | 14 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_single_channel_batch_settles_eight_vouchers_in_order` |
| CH34 | lane: FrameSettled names something else than the channel | 2: `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_single_channel_batch_settles_eight_vouchers_in_order` |
| CH35 | lane: total not accumulated | 38 (19 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, `test_a_reentering_token_cannot_withdraw_twice`, … |
| CH36 | lane: settled lanes not counted | 38 (8 of them gas tests): `setUp` of suites that build on it; `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, … |
| CH37 | walk: padding lanes not recognised | 14 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_v1_05_a_padding_lane_is_reported_and_not_paid` |
| CH38 | walk: a zero commitment is padding when the entry declares none | 13 (12 of them gas tests): `test_a_zero_commitment_is_not_padding_when_the_entry_declares_none` |
| CH39 | walk: a padding lane's result not written | 14 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_v1_05_a_padding_lane_is_reported_and_not_paid` |
| CH40 | walk: a skipped lane's result written as Settled | 28 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, … |
| CH41 | walk: left-over bytes accepted | 13 (12 of them gas tests): `test_frames_that_do_not_parse_revert` |
| CH42 | walk: channel index not bounded | 1: `test_frames_that_do_not_parse_revert` |
| CH43 | frame: signature end not bounded | 13 (12 of them gas tests): `test_frames_that_do_not_parse_revert` |
| CH44 | frame: amount read from the wrong bits | 41 (8 of them gas tests): `setUp` of suites that build on it; `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, … |
| CH45 | frame: header one byte short | 41 (8 of them gas tests): `setUp` of suites that build on it; `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, … |
| CH46 | batch: set index not bounded | 13 (12 of them gas tests): `test_a_set_index_outside_the_set_reverts` |
| CH47 | batch: proof not checked | 15 (12 of them gas tests): `test_an_entry_that_is_not_the_named_verifiers_reverts`, `test_v1_09_an_invalid_proof_reverts`, `test_v1_14_a_verifier_that_is_not_registered_settles_nothing_until_anyone_registers_it` |
| CH48 | batch: an unavailable verifier reported as an invalid proof | 14 (12 of them gas tests): `test_an_entry_that_is_not_the_named_verifiers_reverts`, `test_v1_14_a_verifier_that_is_not_registered_settles_nothing_until_anyone_registers_it` |
| CH49 | batch: an empty channel list not refused | 1: `test_frames_that_do_not_parse_revert` |
| CH50 | batch: a batch where nothing settles does not revert | 20 (12 of them gas tests): `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, `test_a_voucher_for_one_channel_cannot_settle_in_another`, `test_a_voucher_signed_for_another_chain_or_contract_is_skipped`, … |
| CH51 | batch: nothing accrued | 29 (19 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, `test_a_reentering_token_cannot_withdraw_twice`, `test_a_settled_lane_writes_only_its_channel_slot_and_the_batch_one_accrual`, … |
| CH52 | batch: accrued under the wrong asset | 28 (19 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, `test_a_reentering_token_cannot_withdraw_twice`, `test_an_erc1271_payer_voucher_is_accepted`, … |
| CH53 | batch: set hash of the chosen id alone | 39 (8 of them gas tests): `setUp` of suites that build on it; `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, … |
| CH54 | batch: BatchSettled without lane results | 25 (12 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped`, `test_a_single_channel_batch_settles_eight_vouchers_in_order`, `test_a_zero_commitment_is_not_padding_when_the_entry_declares_none`, … |
| CH55 | domain: the cached separator used on any chain | 13 (12 of them gas tests): `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain` |
| CH56 | voucher: amount and cumulative amount swapped | 19 (15 of them gas tests): `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_single_channel_batch_settles_eight_vouchers_in_order`, `test_the_same_proof_settles_later_vouchers_that_name_the_same_commitments`, `test_views_agree_with_what_a_client_computes` |
| CH57 | voucher: wrong typed-data prefix | 39 (8 of them gas tests): `setUp` of suites that build on it; `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_frame_against_an_entry_outside_the_channels_set_is_skipped`, `test_a_lane_whose_channel_pays_in_another_asset_is_skipped`, … |
| CH58 | withdraw: more than accrued allowed | 1: `test_the_provider_withdraws_what_accrued_and_no_more` |
| CH59 | withdraw: zero allowed | 1: `test_the_provider_withdraws_what_accrued_and_no_more` |
| CH60 | withdraw: accrued reduced after paying | 1: `test_a_reentering_token_cannot_withdraw_twice` |
| CH61 | withdraw: accrued not reduced | 16 (14 of them gas tests): `test_a_reentering_token_cannot_withdraw_twice`, `test_the_provider_withdraws_what_accrued_and_no_more` |
| CH62 | withdraw: the token's answer ignored | 1: `test_withdraw_reverts_when_the_token_reports_failure` |

### Gas pins (`test/ChannelSettlementGas.t.sol`)

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| G5 | the reserved cold slot read on every lane | 17, all gas tests: `test_gas_k8_first_batch_new_channels_first_accrual`, `test_gas_k8_first_batch_new_channels_provider_paid_before`, `test_gas_k8_steady`, … |
| G6 | one more storage write per batch | 18 (17 of them gas tests): `test_a_settled_lane_writes_only_its_channel_slot_and_the_batch_one_accrual` |
| G7 | openChannel also writes the reserved cold slot | 3 (2 of them gas tests): `test_v1_01_open_stores_the_deposit_in_one_slot_and_pulls_it` |
| T2 | the pinned K=32 steady execution raised to 600,000 | 3, all gas tests: `test_gas_sweep_steady_k32`, `test_sweep_first_minus_steady_is_the_providers_first_accrual`, `test_sweep_steady_cost_per_frame_is_within_the_limit` |

T2 edits the test file, not the contract: it is the mutation that shows the two checks of the fitted line are live.

### Fork suite (`test/ChannelSettlementFork.t.sol`, real USDC)

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| FC1 | withdraw pays nothing | 2: `test_fork_withdraw_all_but_one_unit_steady`, `test_fork_withdraw_everything_first_usdc_of_the_provider` |
| FC2 | lane: no ERC-1271 fallback | 1: `test_fork_smart_wallet_opens_and_its_voucher_settles` |
| FC3 | open: deposit not recorded | 3: `setUp` of suites that build on it; `test_fork_smart_wallet_opens_and_its_voucher_settles` |
| FC4 | batch: pays the provider at once instead of accruing | 4: `test_fork_k8_steady`, `test_fork_smart_wallet_opens_and_its_voucher_settles`, `test_fork_withdraw_all_but_one_unit_steady`, `test_fork_withdraw_everything_first_usdc_of_the_provider` |
| FC5 | openChannel pulls nothing | 6: `test_fork_open_first_deposit_held_by_the_contract`, `test_fork_open_steady`, `test_fork_smart_wallet_opens_and_its_voucher_settles`, `test_fork_smart_wallet_that_rejects_is_not_charged`, … |

### Survivors

Neither is a gap in the tests; both change code that cannot run yet. Each will get a functional test with the close functions. (Both now have one: see CH17 and CH25 under "Closing a channel".)

- **CH17**, a closing channel refused by settlement. No function sets a channel to `Closing` yet, so refusing that state changes nothing a test can observe.
- **CH25**, the check that a cumulative amount fits 96 bits. `accounted` holds only amounts settled out of a deposit, and a deposit fits 96 bits, so the sum cannot overflow today. It can once waiving a voucher advances `accounted` without spending the balance.

## Closing a channel (`src/ChannelSettlement.sol`, tests in `test/ChannelClose*.t.sol`, `test/ChannelInvariant.t.sol`)

Run on 2026-11-24. Closing a channel adds 64 tests that run in CI: 47 in `ChannelClose.t.sol`, 5 invariants in `ChannelInvariant.t.sol` (512 runs of 50 calls each) and 12 in `ChannelCloseGas.t.sol`. It also adds 12 opt-in tests against the testnet's USDC on a fork. The steady `withdraw` gas test moved into a contract of its own, with its precondition in `setUp`. With the 194 earlier tests the CI suite is 258 tests, all passing on the clean tree.

74 mutations were run, in three batches:

- **First batch:** 58 mutations against every channel suite (`--match-path 'test/Channel*.t.sol'`). The log of this batch kept only `[FAIL …]` lines. A failing invariant prints its name on a later line, so for this batch the count of failing invariants is given but not their names.
- **Second batch:** 10 mutations, each run against one file. Four first-batch mutations were re-run against the invariant suite alone, now recording invariant names (suffix `i`). CD51 was re-run with the boundary test that was added because the first batch did not catch it by name (suffix `r`). Five more aimed at the ported cases that no first-batch mutation had failed.
- **Third batch:** 6 mutations against the fork suite (`FORK_RPC_URL` set to the testnet's public endpoint, `FORK_BLOCK=62638490`).

Every mutation made at least one test fail, and every one of the 77 tests added or changed today fails under at least one mutation recorded here. The two mutations that only the gas pins caught yesterday, CH17 and CH25, now fail functional tests.

In the first table, "gas" counts the gas tests among the failures and "invariant" the invariants. The twelve sweep tests pin execution to the unit, so they fail under any change to the lane's code.

### `src/ChannelSettlement.sol`, every channel suite

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| CD1 | requestClose: anyone may request | 2: `test_edge_a_smart_wallet_payer_closes_its_channel`, `test_only_the_payer_can_request_close` |
| CD2 | requestClose: state not checked | 6 (2 invariants): `test_a_closed_channel_accepts_nothing`, `test_a_closing_channel_settles_and_refuses_what_it_must`, `test_a_held_channel_refuses_a_challenge_a_close_request_and_a_second_finalize`, `test_close_calls_on_a_config_that_was_never_opened_revert` |
| CD3 | requestClose: closingAt ignores the challenge window | 29 (3 invariants, `setUp` of a suite that builds on it): `testFuzz_it2_with_a_challenge_close`, `test_a_challenge_needs_the_payers_signature_and_the_provider`, `test_a_challenge_refuses_an_expired_voucher_and_one_beyond_the_prove_window`, `test_a_closing_channel_settles_and_refuses_what_it_must` … |
| CD4 | requestClose: state not set to Closing | 37 (3 gas, 3 invariants, `setUp` of a suite that builds on it): `testFuzz_it2_with_a_challenge_close`, `test_a_challenge_needs_the_payers_signature_and_the_provider`, `test_a_challenge_refuses_an_expired_voucher_and_one_beyond_the_prove_window`, `test_a_closed_channel_accepts_nothing` … |
| CD5 | requestClose: balance dropped from the slot | 36 (8 gas, 2 invariants): `testFuzz_it2_with_a_challenge_close`, `test_a_challenge_refuses_an_expired_voucher_and_one_beyond_the_prove_window`, `test_a_closing_channel_settles_and_refuses_what_it_must`, `test_a_held_channel_refuses_a_challenge_a_close_request_and_a_second_finalize` … |
| CD6 | challengeClose: anyone may challenge | 1: `test_a_challenge_needs_the_payers_signature_and_the_provider` |
| CD7 | challengeClose: state not checked | 3: `test_a_closed_channel_accepts_nothing`, `test_a_held_channel_refuses_a_challenge_a_close_request_and_a_second_finalize`, `test_close_calls_on_a_config_that_was_never_opened_revert` |
| CD8 | challengeClose: accepted at closingAt | 1: `test_v2_g3_at_closing_at_the_challenge_reverts_and_finalize_works` |
| CD9 | challengeClose: settled seq accepted | 1: `test_v2_g3_a_challenge_with_a_settled_voucher_reverts` |
| CD10 | challengeClose: expired voucher accepted | 1: `test_a_challenge_refuses_an_expired_voucher_and_one_beyond_the_prove_window` |
| CD11 | challengeClose: proveBy beyond the window accepted | 1: `test_a_challenge_refuses_an_expired_voucher_and_one_beyond_the_prove_window` |
| CD12 | challengeClose: a lower claim replaces a higher one | 1: `test_v2_g3_a_higher_challenge_raises_the_claim_and_a_lower_one_reverts` |
| CD13 | challengeClose: a claim not above accounted accepted | 1: `test_v2_g3_a_challenge_with_a_settled_voucher_reverts` |
| CD14 | challengeClose: signature not checked | 2: `test_a_challenge_needs_the_payers_signature_and_the_provider`, `test_edge_a_smart_wallet_payer_closes_its_channel` |
| CD15 | challengeClose: hold expiry from the voucher's proveBy | 3: `test_edge_a_challenge_in_the_last_second_of_the_window_holds`, `test_the_hold_ends_at_closing_at_plus_the_prove_window_whatever_the_voucher_says`, `test_v2_g3_request_challenge_finalize_sweep` |
| CD16 | challengeClose: claim not stored | 26 (8 gas): `testFuzz_it2_with_a_challenge_close`, `test_a_challenge_refuses_an_expired_voucher_and_one_beyond_the_prove_window`, `test_a_held_channel_refuses_a_challenge_a_close_request_and_a_second_finalize`, `test_edge_a_batch_landing_after_finalize_settles_only_against_a_hold` … |
| CD17 | finalizeClose: state not checked | 6 (1 invariant): `test_a_closed_channel_accepts_nothing`, `test_a_held_channel_refuses_a_challenge_a_close_request_and_a_second_finalize`, `test_close_calls_on_a_config_that_was_never_opened_revert`, `test_edge_finalize_twice_reverts` … |
| CD18 | finalizeClose: before closingAt accepted | 1: `test_a_closing_channel_settles_and_refuses_what_it_must` |
| CD19 | finalizeClose: refused at closingAt | 29 (4 gas, 1 invariant, `setUp` of a suite that builds on it): `testFuzz_it2_with_a_challenge_close`, `test_a_closed_channel_accepts_nothing`, `test_a_held_channel_refuses_a_challenge_a_close_request_and_a_second_finalize`, `test_edge_a_batch_landing_after_finalize_settles_only_against_a_hold` … |
| CD20 | finalizeClose: hold ignored | 22 (6 gas): `testFuzz_it2_with_a_challenge_close`, `test_a_held_channel_refuses_a_challenge_a_close_request_and_a_second_finalize`, `test_edge_a_batch_landing_after_finalize_settles_only_against_a_hold`, `test_edge_a_challenge_in_the_last_second_of_the_window_holds` … |
| CD21 | finalizeClose: always Closed | 19 (4 gas, 1 invariant): `testFuzz_it2_with_a_challenge_close`, `test_a_held_channel_refuses_a_challenge_a_close_request_and_a_second_finalize`, `test_edge_a_batch_landing_after_finalize_settles_only_against_a_hold`, `test_edge_a_challenge_in_the_last_second_of_the_window_holds` … |
| CD22 | finalizeClose: balance kept | 15 (4 invariants): `testFuzz_it2_with_a_challenge_close`, `test_edge_a_batch_landing_after_finalize_settles_only_against_a_hold`, `test_edge_a_smart_wallet_payer_closes_its_channel`, `test_edge_at_hold_expiry_a_held_voucher_settles_and_a_second_later_it_does_not` … |
| CD23 | finalizeClose: pays before writing state | 1: `test_finalize_and_sweep_write_state_before_paying` |
| CD24 | finalizeClose: returns nothing | 21 (4 gas, 2 invariants): `testFuzz_it2_with_a_challenge_close`, `test_edge_a_batch_pending_when_close_is_requested_still_settles`, `test_edge_a_challenge_in_the_last_second_of_the_window_holds`, `test_edge_a_smart_wallet_payer_closes_its_channel` … |
| CD25 | finalizeClose: pays the provider | 20 (4 gas, 2 invariants): `testFuzz_it2_with_a_challenge_close`, `test_edge_a_batch_pending_when_close_is_requested_still_settles`, `test_edge_a_challenge_in_the_last_second_of_the_window_holds`, `test_edge_a_smart_wallet_payer_closes_its_channel` … |
| CD26 | finalizeClose: seq and accounted reset | 4 (1 invariant): `testFuzz_it2_with_a_challenge_close`, `test_edge_a_smart_wallet_payer_closes_its_channel`, `test_v2_g3_vouchers_settled_while_closing_shrink_the_hold` |
| CD27 | finalizeClose: back to Open instead of Closed | 8 (1 invariant): `test_a_closed_channel_accepts_nothing`, `test_edge_a_batch_landing_after_finalize_settles_only_against_a_hold`, `test_edge_finalize_twice_reverts`, `test_finalize_after_the_hold_expired_returns_everything` … |
| CD28 | sweep: state not checked | 5 (1 invariant): `test_a_closed_channel_accepts_nothing`, `test_a_closing_channel_settles_and_refuses_what_it_must`, `test_close_calls_on_a_config_that_was_never_opened_revert`, `test_finalize_and_sweep_write_state_before_paying` |
| CD29 | sweep: expiry not checked | 1: `test_v2_g3_at_hold_expiry_the_sweep_reverts_and_a_second_later_it_works` |
| CD30 | sweep: accepted at holdExpiry | 1: `test_v2_g3_at_hold_expiry_the_sweep_reverts_and_a_second_later_it_works` |
| CD31 | sweep: channel not closed | 6 (2 invariants): `test_edge_at_hold_expiry_a_held_voucher_settles_and_a_second_later_it_does_not`, `test_finalize_and_sweep_write_state_before_paying`, `test_v2_g3_at_hold_expiry_the_sweep_reverts_and_a_second_later_it_works`, `test_v2_g3_request_challenge_finalize_sweep` |
| CD32 | sweep: pays before writing state | 1: `test_finalize_and_sweep_write_state_before_paying` |
| CD33 | sweep: pays the provider | 8 (2 gas, 2 invariants): `test_edge_a_smart_wallet_payer_closes_its_channel`, `test_finalize_and_sweep_write_state_before_paying`, `test_v2_g3_at_hold_expiry_the_sweep_reverts_and_a_second_later_it_works`, `test_v2_g3_request_challenge_finalize_sweep` |
| CD34 | waive: anyone may waive | 1: `test_v2_g2_only_the_provider_can_waive` |
| CD35 | waive: held channel past expiry accepted | 1: `test_waive_after_the_hold_expired_reverts` |
| CD36 | waive: closed or unknown channel accepted | 3 (1 invariant): `test_a_closed_channel_accepts_nothing`, `test_close_calls_on_a_config_that_was_never_opened_revert` |
| CD37 | waive: any seq accepted | 2: `test_edge_waive_after_settle_reverts_and_the_next_voucher_can_be_waived`, `test_waive_needs_the_next_voucher_and_the_payers_signature` |
| CD38 | waive: cumulative amount not checked | 2: `test_a_cumulative_amount_beyond_96_bits_never_settles`, `test_v2_g2_waive_with_a_wrong_cumulative_amount_reverts` |
| CD39 | waive: signature not checked | 1: `test_waive_needs_the_next_voucher_and_the_payers_signature` |
| CD40 | waive: spends the balance | 10 (2 gas, 2 invariants): `testFuzz_it2_the_provider_is_paid_exactly_the_settled_vouchers`, `test_a_cumulative_amount_beyond_96_bits_never_settles`, `test_v2_g2_waive_advances_seq_and_accounted_and_the_next_voucher_settles`, `test_waive_accepts_an_expired_voucher_and_one_above_the_balance` … |
| CD41 | waive: a held channel returns nothing | 5 (2 gas, 2 invariants): `test_waive_after_finalize_returns_what_it_releases_to_the_payer` |
| CD42 | waive: a held channel emptied stays Held | 1: `test_waive_after_finalize_returns_what_it_releases_to_the_payer` |
| CD43 | waive: returns to the provider | 5 (2 gas, 2 invariants): `test_waive_after_finalize_returns_what_it_releases_to_the_payer` |
| CD44 | lane: held channel past expiry settles | 1: `test_edge_at_hold_expiry_a_held_voucher_settles_and_a_second_later_it_does_not` |
| CD45 | lane: settling the whole hold leaves the channel Held | 15 (12 gas): `testFuzz_it2_with_a_challenge_close`, `test_edge_a_batch_landing_after_finalize_settles_only_against_a_hold`, `test_v2_g3_vouchers_settled_while_closing_shrink_the_hold` |
| CD46 | lane: a held channel refused | 18 (12 gas): `testFuzz_it2_with_a_challenge_close`, `test_edge_a_batch_landing_after_finalize_settles_only_against_a_hold`, `test_edge_a_smart_wallet_payer_closes_its_channel`, `test_edge_at_hold_expiry_a_held_voucher_settles_and_a_second_later_it_does_not` … |
| CD47 | lane: a closed channel accepted | 4: `test_a_batch_mixing_settled_and_skipped_lanes_reports_every_lane`, `test_a_channel_is_unknown_on_another_chain_whose_vouchers_use_that_chains_domain`, `test_a_closed_channel_accepts_nothing`, `test_edge_a_batch_landing_after_finalize_settles_only_against_a_hold` |
| CH17 | lane: a closing channel refused (again, on the closing code) | 6: `test_a_closing_channel_settles_and_refuses_what_it_must`, `test_edge_a_batch_pending_when_close_is_requested_still_settles`, `test_it3_a_challenged_channel_settles_in_a_batch_and_its_hold_shrinks`, `test_it3_a_closing_channel_settled_in_a_batch_finalizes_with_the_rest` … |
| CH25 | lane: cumulative amount above 96 bits not refused (again, on the closing code) | 13 (12 gas): `test_a_cumulative_amount_beyond_96_bits_never_settles` |
| CD48 | hold: expiry ignored | 1: `test_finalize_after_the_hold_expired_returns_everything` |
| CD49 | hold: not capped at the balance | 1: `test_v2_g3_the_hold_is_capped_at_the_balance` |
| CD50 | hold: not reduced by what settled | 10 (2 gas, 1 invariant): `testFuzz_it2_with_a_challenge_close`, `test_edge_a_smart_wallet_payer_closes_its_channel`, `test_it3_a_challenged_channel_settles_in_a_batch_and_its_hold_shrinks`, `test_v2_g3_a_higher_challenge_raises_the_claim_and_a_lower_one_reverts` … |
| CD51 | hold: expires a second early | 1 (1 invariant) |
| CD52 | view: no held amount after finalization | 2 (1 invariant): `test_waive_after_finalize_returns_what_it_releases_to_the_payer` |
| CD53 | _requireState never reverts | 8 (2 invariants): `test_a_closed_channel_accepts_nothing`, `test_a_closing_channel_settles_and_refuses_what_it_must`, `test_a_held_channel_refuses_a_challenge_a_close_request_and_a_second_finalize`, `test_close_calls_on_a_config_that_was_never_opened_revert` … |
| GD1 | gas: an extra cold read in every state check | 9 (9 gas): `test_gas_challenge_close`, `test_gas_challenge_close_raising_an_earlier_claim`, `test_gas_finalize_payers_first_tokens` … |
| GD2 | gas: an extra cold read in every payment | 10 (10 gas): `test_gas_finalize_payers_first_tokens`, `test_gas_finalize_steady`, `test_gas_finalize_with_a_hold_payers_first_tokens` … |
| GD3 | gas: an extra cold read in waive | 3 (3 gas): `test_gas_waive`, `test_gas_waive_held_payers_first_tokens`, `test_gas_waive_held_steady` |

### Second batch: invariants by name, the boundary test, the ported cases

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| CD24i | finalizeClose: returns nothing (invariant suite) | 2: `invariant_no_channel_pays_out_more_than_its_deposit`, `invariant_tokens_are_conserved_to_the_unit` |
| CD26i | finalizeClose: seq and accounted reset (invariant suite) | 1: `invariant_seq_and_accounted_never_decrease` |
| CD36i | waive: closed or unknown channel accepted (invariant suite) | 1: `invariant_a_closed_channel_accepts_nothing` |
| CD27i | finalizeClose: back to Open instead of Closed (invariant suite) | 1: `invariant_states_only_move_forward_and_a_held_channel_holds_its_balance` |
| CD51r | hold: expires a second early (with the new boundary test) | 1: `test_at_hold_expiry_the_hold_still_counts_and_a_second_later_it_does_not` |
| CD54 | lane: accounted not advanced | 14: `testFuzz_it2_the_provider_is_paid_exactly_the_settled_vouchers`, `testFuzz_it2_with_a_challenge_close`, `test_edge_a_batch_pending_when_close_is_requested_still_settles`, `test_edge_a_smart_wallet_payer_closes_its_channel`, `test_edge_waive_after_settle_reverts_and_the_next_voucher_can_be_waived`, `test_it3_a_challenged_channel_settles_in_a_batch_and_its_hold_shrinks`, `test_v2_g1_cumulative_amount_persists_across_batches`, `test_v2_g1_two_vouchers_of_one_channel_settle_in_one_batch`, `test_v2_g2_waive_advances_seq_and_accounted_and_the_next_voucher_settles`, `test_v2_g3_a_challenge_with_a_settled_voucher_reverts`, `test_v2_g3_a_higher_challenge_raises_the_claim_and_a_lower_one_reverts`, `test_v2_g3_the_hold_is_capped_at_the_balance`, `test_v2_g3_vouchers_settled_while_closing_shrink_the_hold`, `test_waive_after_finalize_returns_what_it_releases_to_the_payer` |
| CD55 | lane: signature not checked | 1: `test_v2_g1_a_voucher_signed_with_a_wrong_cumulative_amount_is_skipped` |
| CD56 | open: also writes the cold slot | 1: `test_it1_a_new_channel_has_its_deposit_and_no_close_state` |
| CD57 | registry: an id can be registered again | 1: `test_it1_re_pointing_a_verifier_is_impossible` |
| CD58 | proof check: the supplied entry not compared with the registered one | 1: `test_it1_re_pointing_a_verifier_is_impossible` |

CD57 breaks `src/VerifierRegistry.sol` and CD58 `src/ProofCheck.sol`; both are what the inverted re-registration test (`test_it1_re_pointing_a_verifier_is_impossible`) guards. CD51 in the first batch failed one invariant only (unnamed there); CD51r shows the boundary test that now guards it directly.

### Fork suite (`test/ChannelSettlementFork.t.sol`, real USDC)

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| FD1 | finalizeClose: returns nothing | 5: `test_fork_finalize_payers_first_usdc`, `test_fork_finalize_steady`, `test_fork_finalize_with_a_hold_payers_first_usdc`, `test_fork_finalize_with_a_hold_steady`, `test_fork_smart_wallet_closes_with_a_hold` |
| FD2 | sweep: pays the provider | 2: `test_fork_sweep_payers_first_usdc`, `test_fork_sweep_steady` |
| FD3 | waive: a held channel returns nothing | 2: `test_fork_waive_held_payers_first_usdc`, `test_fork_waive_held_steady` |
| FD4 | requestClose: state not set to Closing | 8 (including `setUp` of suites that build on it): `test_fork_challenge_close`, `test_fork_finalize_payers_first_usdc`, `test_fork_finalize_steady`, `test_fork_request_close`, `test_fork_smart_wallet_closes_with_a_hold` |
| FD5 | waive: seq not advanced | 1: `test_fork_waive_open_channel` |
| FD6 | withdraw pays nothing | 2: `test_fork_withdraw_all_but_one_unit_steady`, `test_fork_withdraw_everything_first_usdc_of_the_provider` |

## The ERC-8183 evaluator and the ERC-8004 validator (`src/ProofEvaluator8183.sol`, `src/ProofValidator8004.sol`, `src/ClaimDigest.sol`)

Run on 2026-11-24. The ERC-8183 and ERC-8004 contracts add 56 tests that run in CI: 32 in `ProofEvaluator8183.t.sol`, 16 in `ProofValidator8004.t.sol` and 8 in `StandardsGas.t.sol`. All use the real solo proof, the ERC-8183 reference job contract and the ERC-8004 reference registries (`test/external/README.md`). With the 258 earlier tests the CI suite is 314 tests, all passing on the clean tree.

55 mutations were run, in two batches, each against the three new test files only (`--match-path 'test/{ProofEvaluator8183,ProofValidator8004,StandardsGas}.t.sol'`, or one of them):

- **First batch:** 47 mutations of our three contracts.
- **Second batch:** 8 mutations. After the first batch, four tests had not failed under any mutation: they check rules that the reference registries enforce, not our code. RG1–RG6 break those rules in the registries' own source (`lib/erc-8004-contracts`, restored byte for byte after each run) and show that the tests notice a registry that does not enforce them. The gas tests were also corrected after the first batch: they read the proxies' implementation slots in the test body, which left the proxy accounts warm, and every figure was 2,500 low. EV23r and VA17r repeat the two gas mutations against the corrected pins.

Every mutation made at least one test fail, and every one of the 56 new tests fails under at least one mutation recorded here.

### `src/ProofEvaluator8183.sol`

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| EV1 | setTerms: zero verifier accepted | 1: `test_terms_naming_no_verifier_revert` |
| EV2 | setTerms: terms can be overwritten | 1: `test_terms_set_twice_revert` |
| EV3 | setTerms: any caller | 2: `test_terms_for_a_job_that_does_not_exist_revert`, `test_terms_set_by_anyone_but_the_client_revert` |
| EV4 | setTerms: any job status | 1: `test_terms_after_the_job_left_Open_revert` |
| EV5 | setTerms: any evaluator | 1: `test_terms_for_a_job_with_another_evaluator_revert` |
| EV6 | setTerms: verifier not stored | 28: `test_a_forfeited_job_cannot_be_completed`, `test_a_job_is_completed_once`, `test_a_tampered_output_reverts_and_leaves_the_job_unchanged`, `test_a_tampered_proof_reverts_and_leaves_the_job_unchanged`, `test_a_valid_proof_completes_the_job_and_pays_the_provider_with_the_fee`, `test_a_verifier_whose_code_changed_reverts_unavailable`, `test_a_zero_budget_job_submitted_while_Open_completes_with_nothing_paid`, `test_an_entry_that_is_not_the_registered_one_reverts_unavailable`, `test_an_unknown_verifier_reverts_unavailable`, `test_evaluate_after_expiry_reverts`, `test_evaluate_at_expiry_reverts_and_the_refund_opens`, `test_evaluate_before_submission_reverts`, `test_evaluate_one_second_before_expiry_completes`, `test_gas_evaluate_completes_with_the_evaluator_fee_first_payment`, `test_gas_evaluate_completes_with_the_evaluator_fee_steady`, `test_gas_evaluate_completes_without_a_fee_steady`, `test_gas_setTerms`, `test_nobody_can_reject_through_the_evaluator_with_a_garbage_proof`, `test_only_the_fee_paid_during_the_call_is_forwarded`, `test_terms_are_kept_per_job_contract`, `test_terms_are_set_by_the_client_and_readable`, `test_terms_naming_another_verifier_refuse_the_proof`, `test_terms_set_twice_revert`, `test_terms_with_another_input_commitment_refuse_the_proof`, `test_the_evaluator_and_the_validator_record_the_same_digest_for_one_claim`, `test_the_reason_recorded_on_the_job_is_the_claim_digest`, `test_with_a_platform_fee_the_provider_gets_the_budget_less_that_fee`, `test_without_an_evaluator_fee_the_provider_gets_the_budget` |
| EV7 | setTerms: commitment not stored | 16: `test_a_job_is_completed_once`, `test_a_valid_proof_completes_the_job_and_pays_the_provider_with_the_fee`, `test_a_zero_budget_job_submitted_while_Open_completes_with_nothing_paid`, `test_evaluate_one_second_before_expiry_completes`, `test_gas_evaluate_completes_with_the_evaluator_fee_first_payment`, `test_gas_evaluate_completes_with_the_evaluator_fee_steady`, `test_gas_evaluate_completes_without_a_fee_steady`, `test_nobody_can_reject_through_the_evaluator_with_a_garbage_proof`, `test_only_the_fee_paid_during_the_call_is_forwarded`, `test_terms_are_kept_per_job_contract`, `test_terms_are_set_by_the_client_and_readable`, `test_terms_set_twice_revert`, `test_the_evaluator_and_the_validator_record_the_same_digest_for_one_claim`, `test_the_reason_recorded_on_the_job_is_the_claim_digest`, `test_with_a_platform_fee_the_provider_gets_the_budget_less_that_fee`, `test_without_an_evaluator_fee_the_provider_gets_the_budget` |
| EV8 | setTerms: event carries no commitment | 1: `test_terms_are_set_by_the_client_and_readable` |
| EV9 | evaluate: no check that terms exist | 2: `test_terms_are_kept_per_job_contract`, `test_without_terms_a_job_cannot_be_completed_and_can_only_expire` |
| EV10 | evaluate: any job status | 3: `test_a_forfeited_job_cannot_be_completed`, `test_a_job_is_completed_once`, `test_evaluate_before_submission_reverts` |
| EV11 | evaluate: accepted at expiredAt | 1: `test_evaluate_at_expiry_reverts_and_the_refund_opens` |
| EV12 | evaluate: no expiry check | 2: `test_evaluate_after_expiry_reverts`, `test_evaluate_at_expiry_reverts_and_the_refund_opens` |
| EV13 | evaluate: could-not-check reported as invalid | 3: `test_a_verifier_whose_code_changed_reverts_unavailable`, `test_an_entry_that_is_not_the_registered_one_reverts_unavailable`, `test_an_unknown_verifier_reverts_unavailable` |
| EV14 | evaluate: invalid proof accepted | 5: `test_a_tampered_output_reverts_and_leaves_the_job_unchanged`, `test_a_tampered_proof_reverts_and_leaves_the_job_unchanged`, `test_nobody_can_reject_through_the_evaluator_with_a_garbage_proof`, `test_terms_naming_another_verifier_refuse_the_proof`, `test_terms_with_another_input_commitment_refuse_the_proof` |
| EV15 | evaluate: invalid proof rejects the job | 8: `test_a_tampered_output_reverts_and_leaves_the_job_unchanged`, `test_a_tampered_proof_reverts_and_leaves_the_job_unchanged`, `test_gas_evaluate_completes_with_the_evaluator_fee_first_payment`, `test_gas_evaluate_completes_with_the_evaluator_fee_steady`, `test_gas_evaluate_completes_without_a_fee_steady`, `test_nobody_can_reject_through_the_evaluator_with_a_garbage_proof`, `test_terms_naming_another_verifier_refuse_the_proof`, `test_terms_with_another_input_commitment_refuse_the_proof` |
| EV16 | evaluate: could-not-check rejects the job | 6: `test_a_verifier_whose_code_changed_reverts_unavailable`, `test_an_entry_that_is_not_the_registered_one_reverts_unavailable`, `test_an_unknown_verifier_reverts_unavailable`, `test_gas_evaluate_completes_with_the_evaluator_fee_first_payment`, `test_gas_evaluate_completes_with_the_evaluator_fee_steady`, `test_gas_evaluate_completes_without_a_fee_steady` |
| EV17 | evaluate: proof checked against commitment 0 | 14: `test_a_job_is_completed_once`, `test_a_valid_proof_completes_the_job_and_pays_the_provider_with_the_fee`, `test_a_zero_budget_job_submitted_while_Open_completes_with_nothing_paid`, `test_evaluate_one_second_before_expiry_completes`, `test_gas_evaluate_completes_with_the_evaluator_fee_first_payment`, `test_gas_evaluate_completes_with_the_evaluator_fee_steady`, `test_gas_evaluate_completes_without_a_fee_steady`, `test_nobody_can_reject_through_the_evaluator_with_a_garbage_proof`, `test_only_the_fee_paid_during_the_call_is_forwarded`, `test_terms_are_kept_per_job_contract`, `test_the_evaluator_and_the_validator_record_the_same_digest_for_one_claim`, `test_the_reason_recorded_on_the_job_is_the_claim_digest`, `test_with_a_platform_fee_the_provider_gets_the_budget_less_that_fee`, `test_without_an_evaluator_fee_the_provider_gets_the_budget` |
| EV18 | evaluate: reason 0 instead of the claim digest | 3: `test_a_valid_proof_completes_the_job_and_pays_the_provider_with_the_fee`, `test_the_evaluator_and_the_validator_record_the_same_digest_for_one_claim`, `test_the_reason_recorded_on_the_job_is_the_claim_digest` |
| EV19 | evaluate: fee kept | 7: `test_a_job_is_completed_once`, `test_a_valid_proof_completes_the_job_and_pays_the_provider_with_the_fee`, `test_gas_evaluate_completes_with_the_evaluator_fee_first_payment`, `test_gas_evaluate_completes_with_the_evaluator_fee_steady`, `test_nobody_can_reject_through_the_evaluator_with_a_garbage_proof`, `test_only_the_fee_paid_during_the_call_is_forwarded`, `test_with_a_platform_fee_the_provider_gets_the_budget_less_that_fee` |
| EV20 | evaluate: fee paid to the caller | 7: `test_a_job_is_completed_once`, `test_a_valid_proof_completes_the_job_and_pays_the_provider_with_the_fee`, `test_gas_evaluate_completes_with_the_evaluator_fee_first_payment`, `test_gas_evaluate_completes_with_the_evaluator_fee_steady`, `test_nobody_can_reject_through_the_evaluator_with_a_garbage_proof`, `test_only_the_fee_paid_during_the_call_is_forwarded`, `test_with_a_platform_fee_the_provider_gets_the_budget_less_that_fee` |
| EV21 | evaluate: whole balance forwarded, not the fee | 1: `test_only_the_fee_paid_during_the_call_is_forwarded` |
| EV22 | evaluate: event without the output | 1: `test_a_valid_proof_completes_the_job_and_pays_the_provider_with_the_fee` |
| EV23 | evaluate: the job is read twice (gas) | 3: `test_gas_evaluate_completes_with_the_evaluator_fee_first_payment`, `test_gas_evaluate_completes_with_the_evaluator_fee_steady`, `test_gas_evaluate_completes_without_a_fee_steady` |
| EV24 | forfeit: any caller | 2: `test_nobody_can_reject_through_the_evaluator_with_a_garbage_proof`, `test_only_the_provider_can_forfeit` |
| EV25 | forfeit: the client may forfeit too | 1: `test_only_the_provider_can_forfeit` |
| EV26 | forfeit: reason 0 | 1: `test_only_the_provider_can_forfeit` |
| EV27 | forfeit: the job is not rejected | 5: `test_a_forfeited_job_cannot_be_completed`, `test_a_provider_can_forfeit_before_submitting`, `test_forfeit_of_an_open_job_is_refused_by_the_job_contract`, `test_gas_forfeit_steady`, `test_only_the_provider_can_forfeit` |
| EV28 | terms: view returns nothing | 3: `test_gas_setTerms`, `test_terms_are_set_by_the_client_and_readable`, `test_terms_set_twice_revert` |

### `src/ClaimDigest.sol`

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| CD1 | digest: no chain id | 5: `test_a_valid_proof_completes_the_job_and_pays_the_provider_with_the_fee`, `test_a_valid_proof_of_another_output_is_answered_0`, `test_a_valid_proof_of_the_claimed_output_is_answered_100`, `test_the_evaluator_and_the_validator_record_the_same_digest_for_one_claim`, `test_the_reason_recorded_on_the_job_is_the_claim_digest` |
| CD2 | digest: commitment and verifier swapped | 5: `test_a_valid_proof_completes_the_job_and_pays_the_provider_with_the_fee`, `test_a_valid_proof_of_another_output_is_answered_0`, `test_a_valid_proof_of_the_claimed_output_is_answered_100`, `test_the_evaluator_and_the_validator_record_the_same_digest_for_one_claim`, `test_the_reason_recorded_on_the_job_is_the_claim_digest` |

### `src/ProofValidator8004.sol`

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| VA1 | request hash: no salt | 5 (including `setUp` of a suite that builds on it): `test_a_request_opened_by_anyone_but_the_owner_or_an_operator_is_rejected_by_the_registry`, `test_every_argument_is_part_of_the_request_hash`, `test_the_request_hash_is_the_typed_hash_of_the_request`, `test_the_summary_is_pulled_down_only_by_a_proven_contradiction` |
| VA2 | request hash: not bound to the validator | 1: `test_the_request_hash_is_the_typed_hash_of_the_request` |
| VA3 | request hash: not bound to the chain | 1: `test_the_request_hash_is_the_typed_hash_of_the_request` |
| VA4 | request hash: no agent | 2: `test_every_argument_is_part_of_the_request_hash`, `test_the_request_hash_is_the_typed_hash_of_the_request` |
| VA5 | request hash: another type string | 1: `test_the_request_hash_is_the_typed_hash_of_the_request` |
| VA6 | respond: no check of the request's agent | 1: `test_a_request_recorded_for_another_agent_is_not_answered` |
| VA7 | respond: could-not-check reported as invalid | 2: `test_a_check_that_cannot_run_writes_nothing`, `test_the_summary_is_pulled_down_only_by_a_proven_contradiction` |
| VA8 | respond: invalid proof answered | 2: `test_an_invalid_proof_writes_nothing_whatever_the_claim`, `test_the_summary_is_pulled_down_only_by_a_proven_contradiction` |
| VA9 | respond: invalid proof answered 0 | 5: `test_an_invalid_proof_writes_nothing_whatever_the_claim`, `test_gas_respond_0`, `test_gas_respond_100`, `test_gas_respond_100_again`, `test_the_summary_is_pulled_down_only_by_a_proven_contradiction` |
| VA10 | respond: could-not-check answered 0 | 5: `test_a_check_that_cannot_run_writes_nothing`, `test_gas_respond_0`, `test_gas_respond_100`, `test_gas_respond_100_again`, `test_the_summary_is_pulled_down_only_by_a_proven_contradiction` |
| VA11 | respond: 100 and 0 swapped | 10: `test_a_request_opened_by_anyone_but_the_owner_or_an_operator_is_rejected_by_the_registry`, `test_a_summary_filtered_to_this_validator_ignores_other_validators`, `test_a_valid_proof_of_another_output_is_answered_0`, `test_a_valid_proof_of_the_claimed_output_is_answered_100`, `test_every_argument_is_part_of_the_request_hash`, `test_gas_respond_0`, `test_gas_respond_100`, `test_gas_respond_100_again`, `test_respond_is_open_to_anyone_and_repeatable`, `test_the_summary_is_pulled_down_only_by_a_proven_contradiction` |
| VA12 | respond: a contradiction is not written | 3: `test_a_valid_proof_of_another_output_is_answered_0`, `test_gas_respond_0`, `test_the_summary_is_pulled_down_only_by_a_proven_contradiction` |
| VA13 | respond: wrong tag on a pass | 3: `test_a_summary_filtered_to_this_validator_ignores_other_validators`, `test_a_valid_proof_of_the_claimed_output_is_answered_100`, `test_the_summary_is_pulled_down_only_by_a_proven_contradiction` |
| VA14 | respond: no response hash on a pass | 2: `test_a_valid_proof_of_the_claimed_output_is_answered_100`, `test_the_evaluator_and_the_validator_record_the_same_digest_for_one_claim` |
| VA15 | respond: pass written as 99 | 8: `test_a_request_opened_by_anyone_but_the_owner_or_an_operator_is_rejected_by_the_registry`, `test_a_summary_filtered_to_this_validator_ignores_other_validators`, `test_a_valid_proof_of_the_claimed_output_is_answered_100`, `test_every_argument_is_part_of_the_request_hash`, `test_gas_respond_100`, `test_gas_respond_100_again`, `test_respond_is_open_to_anyone_and_repeatable`, `test_the_summary_is_pulled_down_only_by_a_proven_contradiction` |
| VA16 | respond: event reports the wrong answer | 1: `test_a_valid_proof_of_the_claimed_output_is_answered_100` |
| VA17 | respond: the request is read twice (gas) | 3: `test_gas_respond_0`, `test_gas_respond_100`, `test_gas_respond_100_again` |

### Second batch: the reference registries' rules, and the gas pins after the correction

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| RG1 | registry: anyone may open a request for an agent | 1: `test_a_request_opened_by_anyone_but_the_owner_or_an_operator_is_rejected_by_the_registry` |
| RG2 | registry: the agent is not looked up | 2: `test_a_request_for_an_agent_that_does_not_exist_is_rejected_by_the_registry`, `test_a_request_opened_by_anyone_but_the_owner_or_an_operator_is_rejected_by_the_registry` |
| RG3 | registry: anyone may answer a request | 1: `test_a_request_naming_another_validator_is_not_answered_by_this_one` |
| RG4 | registry: an unknown request reads as empty | 2: `test_every_argument_is_part_of_the_request_hash`, `test_respond_without_an_open_request_reverts` |
| RG5 | registry: unanswered requests counted in the summary | 4: `test_a_check_that_cannot_run_writes_nothing`, `test_a_request_recorded_for_another_agent_is_not_answered`, `test_an_invalid_proof_writes_nothing_whatever_the_claim`, `test_the_summary_is_pulled_down_only_by_a_proven_contradiction` |
| RG6 | identity: agents numbered from 1 | 1: `test_agents_are_identity_registry_tokens` |
| EV23r | evaluate: the job is read twice (gas, corrected pins) | 3: `test_gas_evaluate_completes_with_the_evaluator_fee_first_payment`, `test_gas_evaluate_completes_with_the_evaluator_fee_steady`, `test_gas_evaluate_completes_without_a_fee_steady` |
| VA17r | respond: the request is read twice (gas, corrected pins) | 3: `test_gas_respond_0`, `test_gas_respond_100`, `test_gas_respond_100_again` |

RG1–RG5 break `ValidationRegistryUpgradeable.sol` and RG6 `IdentityRegistryUpgradeable.sol`, at the pinned commit. RG5 is the property behind "the summary is never pulled down by could-not-check or no-answer": a registry that counted unanswered requests fails four tests.

## x402: the auth-capture operator, the server and clients

Run on 2026-11-24. The x402 work adds 22 tests that run in CI: 15 in `AuthCaptureProofOperator.t.sol`, 2 in `AuthCaptureSaltBinding.t.sol` and 5 in `AuthCaptureGas.t.sol`. Six more are opt-in: 3 USDC fork tests in `AuthCaptureGas.t.sol`, and 3 in `AuthCaptureStockClient.t.sol`, which replay a payment signed by x402's own client and skip when the end-to-end run has not written it. With the 314 earlier tests the CI suite is 336 tests, all passing on the clean tree. The end-to-end run in `x402/` (`run_e2e.sh`, ten scenarios) is a test too.

28 mutations were run, in batches, each against the files that can catch it. All were caught. Every one of the 28 new Forge tests fails under at least one of them, `test_fork_gas_authorize_steady` only through its suite's `setUp` (FX1), like FD4 when channels were closed. OP1 was run before `forge fmt` reformatted the operator and again after it (OP1r).

### `src/AuthCaptureProofOperator.sol` (`--match-path 'test/AuthCapture*.t.sol'`, with the stock-client payment present)

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| OP1 | authorize: a partial amount is accepted | 1: `test_authorize_must_collect_the_full_amount` |
| OP2 | charge: forwards to the escrow without a proof | 2: `test_gas_charge_with_proof_steady`, `test_the_escrows_charge_is_not_reachable_without_a_proof` |
| OP3 | terms: the salt is not checked | 3: `test_a_payment_not_bound_to_terms_can_never_be_captured`, `test_a_proof_for_other_terms_than_the_payer_signed_cannot_capture`, `test_charge_with_an_invalid_proof_moves_nothing_and_the_authorization_stays_usable` |
| OP4 | terms: the operator is not checked | 1: `test_a_payment_for_another_operator_is_refused` |
| OP5 | proof: could-not-check reported as invalid | 2: `test_a_check_that_cannot_run_cannot_capture`, `test_x402s_client_payment_is_held_and_captured_only_with_a_valid_proof` |
| OP6 | proof: an invalid proof is accepted | 4: `test_a_proof_for_other_terms_than_the_payer_signed_cannot_capture`, `test_an_invalid_proof_cannot_capture_and_the_payer_reclaims_after_the_deadline`, `test_charge_with_an_invalid_proof_moves_nothing_and_the_authorization_stays_usable`, `test_x402s_client_payment_is_held_and_captured_only_with_a_valid_proof` |
| OP7 | fee: the payer's maximum instead of the minimum | 1: `test_the_fee_taken_is_the_payers_minimum` |
| OP8 | capture: one unit instead of the whole hold | 9: `test_a_hold_is_captured_once`, `test_a_random_salt_nonce_defeats_that_binding_but_not_the_receiver_authorizer_one`, `test_anyone_places_the_hold_and_a_valid_proof_captures_it_for_the_receiver`, `test_gas_capture_with_proof_first_payout_of_the_operator`, `test_gas_capture_with_proof_steady`, `test_no_capture_from_the_capture_deadline_on`, `test_only_the_receiver_can_give_the_hold_back_early`, `test_the_fee_taken_is_the_payers_minimum`, `test_x402s_client_payment_is_held_and_captured_only_with_a_valid_proof` |
| OP9 | charge with proof: less than the maximum | 3: `test_charge_with_a_valid_proof_pays_the_receiver_in_one_step`, `test_charge_with_an_invalid_proof_moves_nothing_and_the_authorization_stays_usable`, `test_gas_charge_with_proof_steady` |
| OP10 | void: anyone may give the hold back | 1: `test_only_the_receiver_can_give_the_hold_back_early` |
| OP11 | terms: the authorizer ignores the input commitment | 4: `test_a_proof_for_other_terms_than_the_payer_signed_cannot_capture`, `test_the_terms_authorizer_and_the_bound_salt_follow_the_schemes_derivation`, `test_x402s_client_bound_the_terms_through_receiver_authorizer`, `test_x402s_client_payment_is_held_and_captured_only_with_a_valid_proof` |
| OP12 | terms: the authorizer bound as the policy instead | 3: `test_the_terms_authorizer_and_the_bound_salt_follow_the_schemes_derivation`, `test_x402s_client_bound_the_terms_through_receiver_authorizer`, `test_x402s_client_payment_is_held_and_captured_only_with_a_valid_proof` |
| OP13 | capture: event without the output | 1: `test_anyone_places_the_hold_and_a_valid_proof_captures_it_for_the_receiver` |
| OP14 | charge: event with digest 0 | 1: `test_charge_with_a_valid_proof_pays_the_receiver_in_one_step` |
| OP15 | void: no event | 1: `test_only_the_receiver_can_give_the_hold_back_early` |
| OP16 | capture: the hold is read twice (gas) | 2: `test_gas_capture_with_proof_first_payout_of_the_operator`, `test_gas_capture_with_proof_steady` |
| OP17 | authorize: a second hold is read (gas) | 2: `test_gas_authorize_first_hold_of_the_operator`, `test_gas_authorize_steady` |

### Second batch: the stock-client reclaim test, the salt-binding tests

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| OP18 | authorize: does not forward to the escrow | 17 (including `setUp` of a suite that builds on it): `test_a_check_that_cannot_run_cannot_capture`, `test_a_hold_is_captured_once`, `test_a_payment_not_bound_to_terms_can_never_be_captured`, `test_a_proof_for_other_terms_than_the_payer_signed_cannot_capture`, `test_a_random_salt_nonce_defeats_that_binding_but_not_the_receiver_authorizer_one`, `test_a_salt_nonce_derived_from_the_terms_fits_the_escrow`, `test_an_invalid_proof_cannot_capture_and_the_payer_reclaims_after_the_deadline`, `test_anyone_places_the_hold_and_a_valid_proof_captures_it_for_the_receiver`, `test_authorize_must_collect_the_full_amount`, `test_gas_authorize_first_hold_of_the_operator`, `test_gas_capture_with_proof_first_payout_of_the_operator`, `test_no_capture_from_the_capture_deadline_on`, `test_only_the_receiver_can_give_the_hold_back_early`, `test_the_fee_taken_is_the_payers_minimum`, `test_x402s_client_payment_is_held_and_captured_only_with_a_valid_proof`, `test_x402s_client_payment_left_unproven_is_reclaimed_after_the_deadline` |
| SB1 | the first proposal's check ignores the input commitment (test contract) | 1: `test_a_salt_nonce_derived_from_the_terms_fits_the_escrow` |
| SB2 | escrow: refuses a salt above 128 bits (escrow source) | 2: `test_a_random_salt_nonce_defeats_that_binding_but_not_the_receiver_authorizer_one`, `test_a_salt_nonce_derived_from_the_terms_fits_the_escrow` |
| OP1r | authorize: a partial amount is accepted (formatted source) | 1: `test_authorize_must_collect_the_full_amount` |

SB1 breaks the test-only contract that implements the first proposal's binding; SB2 breaks the escrow's source (`lib/commerce-payments`, restored after the run) so that it refuses large salts.

### Fork suite (`test/AuthCaptureGas.t.sol`, real USDC, `FORK_BLOCK=62638490`)

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| FX1 | authorize: does not forward to the escrow (fork) | 1 (including `setUp` of a suite that builds on it):  |
| FX2 | capture: one unit instead of the whole hold (fork) | 1: `test_fork_gas_capture_with_proof_steady` |
| FX3 | charge with proof: less than the maximum (fork) | 1: `test_fork_gas_charge_with_proof_steady` |

### The x402 server and clients (`bash x402/run_e2e.sh`)

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| SV1 | server: both proof failures reported as one errorReason | `run_e2e.sh` exits 1 at "proof-gated/authorization/wrong-entry -> invalid_proof_gated_evm_verifier_unavailable" |
| SV2 | server: escrow flow does not lock before the resource | `run_e2e.sh` exits 1 at "200 with a successful PAYMENT-RESPONSE" |
| CL1 | client: the request id always uses the one-transaction type | `run_e2e.sh` exits 1 at "200 with a successful PAYMENT-RESPONSE" |
| CL2 | client: no check that receiverAuthorizer is bound to the terms | `run_e2e.sh` exits 1 at "the client refuses to sign" |

## Testnet deployment

Run on 2026-11-24. The deployment adds 9 tests that run in CI (`test/DeployBaseSepolia.t.sol`) and 1 opt-in test on a fork of the testnet (`test/DeployBaseSepoliaFork.t.sol`). With the 336 earlier tests the CI suite is 345 tests, all passing on the clean tree. 15 mutations were run against the deployment script. All were caught. Every one of the 10 new tests fails under at least one. The client package adds 19 unit tests and the end-to-end run of the client against the middleware (36 checks, not part of `forge test`). 9 mutations of the client and the middleware and 16 of the client's checks before signing were all caught (one only after a test was added for it), and every one of the 19 unit tests fails under at least one.

### `script/DeployBaseSepolia.s.sol` (`--match-path test/DeployBaseSepolia.t.sol`; the script restored byte for byte afterwards)

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| DP1 | chain id not checked | 1: `test_refuses_another_chain` (did not revert) |
| DP2 | Validation Registry implementation not checked | 1: `test_refuses_a_changed_validation_registry_implementation` (reverted later, without the expected reason) |
| DP3 | Identity Registry link not checked | 1: `test_refuses_a_validation_registry_linked_to_another_identity_registry` (reverted at the next check instead) |
| DP4 | Identity Registry implementation not checked | 1: `test_refuses_a_changed_identity_registry_implementation` |
| DP5 | escrow code hash not checked | 1: `test_refuses_other_escrow_code` |
| DP6 | collector code hash not checked | 1: `test_refuses_other_collector_code` (reverted later, without the expected reason) |
| DP7 | the escrow the collector serves not checked | 1: `test_refuses_a_collector_that_serves_another_escrow` |
| DP8 | deployer's USDC not checked before anything is sent | 1: `test_refuses_a_deployer_without_the_two_seed_units` (the token's own error, after the deployments) |
| DP9 | the solo bytes deployed as the K=8 verifier | 1: `test_deploys_the_pinned_verifiers_and_everything_the_notes_list` (`CodeHashMismatch` at registration) |
| DP10 | creation prefix copies from offset 10 instead of 11 | 1: the same test (`CodeHashMismatch`) |
| DP11 | ChannelSettlement not seeded, and the script's own seed check removed | 1: the same test ("ChannelSettlement seed: 0 != 1") |
| DP12 | validator pointed at the Identity Registry, and the script's own link check removed | 1: the same test ("validator's ERC-8004 registry") |
| DP13 | solo `verifyGas` 600,001, and the script's own id check removed | 1: the same test ("solo id: the id the tests compute") |
| DP14 | operator pointed at the collector, and the script's own link check removed | 1: the same test ("operator escrow") |
| DPF1 | the pinned escrow code hash changed in its last digit (fork, `test/DeployBaseSepoliaFork.t.sol`) | 1: `test_fork_the_script_deploys_against_the_live_chain` ("preflight: escrow code differs") |

`scripts/escrow_live_check.py`, negative control EC1: built with 200 optimiser runs instead of the deploy profile's 100,000, both contracts report `DIFFER` and the script exits 1.

### The clients (`clients/ts/test/refusal.test.ts`, 19 unit tests, and `bash clients/e2e/run.sh`, 36 checks; each file restored byte for byte)

| Id | Deliberate breakage | What failed |
|---|---|---|
| CL3 | client: `receiverAuthorizer` binding not checked | unit: "refuses a receiverAuthorizer that is not bound to the terms", "…bound to another verifier"; e2e: the unbound offer is signed and fails on chain ("refused: invalid_proof_gated_evm_terms_mismatch" instead of a refusal), and the hold moves the payer's funds |
| CL4 | client: no refusal when the verifier changes after the commitment | e2e: "refused: invalid_auth_capture_evm_extra" instead of "the verifier changed after the commitment" (the client signed) |
| CL5 | client: output taken from the server's body, not the chain | e2e: "the client reports the output from the contract's event" |
| CL6 | client: settlement contract not checked | unit: "refuses another settlement contract" |
| CL7 | client: price ceiling not checked | unit: "refuses a price above its ceiling" |
| CL8 | client: commitment drawn before the server names its verifier | e2e: "the client knew the verifier before it committed" |
| MW1 | middleware: both proof failures reported as one errorReason | e2e: the three `wrong-entry -> invalid_proof_gated_evm_verifier_unavailable` checks |
| MW2 | middleware: the prover's commitment not checked | e2e: the proof about another input is settled ("not settled" and "nothing moved" fail) |
| MW3 | middleware: escrow flow releases without locking first | e2e: 7 checks of the escrow flow (`invalid_proof_gated_evm_not_open`, nothing locked) |

One mutation per check in `refusal()` (the client's checks before it signs), unit tests only:

| Id | Check made always to pass | Unit test that failed |
|---|---|---|
| RF1 | network | "refuses another network" |
| RF2 | asset | "refuses another asset" |
| RF3 | price ceiling | "refuses a price above its ceiling" |
| RF4 | token domain | "refuses a token domain that is not the token's" |
| RF5 | accepted verifier | "refuses a verifier it does not accept" |
| RF6 | settlement contract | "refuses another settlement contract" |
| RF7 | payment flow | "refuses an unknown payment flow" |
| RF8 | prove window | "refuses a prove window of zero or over a day" |
| RF9 | scheme | none at first; "refuses a scheme it does not know" was added, and fails |
| RF10 | escrow and operator type | "refuses another escrow" |
| RF11 | operator | "refuses another operator" |
| RF12 | policy | "refuses a policy" |
| RF13 | fees | "refuses fees" |
| RF14 | commitment present | "refuses an auth-capture offer before it has a commitment" |
| RF15 | commitment matches | "refuses an offer for another input" |
| RF-all | `refusal()` refuses every auth-capture and proof-gated offer | all 19, including "signs a proof-gated offer for this deployment" and "signs a bound auth-capture offer" |

The binding check itself is CL3 above. Every one of the 19 unit tests fails under at least one mutation.

Negative controls for the checks that are not tests:

| Id | Deliberate breakage | Result |
|---|---|---|
| CM1 | `clients/ts/src/commitment.ts` quantises at 2^12 instead of 2^13 | `npm run check-commitment`: `DIFFER`, exit 1 (the clean code gives `MATCH`) |
| CF1 | the client's `PaymentRequirements.amount` typed as a number | `npm --prefix x402 run typecheck`: 4 of the 5 assertions in `x402/client/conformance.ts` fail |
| CD1 | `scripts/check_deployment.py` given the deployment's two verifier transactions in swapped order | 4 checks fail (both code hashes, both entries), exit 1 |

## K=16 with the real proof (`test/ChannelSettlementK16Gas.t.sol`)

Run on 2026-11-24. 7 tests that run in CI: the K=16 verifier against the stored proof and a changed one, its registry entry, and four gas measurements (sixteen channels and one channel, first and steady), the steady one asserting the acceptance figure of 1,170,000. Each mutation was run against this file and reverted; the files were restored byte for byte.

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| KM1 | one output instance of the stored K=16 proof changed (417 to 418) | 6: the verifier accepts the stored proof; all four gas tests (`ProofInvalid()` in `setUp`, or the measured call fails) |
| KM2 | the K=16 verifier replaced by code that returns true for anything | 1: `test_k16_verifier_rejects_a_changed_proof` |
| KM3 | `ChannelSettlement._signedBy` reads the payer's code size before trying ECDSA | 4: `test_gas_k16_steady` (acceptance: 1,179,002 > 1,170,000) and the three other gas pins |

`test_k16_entry_is_registered_with_the_real_code` is a check of the test's own setup (the entry names the code at the verifier's address); KM2 leaves it passing because the replaced code is registered as it is.

## EXPERIMENTAL: the Groth16 prototype (`test/experimental/groth16/Groth16Prototype.t.sol`)

Single-party local setup, insecure for anything but measurement; a Poseidon2 input commitment, not the canonical one, so not the same statement. Run on 2026-11-24. 7 tests: the adapter accepts the prototype's proof, and rejects a changed proof, a changed output and another commitment; `settle` rejects a changed proof with `ProofInvalid()`; two gas measurements with upper pins. Each mutation was run against this file and reverted; the files were restored byte for byte.

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| GM1 | `Groth16Adapter.verify` returns true whatever the verifier says | 4: the three rejections by the adapter, and `settle` with a changed proof (it no longer reverts) |
| GM2 | the adapter writes each lane's commitment after its outputs | 3: the adapter accepts the proof; both gas measurements (the measured call fails) |
| GM3 | the last output word of the fixture changed | 3: the same three |

## Hygiene scan (`scripts/hygiene_scan.sh`)

The scan's own failure cases are kept as a script, `scripts/hygiene_selftest.sh`, and run in CI. It plants one violation per rule, checks that the scan reports it, and removes it:

| Planted violation | Finding the scan must report |
|---|---|
| A random address in a file outside `deployments/` | `FAIL address` |
| An address listed in `deployments/`, repeated in `specs/` | none: accepted |
| The same address in a file outside `specs/` and `deployments/` | `FAIL address` |
| An address not listed in `deployments/`, in `specs/` | `FAIL address` |
| The same address in `deployments/`, with a private reference tree that contains it | `FAIL private-ref`, without printing the value |
| A 64-hex value, bare and `0x`-prefixed | `FAIL value32` |
| An endpoint keyword | `FAIL keyword` |
| A PEM private-key header | `FAIL keyword` |
| A path into a home directory | `FAIL home-path` |
| A binary file that is not pinned | `FAIL binary` |
| One byte appended to a pinned file | `FAIL pinned` |

It also checks that the clean tree passes and that an address inside `deployments/` is accepted when no private reference tree objects.

The rule that lets `specs/` repeat the deployment's addresses was itself mutated on 2026-11-24, against the self-test, and restored byte for byte:

| Id | Deliberate breakage | Self-test cases that went wrong |
|---|---|---|
| HM1 | any address is accepted in `specs/` | 1: an address not in `deployments/` is caught in `specs/` |
| HM2 | an address listed in `deployments/` is accepted in every path | 1: the same address elsewhere is still caught |
| HM3 | the `specs/` rule removed | 4: the clean tree (the specification's reference addresses) and the cases that depend on it |

## The registry entry check (`scripts/test_verify_entry.py`)

Run on 2026-11-24 on the Mac. 19 unit tests, no EZKL and no network: Keccak test vectors and the pinned key and bytecode hashes; the metadata trailer's form; the registry id from every field but the addresses; and `compare` against an entry consistent with the pinned solo files, broken one way at a time. Each mutation was applied to `scripts/verify_entry.py`, the tests run, and the file restored byte for byte.

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| VM1 | the bytecode comparison compares the regenerated code with itself | 3: `test_code_byte_changed`, `test_code_appended_before_the_trailer`, `test_code_at_the_address_is_not_the_registered_code` |
| VM2 | `split_trailer` no longer checks the compiler version bytes | 1: `test_rejects_other_forms` |
| VM3 | the EIP-7702 delegation check always passes | 1: `test_delegated_verifier` |
| VM4 | `compute_id` leaves `verifyGas` out of the id | 3: `test_registered_ids`, `test_every_field_but_the_addresses_is_in_the_id`, `test_entry_not_the_registered_one` |
| VM5 | the `vkHash` comparison always passes | 1: `test_vk_changed` |
| VM6 | the verdict is MATCH if any check matches | 10: every `Compare` test with a failing check |
| VM7 | the entry is not authenticated against `entryHash` | 1: `test_entry_not_the_registered_one` |
| VM8 | SHA-3 padding (`0x06`) instead of Keccak's (`0x01`) | 15: the vectors, the pinned hashes and every test that hashes |
| VM9 | an unregistered entry counts as registered | 1: `test_not_registered` |
| VM10 | the trailer is cut by its length field alone, without checking its form | 3 subtests of `test_rejects_other_forms` |

On the server, one deliberately wrong input was run end to end: the pinned solo `settings.json` with its two range checks swapped. The script reported a different verifying key and verifier and exited 1 (`measurements/2026-11-24-verify-entry/`).

## x402 shape (a): the proof policy and the batch-settlement claim gate

Run on 2026-11-25. The work adds 42 tests that run in CI: 24 in `ProofCapturePolicy.t.sol`, 3 in `ProofCapturePolicyGas.t.sol` and 15 in `test/experimental/batch-gate/ProofClaimGate.t.sol`. Three more are opt-in USDC fork tests in `ProofCapturePolicyGas.t.sol`. With the earlier tests the suite is 440: 401 pass and 39 opt-in tests skip without a fork endpoint or the end-to-end run's files.

59 mutations were run, each against the files that can catch it, and each source was restored byte for byte. 58 were caught. Every one of the 45 new tests fails under at least one of them; `test_fork_gas_policy_authorize_steady` only through its suite's `setUp` (FP3), like FX1. The tables below are from a run against the final tests. An earlier run of the first 51 mutations, against the suite before `test_the_verifier_receives_exactly_its_allowance_through_the_policy` and `test_arguments_that_do_not_fit_the_entry_are_invalid_through_the_policy` existed, caught 49: PC4 survived because the EZKL adapter repeats the output-size check, and PC5 because 599,000 gas still covers the solo proof. Those two tests were written for them; PC6 was added with them.

### `src/ProofCapturePolicy.sol`, `src/ICapturePolicyStatus.sol` (`--match-path 'test/ProofCapturePolicy*.t.sol'`)

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| PP1 | salt: not compared (any terms open any payment) | 3: `test_a_refused_attempt_leaves_the_authorization_capturable`, `test_terms_the_payer_did_not_sign_are_denied_not_proof_invalid`, `test_the_boolean_hooks_are_true_only_for_authorized` |
| PP2 | policy address: any value accepted | 1: `test_a_salt_bound_to_another_policy_is_denied` |
| PP3 | could-not-check reported as invalid | 5: `test_a_refused_attempt_leaves_the_authorization_capturable`, `test_a_refused_charge_moves_nothing_and_the_authorization_stays_usable`, `test_after_refusals_the_payer_reclaims_from_the_capture_deadline_on`, `test_an_unknown_entry_is_refused_with_verifier_unavailable_never_proof_invalid`, `test_changed_code_is_refused_with_verifier_unavailable_never_proof_invalid` |
| PP4 | invalid reported as could-not-check | 6: `test_a_refused_attempt_leaves_the_authorization_capturable`, `test_a_refused_charge_moves_nothing_and_the_authorization_stays_usable`, `test_after_refusals_the_payer_reclaims_from_the_capture_deadline_on`, `test_an_invalid_proof_is_refused_with_proof_invalid`, `test_arguments_that_do_not_fit_the_entry_are_invalid_through_the_policy`, `test_terms_the_payer_did_not_sign_are_denied_not_proof_invalid` |
| PP5 | invalid proof authorized | 7: `test_a_refused_attempt_leaves_the_authorization_capturable`, `test_a_refused_charge_moves_nothing_and_the_authorization_stays_usable`, `test_after_refusals_the_payer_reclaims_from_the_capture_deadline_on`, `test_an_invalid_proof_is_refused_with_proof_invalid`, `test_arguments_that_do_not_fit_the_entry_are_invalid_through_the_policy`, `test_terms_the_payer_did_not_sign_are_denied_not_proof_invalid`, `test_the_boolean_hooks_are_true_only_for_authorized` |
| PP6 | could-not-check reported as denied | 5: `test_a_refused_attempt_leaves_the_authorization_capturable`, `test_a_refused_charge_moves_nothing_and_the_authorization_stays_usable`, `test_after_refusals_the_payer_reclaims_from_the_capture_deadline_on`, `test_an_unknown_entry_is_refused_with_verifier_unavailable_never_proof_invalid`, `test_changed_code_is_refused_with_verifier_unavailable_never_proof_invalid` |
| PP7 | salt nonce ignores the input commitment | 2: `test_terms_the_payer_did_not_sign_are_denied_not_proof_invalid`, `test_the_status_words_and_the_salt_follow_the_derivation` |
| PP8 | salt bound with policy zero whatever the data says | 1: `test_terms_the_payer_did_not_sign_are_denied_not_proof_invalid` |
| PP9 | boolean capture hook true unless invalid | 1: `test_the_boolean_hooks_are_true_only_for_authorized` |
| PP10 | boolean charge hook true unless invalid | 1: `test_the_boolean_hooks_are_true_only_for_authorized` |
| PP11 | chargeStatus always authorized | 1: `test_a_refused_charge_moves_nothing_and_the_authorization_stays_usable` |
| PP12 | captureStatus always authorized | 8: `test_a_refused_attempt_leaves_the_authorization_capturable`, `test_a_salt_bound_to_another_policy_is_denied`, `test_after_refusals_the_payer_reclaims_from_the_capture_deadline_on`, `test_an_invalid_proof_is_refused_with_proof_invalid`, `test_an_unknown_entry_is_refused_with_verifier_unavailable_never_proof_invalid`, `test_arguments_that_do_not_fit_the_entry_are_invalid_through_the_policy`, `test_changed_code_is_refused_with_verifier_unavailable_never_proof_invalid`, `test_terms_the_payer_did_not_sign_are_denied_not_proof_invalid` |
| PP13 | ERC-165: any interface claimed | 1: `test_supports_its_interface_and_erc165_only` |
| PP14 | status word: Authorized spelled otherwise | 1: `test_the_status_words_and_the_salt_follow_the_derivation` |
| PP15 | status words: VerifierUnavailable collapsed into ProofInvalid | 1: `test_the_status_words_and_the_salt_follow_the_derivation` |

### `src/ProofCheck.sol`, `checkOneInMemory` (`--match-path 'test/ProofCapturePolicy*.t.sol'`)

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| PC1 | checkOneInMemory: code hashes not checked | 4: `test_a_refused_attempt_leaves_the_authorization_capturable`, `test_a_refused_charge_moves_nothing_and_the_authorization_stays_usable`, `test_after_refusals_the_payer_reclaims_from_the_capture_deadline_on`, `test_changed_code_is_refused_with_verifier_unavailable_never_proof_invalid` |
| PC2 | checkOneInMemory: entry not compared with the registered hash | 1: `test_an_unknown_entry_is_refused_with_verifier_unavailable_never_proof_invalid` |
| PC3 | checkOneInMemory: unknown id passes on to the code check | 1: `test_an_unknown_entry_is_refused_with_verifier_unavailable_never_proof_invalid` |
| PC4 | checkOneInMemory: output size not checked | 1: `test_arguments_that_do_not_fit_the_entry_are_invalid_through_the_policy` |
| PC5 | checkOneInMemory: verifier given 1,000 gas less than its allowance | 1: `test_the_verifier_receives_exactly_its_allowance_through_the_policy` |
| PC6 | checkOneInMemory: lane count not checked | 1: `test_arguments_that_do_not_fit_the_entry_are_invalid_through_the_policy` |

### `src/PolicyCaptureOperator.sol` (the same)

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| PO1 | any non-zero word accepted | 9: `test_a_refused_attempt_leaves_the_authorization_capturable`, `test_a_refused_charge_moves_nothing_and_the_authorization_stays_usable`, `test_a_salt_bound_to_another_policy_is_denied`, `test_after_refusals_the_payer_reclaims_from_the_capture_deadline_on`, `test_an_invalid_proof_is_refused_with_proof_invalid`, `test_an_unknown_entry_is_refused_with_verifier_unavailable_never_proof_invalid`, `test_changed_code_is_refused_with_verifier_unavailable_never_proof_invalid`, `test_terms_the_payer_did_not_sign_are_denied_not_proof_invalid`, `test_the_operator_refuses_every_word_but_authorized` |
| PO2 | the word is not checked | 9: `test_a_refused_attempt_leaves_the_authorization_capturable`, `test_a_refused_charge_moves_nothing_and_the_authorization_stays_usable`, `test_a_salt_bound_to_another_policy_is_denied`, `test_after_refusals_the_payer_reclaims_from_the_capture_deadline_on`, `test_an_invalid_proof_is_refused_with_proof_invalid`, `test_an_unknown_entry_is_refused_with_verifier_unavailable_never_proof_invalid`, `test_changed_code_is_refused_with_verifier_unavailable_never_proof_invalid`, `test_terms_the_payer_did_not_sign_are_denied_not_proof_invalid`, `test_the_operator_refuses_every_word_but_authorized` |
| PO3 | every refusal reported as ProofInvalid | 8: `test_a_refused_attempt_leaves_the_authorization_capturable`, `test_a_refused_charge_moves_nothing_and_the_authorization_stays_usable`, `test_a_salt_bound_to_another_policy_is_denied`, `test_after_refusals_the_payer_reclaims_from_the_capture_deadline_on`, `test_an_unknown_entry_is_refused_with_verifier_unavailable_never_proof_invalid`, `test_changed_code_is_refused_with_verifier_unavailable_never_proof_invalid`, `test_terms_the_payer_did_not_sign_are_denied_not_proof_invalid`, `test_the_operator_refuses_every_word_but_authorized` |
| PO4 | capture: one unit instead of the whole hold | 9: `test_a_hold_is_captured_once`, `test_a_payment_bound_with_the_policy_address_is_answered_too`, `test_a_refused_attempt_leaves_the_authorization_capturable`, `test_a_valid_proof_authorizes_and_anyone_captures_for_the_receiver`, `test_gas_capture_with_policy_steady`, `test_only_the_receiver_can_give_the_hold_back_early`, `test_the_fee_taken_is_the_payers_minimum`, `test_the_operator_refuses_every_word_but_authorized`, `test_too_little_gas_reverts_with_a_typed_error_not_a_refusal` |
| PO5 | fee: the payer's maximum | 1: `test_the_fee_taken_is_the_payers_minimum` |
| PO6 | charge: the escrow's charge reachable without the policy | 2: `test_gas_charge_with_policy_steady`, `test_the_escrows_charge_is_not_reachable_without_the_policy` |
| PO7 | chargeWithPolicy: status not checked | 1: `test_a_refused_charge_moves_nothing_and_the_authorization_stays_usable` |
| PO8 | chargeWithPolicy: less than the maximum | 3: `test_a_refused_charge_moves_nothing_and_the_authorization_stays_usable`, `test_charge_with_a_valid_proof_pays_the_receiver_in_one_step`, `test_gas_charge_with_policy_steady` |
| PO9 | authorize: a partial amount accepted | 1: `test_authorize_must_collect_the_full_amount` |
| PO10 | void: anyone | 1: `test_only_the_receiver_can_give_the_hold_back_early` |
| PO11 | capture: event without the policy data hash | 1: `test_a_valid_proof_authorizes_and_anyone_captures_for_the_receiver` |
| PO12 | charge: event with the wrong amount | 1: `test_charge_with_a_valid_proof_pays_the_receiver_in_one_step` |
| PO13 | void: no event | 1: `test_only_the_receiver_can_give_the_hold_back_early` |
| PO14 | capture: the hold read twice (gas) | 1: `test_gas_capture_with_policy_steady` |
| PO15 | authorize: does not forward to the escrow | 13: `setUp` of the gas suite, `test_a_hold_is_captured_once`, `test_a_payment_bound_with_the_policy_address_is_answered_too`, `test_a_refused_attempt_leaves_the_authorization_capturable`, `test_a_valid_proof_authorizes_and_anyone_captures_for_the_receiver`, `test_after_refusals_the_payer_reclaims_from_the_capture_deadline_on`, `test_an_invalid_proof_is_refused_with_proof_invalid`, `test_an_unknown_entry_is_refused_with_verifier_unavailable_never_proof_invalid`, `test_changed_code_is_refused_with_verifier_unavailable_never_proof_invalid`, `test_only_the_receiver_can_give_the_hold_back_early`, `test_the_fee_taken_is_the_payers_minimum`, `test_the_operator_refuses_every_word_but_authorized`, `test_too_little_gas_reverts_with_a_typed_error_not_a_refusal` |
| PO16 | authorize: the hold read once more (gas) | 1: `test_gas_policy_authorize_steady` |

### `test/experimental/batch-gate/ProofClaimGate.sol` (`--match-path 'test/experimental/batch-gate/*.t.sol'`)

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| G1 | leaf does not bind the position | 8: `test_a_check_that_cannot_run_is_unavailable_not_invalid`, `test_a_proven_request_at_its_signed_position_is_claimed_and_paid_out`, `test_an_invalid_proof_is_refused_and_the_position_stays_open`, `test_base_claimed_carries_earlier_batches`, `test_every_position_of_batches_of_one_to_nine_opens_only_where_it_is`, `test_gas_claim_with_proof_first_claim_of_the_channel`, `test_gas_claim_with_proof_steady`, `test_one_proof_claims_one_unit_and_a_position_counts_once` |
| G2 | path direction ignored | 8: `test_a_check_that_cannot_run_is_unavailable_not_invalid`, `test_a_proven_request_at_its_signed_position_is_claimed_and_paid_out`, `test_an_invalid_proof_is_refused_and_the_position_stays_open`, `test_base_claimed_carries_earlier_batches`, `test_every_position_of_batches_of_one_to_nine_opens_only_where_it_is`, `test_gas_claim_with_proof_first_claim_of_the_channel`, `test_gas_claim_with_proof_steady`, `test_one_proof_claims_one_unit_and_a_position_counts_once` |
| G3 | position range not checked | 1: `test_a_commitment_claimed_at_a_position_it_does_not_hold_is_refused` |
| G4 | path length not checked | **none: survived, see below** |
| G5 | root signature not checked | 3: `test_a_root_signed_for_another_gate_does_not_open_this_one`, `test_a_root_signed_for_one_channel_does_not_open_another`, `test_a_root_the_payer_did_not_sign_is_refused` |
| G6 | root digest omits the channel | 9: `test_a_check_that_cannot_run_is_unavailable_not_invalid`, `test_a_commitment_claimed_at_a_position_it_does_not_hold_is_refused`, `test_a_proven_request_at_its_signed_position_is_claimed_and_paid_out`, `test_an_invalid_proof_is_refused_and_the_position_stays_open`, `test_base_claimed_carries_earlier_batches`, `test_gas_claim_with_proof_first_claim_of_the_channel`, `test_gas_claim_with_proof_steady`, `test_one_proof_claims_one_unit_and_a_position_counts_once`, `test_the_proof_must_be_for_the_included_commitment` |
| G7 | root digest omits the price | 9: `test_a_check_that_cannot_run_is_unavailable_not_invalid`, `test_a_commitment_claimed_at_a_position_it_does_not_hold_is_refused`, `test_a_proven_request_at_its_signed_position_is_claimed_and_paid_out`, `test_an_invalid_proof_is_refused_and_the_position_stays_open`, `test_base_claimed_carries_earlier_batches`, `test_gas_claim_with_proof_first_claim_of_the_channel`, `test_gas_claim_with_proof_steady`, `test_one_proof_claims_one_unit_and_a_position_counts_once`, `test_the_proof_must_be_for_the_included_commitment` |
| G8 | a position counts twice | 1: `test_one_proof_claims_one_unit_and_a_position_counts_once` |
| G9 | ceiling from the batch size, not the proven count | 1: `test_one_proof_claims_one_unit_and_a_position_counts_once` |
| G10 | baseClaimed ignored | 2: `test_base_claimed_carries_earlier_batches`, `test_gas_claim_with_proof_steady` |
| G11 | could-not-check reported as invalid | 1: `test_a_check_that_cannot_run_is_unavailable_not_invalid` |
| G12 | invalid proof accepted | 2: `test_an_invalid_proof_is_refused_and_the_position_stays_open`, `test_the_proof_must_be_for_the_included_commitment` |
| G13 | receiver not required to be the gate | 1: `test_a_channel_whose_receiver_is_not_the_gate_is_refused` |
| G14 | payout does not forward | 1: `test_a_proven_request_at_its_signed_position_is_claimed_and_paid_out` |
| G15 | inclusion not checked | 1: `test_a_commitment_claimed_at_a_position_it_does_not_hold_is_refused` |
| G16 | event without the output | 1: `test_a_proven_request_at_its_signed_position_is_claimed_and_paid_out` |
| G17 | proof checked against the root instead of the commitment | 6: `test_a_proven_request_at_its_signed_position_is_claimed_and_paid_out`, `test_an_invalid_proof_is_refused_and_the_position_stays_open`, `test_base_claimed_carries_earlier_batches`, `test_gas_claim_with_proof_first_claim_of_the_channel`, `test_gas_claim_with_proof_steady`, `test_one_proof_claims_one_unit_and_a_position_counts_once` |
| G18 | gate answers ERC-1271 for any signature | 1: `test_without_the_gate_nobody_claims_or_signs_for_its_channel` |

### Fork suite (`test/ProofCapturePolicyGas.t.sol`, real USDC, `FORK_BLOCK=62638490`)

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| FP1 | fork: capture one unit instead of the whole hold | 2: `test_fork_gas_capture_with_policy_steady`, `test_gas_capture_with_policy_steady` |
| FP2 | fork: charge less than the maximum | 2: `test_fork_gas_charge_with_policy_steady`, `test_gas_charge_with_policy_steady` |
| FP3 | fork: authorize does not forward to the escrow | 2 (the `setUp` of both gas suites, the fork suite's included) |

### Escrow source (`lib/commerce-payments`, restored after the run)

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| EX1 | escrow: capture does not check the operator (escrow source) | 1: `test_a_payment_for_another_operator_cannot_be_captured_here` |


### Survivor

- **G4** (the gate does not check the path's length). Equivalent as far as a test can tell: a path of the wrong length opens the root only if a leaf hash, the hash of 96 bytes, equals an inner node, the hash of 64, or the hash chain continues past the root to equal it, and either needs a keccak256 collision or preimage. The check stays as defence in depth; the proposal lists the tree encoding as an open point.
