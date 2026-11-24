# Contributing

## Before you push

```
forge fmt --check
forge build
forge test
bash scripts/hygiene_scan.sh
bash scripts/hygiene_selftest.sh
python3 scripts/test_verify_entry.py
(cd clients/ts && npm ci && npm run typecheck && npm test)
```

All must pass. CI runs the same commands, and compiles the Python middleware.

## Rules

1. **Signed commits.** Every commit is signed (`git config commit.gpgsign true`). Unsigned commits are not merged.
2. **A test that guards a property must be seen failing first.** Before a property test is accepted, break the code it guards on purpose, run the test, and confirm it fails for the right reason. Put the mutation and the failing output in the pull request. A test that has never failed has not been shown to test anything. Mutations already recorded are in `test/MUTATIONS.md`.
3. **No secrets, no live addresses.** No private keys, mnemonics, RPC URLs with API keys, explorer links or deployed addresses in source, tests, docs or commit messages. Deployed addresses are recorded under `deployments/`; the specification under `specs/` may repeat the ones recorded there, and nothing else may. `scripts/hygiene_scan.sh` enforces this; a new constant that it flags needs an entry in `scripts/hygiene_allowlist.txt` with a reason.
4. **Testnet only.** No mainnet configuration, addresses or deployment scripts.
5. **Pinned files stay pinned.** Files listed in `provenance/COPIED_FILES.sha256` are fixtures and circuit inputs. Do not edit them; replace them only together with their recorded hash and an explanation.
6. **Label claims.** In documentation, a number is either measured (say how, and where the output is) or an estimate (say so, with a range).

## Layout

| Path | Contents |
|---|---|
| `src/` | Contracts |
| `test/` | Foundry tests; `test/fixtures/` holds real proofs and verifier bytecode |
| `specs/` | The draft x402 scheme specification; `REVIEW.md` lists its requirements and numbers with their sources |
| `clients/` | The TypeScript client and the Python server middleware |
| `circuits/spike-mlp/` | Pinned circuit inputs and the scripts that regenerate verifiers from them |
| `measurements/` | Scripts and results of the gas and proving measurements; `experimental/` holds variants with new keys, none canonical |
| `provenance/` | SHA-256 of every file carried into this repository from its predecessor |
| `scripts/` | Repository tooling, deployment checks and `verify_entry.py` |

## Changing the specification

Every MUST and SHOULD in `specs/schemes/proof-gated/` and every number in it is listed in `specs/schemes/proof-gated/REVIEW.md` with where it is enforced or measured. A change to the specification updates that list in the same commit. A number in the specification must come from a measurement in this repository and name its source.

## Style

Solidity is formatted with `forge fmt`. Errors are custom errors, not strings. Every external function has NatSpec that states what it reverts on.
