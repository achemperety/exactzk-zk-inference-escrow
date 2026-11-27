# Test vectors

## ERC-8505: an ERC-8183 job that lapsed after delivery

[`erc8505-erc8183-lapsed-after-delivery.json`](erc8505-erc8183-lapsed-after-delivery.json) is one test vector for ERC-8505 (Evaluated Work Records). It has the shape of that ERC's `assets/erc-8505/vectors.json`. It covers the case the ERC's own vectors cannot: an ERC-8183 job with a proof-checking evaluator. The provider delivered, nobody presented a proof, the job expired, and the client took the budget back.

### The job

Base Sepolia (chain id 84532), 2026-11-27 (UTC), blocks 64,281,262 to 64,283,748. Run by [`script/Vector8183Expired.s.sol`](../../script/Vector8183Expired.s.sol) at commit `c828a22` and tested by `test/Vector8183Expired.t.sol`. The addresses are in [`deployments/base-sepolia-erc8183-test.json`](../../deployments/base-sepolia-erc8183-test.json), a test-only deployment.

- **Job contract.** The ERC-8183 reference implementation as the ERC's text gives it (`test/external/erc8183/`, see `test/external/README.md`), behind an ERC-1967 proxy. It pays in testnet USDC and charges no fee. The account that deployed it renounced both admin roles right after initialising it, so nobody can upgrade it, set a fee or allow a hook. ERC-8183 names no deployment of its own, and no published deployment of the reference contract on Base Sepolia was found.
- **Evaluator.** `ProofEvaluator8183` v3.1 (`deployments/base-sepolia-v3.1.json`).
- **Terms.** While the job was Open, the client named the v3.1 solo entry and the input commitment of the solo proof stored in `test/fixtures/`. The provider submitted `keccak256` of that proof's output. That proof would have completed the job before `expiredAt` (`test_before_expiry_the_stored_proof_would_have_completed_it`), but nobody presented it.
- **Roles.** The client and the provider are fresh testnet-only addresses, created for this job and used for nothing else. A third testnet-only account funded them and deployed the job contract; it is not recorded here.
- **Expiry.** The reference contract requires `expiredAt` more than 5 minutes after the block that creates the job. The script set it 7 minutes after that block's simulated time, at 1,795,778,564. `submit` was mined 402 seconds before that time and `claimRefund` 54 seconds after it. Before sending `claimRefund`, the script checked by a call that sends nothing that the evaluator refused even the valid stored proof with `JobExpired`.
- **Money.** 10,000 USDC units moved from the client to the job contract in `fund` and back in `claimRefund`. The job contract holds none.

### Transactions

All 14 succeeded; 4,223,623 gas in all.

| # | Block | From | Call | Hash |
|---:|---:|---|---|---|
| 1 | 64,281,262 | funder | ETH to the client | `0xa46f958afc0a14d8bbeeeb0540031e0a2b0d0e50338b532fb262f4f8b42649d9` |
| 2 | 64,281,266 | funder | ETH to the provider | `0x33490d18df2a85790a9bd4da7cf11c065e5ad97525fc4bbca1bc9c27507ef006` |
| 3 | 64,281,270 | funder | 0.01 USDC to the client | `0xee196db1c1ff17dd0ef4c0282c46b664ea50791d13541d9e31b5c0edf87ad37e` |
| 4 | 64,281,323 | funder | create `AgenticCommerce` (implementation) | `0xc79cab04f25ca84a2c85f0025a6ee05ae76eba57ef8ed3abf5e69a9aaf0d05df` |
| 5 | 64,281,327 | funder | create the proxy, `initialize` | `0xf6c615c25e0ad625629e4a20a44ba5564d606aa9bf372747e5b9106021765de2` |
| 6 | 64,281,331 | funder | `renounceRole(ADMIN_ROLE)` | `0x55ad8c721839f15305b05cda8782ce19ad7cdfdca24b24e3ea35368d9b1842d9` |
| 7 | 64,281,335 | funder | `renounceRole(DEFAULT_ADMIN_ROLE)` | `0x3b233c6cffc81e4593154b3e627d90e2dd0f281fe19e72c988b9063c21880f12` |
| 8 | 64,281,449 | client | `createJob` (job 1) | `0x3f3ede9c53dfe788b785904e8742cee9d51a3eee4a9ffde78ce7f7fe6cc7b4bd` |
| 9 | 64,281,453 | client | `setTerms` on the evaluator | `0x40b7aee20b4ba37fba58f896d3f282fac0497ab8cc1d147e27df276870feb243` |
| 10 | 64,281,457 | provider | `setBudget` (10,000) | `0xb69d2b9ea26dc3f3292315019077d9ba246d38a86053351aee6d80e80507511e` |
| 11 | 64,281,461 | client | USDC `approve` | `0x8b91f5239d10981e6f9a969502a9f87afb4d048a06708c79946526fc22e6dd26` |
| 12 | 64,281,465 | client | `fund` | `0xa6f0feb743175b1bff95b957ddfbfd0db49008c97fcbb298f1b3b86060478544` |
| 13 | 64,281,470 | provider | `submit` | `0x5a38a23f5d99aa4062a0e76a709e9bfb4d4eab42327ec5178ceebe2d6ca336e0` |
| 14 | 64,283,748 | client | `claimRefund` | `0xb922367ac1260e6c7609af31e969664ec5c9490dd63ec33b89d56ef09765cff9` |

