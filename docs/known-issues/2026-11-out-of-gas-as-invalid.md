# Known issue: a verifier that runs out of gas reads as Invalid

Found 2026-11-26 while drafting the proof-verifier-registry ERC. Affects every contract of `v3.0.0-testnet` on Base Sepolia. Testnet only. No funds can be released on an invalid proof; a valid proof can be refused.

## What happens

`ProofCheck` hands the adapter exactly the entry's `verifyGas`, and reads the adapter's answer as `Valid` only if it is the word `1`. Everything else was read as `Invalid`: a revert, running out of gas, any other answer.

The deployed `Halo2EzklAdapter` calls the EZKL verifier with all the gas it has, and answers `false` when the call fails. A generated EZKL verifier rejects a proof by reverting with no data. A verifier that runs out of gas also reverts with no data. The adapter cannot tell the two apart, so it answers `false` for both, and the check reads both as `Invalid`.

So if verifying a valid proof ever costs more than the entry's `verifyGas`, the proof reads as `Invalid`. That breaks core property 1 of the specification ([proof_condition.md](../../specs/schemes/proof-gated/proof_condition.md#core-properties)): "could not be checked" never becomes `ProofInvalid`.

The cost of a verification is set by the chain's gas schedule, and hard forks change it. It has happened once already: Osaka repriced `MODEXP` (EIP-7883), and one verification of either pinned verifier now costs exactly **8,097 gas more**. Three `MODEXP` calls went from 1,349 to 4,048 gas each: solo 577,544 against 569,447 under Prague or Cancun, K=8 635,807 against 627,710 ([MEASUREMENTS.md](../../MEASUREMENTS.md); mutation FB6 in [test/MUTATIONS.md](../../test/MUTATIONS.md)).

## Base Sepolia already prices it this way

Checked 2026-11-27, Base Sepolia block 63,995,885. A gauge contract injected with an `eth_call` state override measured one call of the deployed solo verifier with the fixture proof: 580,176 gas. The same gauge on local Anvil nodes with the same runtime code gave 580,176 under Osaka and 572,079 under Prague. Each figure includes the gauge's own call, including the first-touch charge for the verifier's account. The difference is the 8,097 above. So the entries' headroom below is the headroom on the chain today.

## Affected entries

Both entries registered by `v3.0.0-testnet` (ids in [deployments/base-sepolia.json](../../deployments/base-sepolia.json), `verifierIds`). Registry entries are immutable, so these stay as they are.

"Used" is gas used by the adapter call inside a check. A check reads both code hashes first, so the adapter and the verifier accounts are warm. "First call" is the same call with both accounts cold, as when the adapter is called directly. Measured in `forge test`, Osaka, `test/OutOfGasClassification.t.sol` (`test_headroom_of_the_deployed_solo_entry`, `test_headroom_of_the_deployed_k8_entry`).

| Entry | `verifyGas` | Used, valid proof, in a check | Left unspent | First call, cold | Left unspent |
|---|---:|---:|---:|---:|---:|
| solo | 600,000 | 580,620 | 19,380 (3.2%) | 585,620 | 14,380 (2.4%) |
| K=8 | 660,000 | 641,365 | 18,635 (2.8%) | 646,365 | 13,635 (2.1%) |

The ERC draft's probe gave 643,865 for K=8 (2.4% headroom). That figure has one account warm and one cold: the probe's warm-up reads of the code hashes were never used, so the compiler removed them. A repricing that adds a little more than twice the Osaka change to a verification would turn every valid proof against these entries into `Invalid`: 19,380 gas for solo, 18,635 for K=8.

## Impact

- **A provider's valid proof is refused.** Every contract that checks a proof reverts on `Invalid`: the settlement contracts, the ERC-8183 evaluator, the ERC-8004 validator and the `auth-capture` operator. The provider is not paid for work it did and can prove. Under the host protocols' own deadlines the funds go back to the payer: `reclaim` after the capture deadline, the channel's prove window, the job's expiry.
- **The wrong reason is reported.** The refusal says `ProofInvalid`, where it should say `VerifierUnavailable`. A client or indexer that counts `ProofInvalid` against a provider counts a false rejection.
- **Never a payment released on an invalid proof.** `Valid` still requires the adapter's word `1`, which a verifier that ran out of gas cannot produce. Running out of gas can only turn acceptance into refusal, never the reverse.
- **No state is written on either outcome.** Every consumer reverts on both, so there is nothing to correct on chain.

