

## PROTOTYPE: hash-only `policyData` (`test/experimental/hash-policy/`, branch `hash-policy`)

Run on 2026-11-25. 10 mutations of `RecordedProofPolicy.sol`, run with `--match-path 'test/experimental/hash-policy/*.t.sol'` and restored byte for byte afterwards. All were caught. `setUp` in a row is the gas suite's: under HP10 its own capture is refused.

| Id | Deliberate breakage | Tests that failed |
|---|---|---|
| HP1 | the record key omits the input commitment | 1: `test_a_valid_record_for_another_commitment_does_not_open_this_payment` |
| HP2 | no record reads as ProofInvalid | 3: `test_a_proof_can_be_presented_again_after_verifier_unavailable`, `test_a_valid_record_for_another_commitment_does_not_open_this_payment`, `test_an_unrecorded_hash_is_verifier_unavailable_never_proof_invalid` |
| HP3 | a check that cannot run is stored as Invalid | 1: `test_a_proof_can_be_presented_again_after_verifier_unavailable` |
| HP4 | a recorded Invalid reads as Authorized | 1: `test_a_recorded_invalid_proof_is_proof_invalid_and_does_not_block_the_real_one` |
| HP5 | every checked proof is recorded Valid | 2: `test_a_record_never_changes`, `test_a_recorded_invalid_proof_is_proof_invalid_and_does_not_block_the_real_one` |
| HP6 | the salt is not compared | 1: `test_terms_the_payer_did_not_sign_are_denied_even_with_a_valid_record` |
| HP7 | the policy address is not checked | 1: `test_a_salt_bound_to_another_policy_is_denied` |
| HP8 | a stored result is checked again instead of returned | 1: `test_a_record_never_changes` |
| HP9 | the record event without the output | 1: `test_anyone_records_anyone_captures_and_the_output_is_in_the_record_event` |
| HP10 | the record key hashes the proof without the output | 4: `setUp`, `test_a_proof_can_be_presented_again_after_verifier_unavailable`, `test_a_recorded_invalid_proof_is_proof_invalid_and_does_not_block_the_real_one`, `test_anyone_records_anyone_captures_and_the_output_is_in_the_record_event` |