The vector's `logs` are the job's `JobCreated` (8), `JobFunded` (12), `JobSubmitted` (13) and `Refunded` (14). The job also emitted `BudgetSet` (10) and `JobExpired` (14); the descriptor does not declare them, so they are not steps.

### The expected result, and the text it was checked against

ERC-8505 is a draft. The expected result was checked against `ERCS/erc-8505.md` in ethereum/ERCs PR #2185 at commit `9f49fb912aad69c94e1103c327e6300b436c408c` (SHA-256 of the file `8f2f07c44b34908d4b816c80e6e02989b83747a9c30c3758e7cd115386bd32a9`):

- **Outcomes, lines 217–220.** The job has `assigned` (`JobCreated`), `funded`, `delivered` and `refunded` steps and no `verdict` step, so rule 4 applies: "No `verdict` step after the last `delivered` step: `lapsed` after `delivered`." It is consistent: one `funded` step, before the delivery; one terminal step in its transaction; the refund equals the funded amount; the delivery names the job's provider.
- **Entries, lines 247–252.** `lapsed` after `delivered` takes `tag1` `work.lapsed`, `tag2` `delivered`, `value` 0, and "The `value` of a `work.lapsed` entry carries no score. Each reader sets the weight of a lapse."
- **Reading on chain, lines 448–451.** `getSummary(agentId, writers, "work.outcome", "")` gives the share accepted, and "Lapses never enter the share accepted". `getSummary(agentId, writers, "work.lapsed", "")` counts lapses. A call with an empty `tag1` does not filter by tag in the ERC-8004 Reputation Registry, so it would average the lapse's 0 with everything else; the profile does not use that call.

The rationale, lines 473–476, says the same for ERC-8183 directly: a job "that expires after submission gets a `work.lapsed` entry". Earlier versions of the draft gave such a job no entry; the commit above changed that.

### For a writer or reader

- **`head` is null.** The head fields (`agentRegistry`, `agentId`, `clientAddress`, `createdAt`) are the ERC-8505 writer's inputs, so the vector leaves them, and the `bytes`, `feedbackHash` and `file` that depend on them, for the writer to fill.
- **72 hours.** An entry may be posted only once the task is due: at least 72 hours after the timestamp of the block that holds the terminal step (lines 88–90). Here that block is 64,283,748, at 1,795,778,618 (2026-11-27 11:23:38 UTC).
- **Log queries.** The public Base Sepolia endpoint answers `eth_getLogs` over at most 200 blocks, and refuses wider ranges with an error. From `fromBlock` (64,281,327, the proxy's deployment) to the refund is 2,422 blocks, so a reader using that endpoint has to query in chunks.
- **Pinned.** The JSON file's SHA-256 is in [`provenance/TEST_VECTORS.sha256`](../../provenance/TEST_VECTORS.sha256), and `scripts/hygiene_scan.sh` checks it on every run.
