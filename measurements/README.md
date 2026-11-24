# Measurements

All figures together, with the method and the machine of each: [MEASUREMENTS.md](../MEASUREMENTS.md).

## Version 3

| Folder | What was measured |
|---|---|
| `2026-11-23-solo-settlement/` | Gas of the solo settlement flows, test token and USDC on a fork |
| `2026-11-23-channel-settlement/` | Gas of channel batches, the K-sweep |
| `2026-11-24-channel-close/` | Gas of closing a channel |
| `2026-11-24-standards/` | Gas of the ERC-8183 evaluator and the ERC-8004 validator |
| `2026-11-24-x402-auth-capture/` | Gas of paying through x402's `auth-capture` escrow |
| `2026-11-24-k16/` | K=16 with the real proof |
| `2026-11-24-testnet/` | The deployment's own transactions on the testnet |
| `2026-11-24-prover/` | Proving with the canonical keys (warm prover, `check_mode` SAFE) |
| `2026-11-24-verify-entry/` | Checking the registry entries against the published circuit files |
| `experimental/` | EXPERIMENTAL circuit variants and a Groth16 prototype, with new keys, none canonical |

## Carried over from the previous version

These folders hold the scripts and result files of measurements made on the previous version of the contracts. They are here so that later measurements of version 3 can be made the same way and compared.

| Folder | What was measured |
|---|---|
| `2026-09-18-steady/` | Gas of a K=8 batch settlement, first batch and steady state, on a local Anvil node |
| `2026-09-28-k16/` | Circuit generation, proving cost and settlement gas at K=2, 4 and 16 |
| `2026-09-28-proving-cost/` | Time and peak memory of key generation, witness, proving and verification for the solo and K=8 circuits |

The scripts call the previous contracts and expect that repository's layout, so they do not run here as they are. Working directories, raw logs and written reports were not carried over; `provenance/README.md` lists exactly what was.

The transaction hashes in the result files are from throwaway local Anvil chains. The keys in the scripts are Anvil's published default accounts.