## The fix (v3.1)

The ERC draft's step 6, with a threshold of 1/16.

**What exhaustion leaves.** A call that forwards all its gas keeps 1/64 of it back (EIP-150). When the innermost call of a chain of `d` such calls runs out of gas, each level gets back what it kept. About `verifyGas · (1 − (63/64)^d)` is left unspent. The ERC draft's probe measured the cases below, at a 600,000 allowance, in the private draft's working files. They are ported as tests in `test/OutOfGasClassification.t.sol`.

| Depth below the adapter | Measured unspent |
|---|---:|
| d = 1, the verifier loops | 1.11% |
| d = 2, the verifier calls `MODEXP` | 3.04% |
| d = 3 | 4.54% |
| d = 4 | 6.02% |
| d = 5 | 7.46% |

A precompile given bad input also consumes all the gas it is given, for example `ECPAIRING` with a point off the curve. That is d = 2 for a verifier that calls it directly.

**The rule.**

- `ProofCheck` returns `Invalid` only in two cases. The arguments do not fit the entry. Or the adapter answered `false` and left more than `verifyGas / 16` (6.25%) unspent.
- Everything else is `Unverifiable`: a revert, running out of gas, an answer that is not the word `0` or `1`, and a `false` that left `verifyGas / 16` or less.
- An entry whose verifier nests all-gas calls deeper than 4 below the adapter must not be registered, because at d = 5 exhaustion leaves more than 1/16.
- `Halo2EzklAdapterV2` applies the same rule to its own call to the verifier. If the verifier did not accept and the adapter has no more than 1/16 of the gas it started with left, it reverts with `TargetGasExhausted`. It answers `false` only for a rejection with gas to spare, or for a statement it refuses before calling the verifier (shape, field).
- `ProofStatus` is renumbered as in the ERC draft: `Unverifiable = 0`, `Valid = 1`, `Invalid = 2`. A status nobody set now reads as "nothing was decided", not as a rejection.

**New entries.** They are sized at 1.10 times the measured first-call valid path of adapter V2 (accounts cold). That leaves room for a repricing and keeps every real rejection above the 1/16 line.

| Entry | First call, valid proof (V2) | 1.10 × | `verifyGas` | Wrong output, in a check (V2) | Left unspent |
|---|---:|---:|---:|---:|---:|
| solo | 585,667 | 644,234 | 645,000 | 580,685 | 64,315 (10.0%) |
| K=8 | 646,412 | 711,053 | 712,000 | 641,430 | 70,570 (9.9%) |

The first-call figure is 5,000 above the in-check figure. That is the EIP-2929 charge for two cold accounts, 2,500 each for the adapter and the verifier. `test_first_call_surcharge_is_eip2929_and_new_entries_are_sized_over_it` shows it: with only the verifier cold, the difference is 2,500. Reading both code hashes first, as a check does, removes it (`test_extcodehash_removes_the_first_call_surcharge`).

With these entries a valid proof stays `Valid` until a repricing adds more than 64,333 gas (solo) or 70,588 gas (K=8) to the in-check path. A rejection at the final pairing stays `Invalid` until a repricing adds 24,003 gas (solo) or 26,070 gas (K=8) to it (`test_wrong_output_against_both_allowances`). Beyond that it reads as `Unverifiable`, which fails safe.

**What the deployed entries do under the new check.** A valid proof is `Valid`, and a proof rejected early (a changed byte) is `Invalid`. A wrong output, rejected at the final pairing, leaves only about 3% unspent and reads as `Unverifiable`. `test_deployed_entries_report_a_final_pairing_rejection_as_unverifiable` shows this. It fails safe; new deployments should use the new entries.

**A consequence for proofs with a point off the curve.** A verifier that hands such a point to a BN254 precompile sees the precompile consume all its gas. That reads as `Unverifiable`, not `Invalid`. This affects, for example, the experimental Groth16 adapter (`test_g16_settle_rejects_a_changed_proof`). Nothing is paid either way. A third party can make any attempt read `Unverifiable` instead of `Invalid`, but it cannot make one read `Valid`.

## What has to be redeployed

`ProofCheck` is an internal library, compiled into each contract that checks a proof. Every deployed contract that embeds it needs a new version:

