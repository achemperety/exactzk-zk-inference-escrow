# ERC-8183 and ERC-8004: where the text and the reference code differ

Found while testing an ERC-8183 evaluator and an ERC-8004 validator against each ERC's reference code (`test/external/README.md`). Line numbers refer to these pinned versions:

| | Text | Code |
|---|---|---|
| ERC-8183 | `ERCS/erc-8183.md` at `ethereum/ERCs` `a078cab5cc8e9581c15f76c091ed96eed28f02f7` | `AgenticCommerce.sol` and `IACPHook.sol` as given in that text (lines 404–712 and 391–398), copied to `test/external/erc8183/`; code line *n* is text line *n* + 403 |
| ERC-8004 | `ERCS/erc-8004.md` at `ethereum/ERCs` `503591a6e80e6e1affdd6403341e25269141f046` (identical to `ERC8004SPEC.md` in the code repository) | `contracts/ValidationRegistryUpgradeable.sol` and `contracts/IdentityRegistryUpgradeable.sol` at `erc-8004/erc-8004-contracts` `b9e466c250744a7e06b13dff9d3c2844ed64f825` |

## ERC-8183

| # | Text | Code |
|---:|---|---|
| 1 | `fund(jobId, expectedBudget, optParams?)` reverts if the budget is zero or differs from `expectedBudget`, "front-running protection" (lines 43, 79–80, 90–91; the ERC-2771 example at 365–368 has the same signature) | `fund(uint256 jobId, bytes optParams)` (line 188): no expected budget; a zero budget is funded and nothing is transferred (line 200) |
| 2 | `setBudget` is called by "client or provider" (lines 43, 57, 88–89) | Provider only (line 176) |
| 3 | `setProvider(jobId, provider, optParams?)`, hookable (lines 86–87, 139) | `setProvider(uint256 jobId, address provider_)` (line 161): no `optParams`, no hook calls |
| 4 | `submit` "SHALL revert if job is not Funded"; "No other transitions are valid" (lines 52, 93) | `submit` is also accepted from Open when the budget is zero (lines 211–214), an Open → Submitted transition |
| 5 | Hook `data` per function: `setBudget` `(amount, optParams)`, `fund` raw `optParams`, `submit` `(deliverable, optParams)`, `complete` and `reject` `(reason, optParams)` (lines 151–158) | The caller comes first in every encoding: lines 178, 196, 217, 232, 271 |
| 6 | `createJob` is not in the hookable list; `IACPHook` is two functions (lines 114–121, 137–145) | `createJob` calls the hook's `afterAction` (line 156); a hook must be on the admin's allow-list (line 136) and report `IACPHook` through ERC-165 (line 138; `IACPHook is IERC165`, `IACPHook.sol` line 5) |
| 7 | "the reference `AgenticCommerce` contract follows this minimal pattern", a kernel without hooks, with hooks in a separate `AgenticCommerceHooked` (line 112) | The published `AgenticCommerce` calls hooks (lines 116–126 and every lifecycle function); no `AgenticCommerceHooked` is given |
| 8 | A platform fee only (line 108) | Also an evaluator fee paid to the evaluator on completion: `evaluatorFeeBP`, `EvaluatorFeePaid` (lines 41, 60, 239–248) |
| 9 | "Job Data" lists fields, but no function reads a job (lines 60–69) | `getJob(uint256)` returns the whole struct (line 306). An evaluator contract has to rely on it |
| 10 | Implementations SHOULD bound hook gas (line 724) and SHOULD support ERC-2771, with all role checks on `_msgSender()` (lines 342–356) | Hooks receive all remaining gas (lines 118, 124); every role check uses `msg.sender` |
| 11 | `createJob` reverts if `expiredAt` "is not in the future" (line 85) | Requires more than 5 minutes ahead (line 135); `fund` also reverts at or after `expiredAt` (line 194), which the text does not mention |

Neither the text (line 95) nor the code stops `complete` at or after `expiredAt`, when `claimRefund` becomes available (line 99). An evaluator contract that should not race the refund has to check the deadline itself.

## ERC-8004 (Validation and Identity registries)

| # | Text | Code |
|---:|---|---|
| 1 | The contract stores `lastUpdate` (line 383); nothing says what it holds before a response | Set to the request's time when the request is opened (`ValidationRegistryUpgradeable.sol` line 104). `getValidationStatus` therefore cannot tell "not answered" from "answered 0" by `response` or `lastUpdate`; only the internal `hasResponse` flag can (lines 105, 131, 173), and it is not returned |
| 2 | For a request, "All other fields are mandatory" (line 357) | `requestURI` and `requestHash` are not checked (lines 78–113) |
| 3 | `agentId` is "assigned incrementally" (line 46) | The first agent is id 0 (`IdentityRegistryUpgradeable.sol` lines 62, 71, 81: `$._lastId++` from 0) |
| 4 | `getValidationStatus` (line 388) says nothing about an unknown request | Reverts with `"unknown"` (line 142) |
