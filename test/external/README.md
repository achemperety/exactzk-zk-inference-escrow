# Third-party reference contracts

The ERC-8183 evaluator (`src/ProofEvaluator8183.sol`) and the ERC-8004 validator (`src/ProofValidator8004.sol`) are tested against the reference contracts that each ERC points to. Both are built here from source. They are used only by tests and are never deployed from this repository.

## ERC-8183: the job contract

| | |
|---|---|
| Source | The text of ERC-8183, section "Reference Implementation". The ERC gives the code inline and links to no other repository. |
| Pinned at | `ethereum/ERCs` commit `a078cab5cc8e9581c15f76c091ed96eed28f02f7` (2026-03-13), file `ERCS/erc-8183.md`, SHA-256 `257c35bbaecab58d0c36823fe8fb2d0fffc83d6f1fd7301d97674707784efa3a`. This is the latest change to that file at the time of writing. |
| Files here | `erc8183/IACPHook.sol` (lines 391–398 of the ERC), SHA-256 `00103fb36b2b75118713c60142584e6411b85c721103eb00654aa3421d9305da`; `erc8183/AgenticCommerce.sol` (lines 404–712), SHA-256 `4f48f573cf5e05c70170b53a3cb95755e76ce40c8f1f8d3d339b95c289e5e8d8`. |
| Extraction | Each file is the lines between the ```` ```solidity ```` fence and the closing fence under its heading, byte for byte, with one newline at the end. Nothing is changed, so the files have no licence line, as in the ERC. `forge fmt` skips them. |
| Built with | OpenZeppelin `contracts-upgradeable` v5.4.0 and `contracts` v5.4.0 (the ERC names no version; this is the version the ERC-8004 repository below uses). It compiles unchanged. |
| Deployed in tests | `ReferenceDeploy.agenticCommerce`: the implementation behind an ERC-1967 proxy, initialised with the test token as payment token. The test contract holds the admin roles and sets an evaluator fee of 5 % (`setEvaluatorFee(500)`). |

Every test in `test/ProofEvaluator8183.t.sol` and every evaluator row of `test/StandardsGas.t.sol` uses this contract. A minimal job contract written from the ERC's text was not needed. None of the disagreements below blocks a test of the evaluator without a hook.

### Where the ERC's text and its reference code disagree

| # | Text | Code | Matters for |
|---:|---|---|---|
| 1 | `fund(jobId, expectedBudget, optParams?)`; reverts if the budget is zero or differs from `expectedBudget` (front-running protection) | `fund(uint256 jobId, bytes optParams)`; no expected budget; a zero budget is funded with no transfer | Clients: the price can change between signing and funding. Not the evaluator |
| 2 | `setBudget` by the client or the provider | Provider only | Test setup: the provider sets the budget |
| 3 | `setProvider(jobId, provider, optParams?)`, hookable | `setProvider(jobId, provider)`, no `optParams`, no hook calls | Not the evaluator |
| 4 | `submit` only from Funded; "No other transitions are valid" | `submit` also from Open when the budget is zero (Open → Submitted) | Tested: such a job completes through the evaluator with nothing paid |
| 5 | Hook `data`: `fund` raw `optParams`; `setBudget` `(amount, optParams)`; `submit` `(deliverable, optParams)`; `complete`/`reject` `(reason, optParams)` | The caller's address comes first in each: `(sender, optParams)`, `(sender, amount, optParams)`, `(sender, deliverable, optParams)`, `(sender, reason, optParams)` | A hook variant of the evaluator would have to follow the code. Not built |
| 6 | `createJob` is not hookable; `IACPHook` has two functions | `createJob` calls the hook's `afterAction`; a hook must be on an admin's allow-list and must report `IACPHook` through ERC-165 | The hook variant is not permissionless on a deployment of this code |
| 7 | The hooks section calls the reference `AgenticCommerce` a non-hooked kernel, with hooks in a separate `AgenticCommerceHooked` | The published `AgenticCommerce` calls hooks; no `AgenticCommerceHooked` is given | As 5 and 6 |
| 8 | A platform fee only | Also an evaluator fee (`evaluatorFeeBP`, `EvaluatorFeePaid`), paid to the evaluator on completion | The evaluator forwards it to the provider in the same call |
| 9 | No getter for a job | `getJob(jobId)` returns the whole `Job` struct | The evaluator depends on it: a job contract with only the text's functions cannot be served by this evaluator |
| 10 | Implementations SHOULD bound hook gas and SHOULD support ERC-2771 | Hooks get all remaining gas; `msg.sender` throughout | Not the evaluator |
| 11 | `createJob` reverts if `expiredAt` is not in the future | Requires more than 5 minutes ahead; `fund` also reverts at or after `expiredAt` | Not the evaluator |

Neither the text nor the code stops `complete` at or after `expiredAt`, when `claimRefund` opens. The evaluator does: it refuses a proof from `expiredAt` on, so completion and refund are never both available.

## ERC-8004: the Identity and Validation registries

| | |
|---|---|
| Source | `erc-8004/erc-8004-contracts`, the repository of the ERC's authors, as a git submodule at `lib/erc-8004-contracts`. |
| Pinned at | Commit `b9e466c250744a7e06b13dff9d3c2844ed64f825` (2026-08-15). This is the commit from which the 2026-10-13 count of ERC-8004 registry use ([achemperety/erc8004-usage-2026-10-13](https://github.com/achemperety/erc8004-usage-2026-10-13)) took its addresses and ABIs, so the code tested here is the code that count describes. |
| Files used | `contracts/IdentityRegistryUpgradeable.sol` (SHA-256 `18c8ca8c88493b46e54d000c96eaf7470d1f9dbfe55493fd7fa923bae543ff75`), `contracts/ValidationRegistryUpgradeable.sol` (`26b1ebb8718abfeba1f12d51201f2adcf6c02f5bde79902532bd2d8fc3657882`), `contracts/HardhatMinimalUUPS.sol` (`9d3b152b88733e61f40ae2de775f7448001b73d9165f23ee8bbe5dd88cd042aa`). Unchanged. |
| The ERC's text | `ERC8004SPEC.md` at that commit is byte-identical to `ERCS/erc-8004.md` at `ethereum/ERCs` commit `503591a6e80e6e1affdd6403341e25269141f046`, the latest change to the ERC (SHA-256 `249dc3d96ad7bbe4afd25cacd14be942eb87751abcf1608bab19a610f3c3f8a9`). |
| Built with | OpenZeppelin `contracts-upgradeable` v5.4.0 (submodule `lib/openzeppelin-contracts-upgradeable`, commit `e725abddf1e01cf05ace496e950fc8e243cc7cab`) and the `contracts` release its own submodule pins (v5.4.0, commit `c64a1edb67b6e3f4a15cca8909c9482ad33a02b0`): the versions in the repository's lockfile. Context remappings in `foundry.toml` give these files, and only these, the v5.4.0 sources. |
| Deployed in tests | `ReferenceDeploy.erc8004`, as the repository's own tests do it (`test/core.ts`): a proxy to `HardhatMinimalUUPS`, which makes the deployer the owner, then `upgradeToAndCall` to the real implementation with its initialiser. |

The registries enforce the caller rules of the ERC's text: `validationRequest` only by the agent's owner, an address approved for all its tokens, or the address approved for that token; `validationResponse` only by the validator named in the request. A local registry written for the tests was therefore not needed.

### Where the ERC's text and the registry code differ

None of these blocks a test. They change what a reader of the registry can conclude.

| # | Text | Code | Effect |
|---:|---|---|---|
| 1 | Stores `lastUpdate`; says nothing of its value before a response | `lastUpdate` is the time of the request until the first response | `getValidationStatus` cannot tell "not answered" from "answered 0" by `response` or `lastUpdate`. For this validator's answers, the tag and the response hash tell them apart: an unanswered request has an empty tag and a zero hash. `getSummary` counts only answered requests (an internal flag) |
| 2 | "All other fields are mandatory" for a request | `requestURI` and `requestHash` are not checked | None here |
| 3 | Agent ids "assigned incrementally" | The first agent is id 0 | None; the tests use agents 0 and 1 |
| 4 | Reading an unknown request is not specified | `getValidationStatus` reverts with `"unknown"` | The validator relies on it: answering a request nobody opened reverts before any proof is checked |

## x402 `auth-capture`: the escrow and its ERC-3009 collector

| | |
|---|---|
| Source | `base/commerce-payments`, the contracts x402's `auth-capture` EVM binding names, as a git submodule at `lib/commerce-payments` |
| Pinned at | Tag `v1.1.0`, commit `6b0a5ef3f0df973857f558e2d6b5dd645b5e97f9`: the v1.1 deployment set, the binding's default |
| Built with | Its own dependencies, as its `remappings.txt` names them: OpenZeppelin v5.0.2 (through its `spend-permissions` submodule, of which only `lib/openzeppelin-contracts` is checked out) and solady (`5ea5d9f`). Context remappings in `foundry.toml` |
| Deployed in tests | `AuthCaptureEscrow` and `ERC3009PaymentCollector` placed at the canonical v1.1 addresses the binding publishes, with Forge's `deployCodeTo` (the constructor runs at the target address), on chain id 84532: x402's own client signs for those addresses (`test/AuthCaptureBase.sol`, `script/X402LocalChain.s.sol`) |
| On the testnet | Both are deployed at those addresses on the target testnet and equal this source built with its deploy profile, metadata removed and immutables zeroed (`scripts/escrow_live_check.py`; `docs/deployment-notes.md`). The testnet `AuthCaptureProofOperator` uses that escrow |

## x402's TypeScript packages

`@x402/core` (types, zod schemas, header encoding, the client) and `@x402/evm` (the `auth-capture` client scheme) at `x402-foundation/x402` commit `3eb54b2984a955118845115b3fd5db4c926d0382`, fetched from source by `x402/fetch_x402.sh` and not tracked. See `x402/README.md`.

## Compiler settings

Everything here is compiled with this repository's settings (solc 0.8.28, `via_ir`, 1,000,000 optimiser runs, Osaka rules, no metadata). The ERC-8004 repository compiles with solc 0.8.24, `via_ir`, 200 runs, for Shanghai; commerce-payments deploys with `via_ir`, 100,000 runs, for Cancun. Behaviour is the same; gas inside the registries and the job contract differs from what their deployed bytecode would use. The gas figures in `measurements/2026-11-24-standards/` say which parts are third-party code.