- `SoloSettlement`
- `ChannelSettlement`
- `ProofEvaluator8183`
- `ProofValidator8004`
- `AuthCaptureProofOperator`

`ProofValidator8004` is deployed in a second step, later than the other four, so that the source it is verified against is the one on `main`. Until then the `v3.0.0-testnet` validator stays in use.

Not redeployed:

- `VerifierRegistry` does not embed `ProofCheck`. It is append-only, and the new entries are added to it.
- The two EZKL verifiers are unchanged and reused.
- The deployed `Halo2EzklAdapter` stays, because the deployed entries pin its code. The new entries use `Halo2EzklAdapterV2`.

The `v3.0.0-testnet` contracts keep their own check. They can also use the new entries, because every one of them takes the verifier id per payment, job, request or channel. With the new entries a valid proof no longer runs short of gas there either. Those contracts still read `TargetGasExhausted` and any other failure as `Invalid`, as before.

## Deployment on Base Sepolia (prepared, not run)

`script/DeployV31BaseSepolia.s.sol` reads the v3.0 registry and verifiers from [deployments/base-sepolia.json](../../deployments/base-sepolia.json). Before it sends anything, it checks the chain as the v3.0 script did:

- the ERC-8004 registries' implementations;
- x402's escrow and collector code;
- the deployer's USDC for the seeds.

It also checks what it reuses:

- that the registry's code is `VerifierRegistry`;
- that both v3.0 entries are registered, with the pinned verifiers;
- that the v3.1 entries do not exist yet.

`run()` refuses, so that this file can never run the v3.0 deployment it inherits. `runV31()` deploys everything but `ProofValidator8004`. `runV31Validator()`, the second step, deploys the validator into the registry recorded for v3.1, after checking the chain again and that both v3.1 entries exist. `test/DeployV31BaseSepolia.t.sol` runs both against local copies, including one test for each refusal.

```
forge script script/DeployV31BaseSepolia.s.sol --sig "runV31()" --rpc-url <rpc> --account <keystore>                      (simulation)
forge script script/DeployV31BaseSepolia.s.sol --sig "runV31()" --rpc-url <rpc> --account <keystore> --broadcast --slow
forge script script/DeployV31BaseSepolia.s.sol --sig "runV31Validator()" --rpc-url <rpc> --account <keystore> --broadcast --slow
```

**Rehearsal, 2026-11-27.** On a local fork of Base Sepolia (block 64,015,747), sent from the v3.0 deployer's address with Anvil's impersonation, nothing sent to the chain. All 10 transactions succeeded, 8,454,955 gas:

| # | Transaction | Gas |
|---:|---|---:|
| 1 | `Halo2EzklAdapterV2` | 364,033 |
| 2 | register solo, `verifyGas` 645,000 | 171,913 |
| 3 | register K=8, `verifyGas` 712,000 | 171,925 |
| 4 | `SoloSettlement` | 1,219,729 |
| 5 | `ChannelSettlement` | 2,650,420 |
| 6 | seed `SoloSettlement`, 1 unit of USDC | 62,135 |
| 7 | seed `ChannelSettlement`, 1 unit of USDC | 62,135 |
| 8 | `ProofEvaluator8183` | 1,234,508 |
| 9 | `ProofValidator8004` (second step) | 950,142 |
| 10 | `AuthCaptureProofOperator` | 1,568,015 |

Without the validator, the first step is 9 transactions and 7,504,813 gas. Its dry run against the chain itself on 2026-11-27 passed every preflight check: forge estimated 9,808,253 gas at 0.0101 gwei, 0.000099 ETH. An earlier dry run of all ten transactions, with gas limits of 11,043,437 in total (forge's 1.3 margin), also passed. Both estimates are before the L1 data fee. The v3.0 deployment, 16.9 million gas, cost 0.000101 ETH in all. The v3.0 deployer holds enough ETH and USDC.

The new ids:

- solo `0x660e857f…c1e1`
- K=8 `0x81e1e628…c286`

**After the deployment:**

1. Record the new addresses and ids in `deployments/` as a v3.1 section next to v3.0's.
2. Verify the new contracts on Sourcify and Blockscout, as for v3.0.
3. Re-measure the figures in `MEASUREMENTS.md` on the 3.1 code.
4. Point the quickstart and the client's known verifier ids at the new entries.
5. Tag `v3.1.0-testnet`.
