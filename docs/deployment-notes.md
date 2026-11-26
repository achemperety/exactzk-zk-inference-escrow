# Deployment notes (testnet)

These notes record what the testnet deployment does and what it was checked against.

## Deployed

**2026-11-24, from commit `07d7e1c`, Base Sepolia blocks 62,968,700 to 62,968,830.** 13 transactions, all successful, 16,869,040 gas, 0.000101 ETH including L1 data fees. The addresses of our contracts and the two verifier ids are in [deployments/base-sepolia.json](../deployments/base-sepolia.json). The deployer is a testnet-only account and is not recorded in this repository. `07d7e1c` is the commit of the development repository the deployment was built from; this repository's `src/` and `script/` are that commit's sources, apart from one reworded comment in `src/ProofValidator8004.sol`. The contracts are compiled without a metadata hash (`cbor_metadata = false` in `foundry.toml`), so the comment changes no bytecode, and an explorer can report a code match but not an exact one. Verified 2026-11-24: on Sourcify, all seven contracts match on creation and runtime code, and the two verifiers, deployed as raw runtime bytes, on runtime code; on Blockscout, the seven contracts are verified (partially).

`python3 scripts/check_deployment.py <Forge's broadcast file> https://sepolia.base.org` reads every receipt and contract back from the chain and found everything as intended:

- every transaction succeeded;
- each of our contracts equals that commit's build, apart from its immutable values;
- both verifiers have the code hashes in `circuits/spike-mlp/MANIFEST.md`;
- both entries are registered with their pinned ids, lanes, output size, gas and key hash;
- each settlement contract holds its one-unit seed;
- every contract points at the registry;
- the validator points at the ERC-8004 authors' testnet Validation Registry, whose implementation is still the one checked;
- the operator points at x402's canonical escrow.

The quickstart's payee, a separate testnet-only account, is in `deployments/base-sepolia-quickstart.json`. Gas of the deployment's transactions in use is in `measurements/2026-11-24-testnet/`.

## Source verification

**`ProofEvaluator8183` on Sourcify, checked 2026-11-25.** Sourcify holds a verification of the evaluator on Base Sepolia, made on 2026-11-24 at 18:23:45 UTC: `match` for both the creation and the runtime code. The deployment day did not record it here; it is recorded now in [deployments/base-sepolia-source-verification.json](../deployments/base-sepolia-source-verification.json). `match` rather than `exact_match` is the most Sourcify can give: the contracts are compiled without CBOR metadata, so there is no metadata hash to match exactly. Sourcify accepts one verification per address, so nothing was submitted again; instead both sides were compared with this public tree:

- Sourcify's 14 source files equal this repository's at tag `v3.0.0-testnet`. At `main` (`fd1ce61`), 13 are equal and `src/ProofCheck.sol` differs only by `checkOneInMemory`, a function added for the policy profile that the evaluator does not use.
- Its settings are this repository's `foundry.toml`: solc 0.8.28, via IR, optimizer at 1,000,000 runs, EVM `prague`, no metadata.
- The runtime code built from `main` equals the code on chain (`cast code`, 5,463 bytes) outside the evaluator's two immutable slots, which hold the registry's address.

The other contracts of the deployment were not looked up on Sourcify.

## How to deploy

`script/DeployBaseSepolia.s.sol` performs the order below; the holder of the deployer keystore runs it through `scripts/deploy.sh`:

```
bash scripts/deploy.sh balances   # the deployer's ETH and USDC
bash scripts/deploy.sh dry        # simulation against Base Sepolia, nothing sent
bash scripts/deploy.sh send       # broadcast, one transaction at a time
```

Forge executes the whole script locally before it sends anything, and the script stops there if Base Sepolia is not what was checked: the ERC-1967 implementations behind the ERC-8004 Validation and Identity Registry proxies, the Identity Registry the Validation Registry points to, the code hashes of x402's escrow and ERC-3009 collector at the canonical addresses and the escrow that collector serves, and two units of USDC in the deployer's balance for the seeds. After deploying it checks its own result: both verifiers' code hashes, both verifier ids, both seeds, and every contract's links to the registry, the Validation Registry and the escrow. `test/DeployBaseSepolia.t.sol` runs the same script against local copies of those contracts, including one test per refusal; `test/DeployBaseSepoliaFork.t.sol` (opt-in, `FORK_RPC_URL`) runs it unchanged on a fork of Base Sepolia.

A rehearsal on a local fork of Base Sepolia (block 62,960,977, sent from the deployer's address with Anvil's impersonation, nothing sent to the chain) used 16,864,240 gas in 13 transactions; the deployment itself used the same per transaction except the second seed (62,135 instead of 57,335, because the deployer kept USDC afterwards): 3,943,464 and 3,943,068 for the solo and K=8 verifiers, 2,623,382 for `ChannelSettlement`, 1,552,450 for `AuthCaptureProofOperator`, 1,225,966 for `ProofEvaluator8183`, 1,204,388 for `SoloSettlement`, 934,573 for `ProofValidator8004`, 626,358 for `VerifierRegistry`, 347,283 for `Halo2EzklAdapter`, 171,913 and 171,925 for the two registrations, 62,135 and 57,335 for the two seeds. The L1 data fee for its 75,839 bytes of calldata was bounded at about 1.1 × 10^-13 ETH by the chain's gas price oracle that day.

The verifier entries registered, and their ids (the ids `test/ProofCoreBase.sol` computes for the same entries):

| Entry | Lanes | Output bytes per lane | `verifyGas` | Verifier code hash | Id |
|---|---:|---:|---:|---|---|
| Solo | 1 | 320 | 600,000 | `0x8cd0b80f…5f49` | `0xc302c6867eddfdcd201bbe7fb653191da6ee4c1a178e7df821e9ebca01b6ff9b` |
| K=8 | 8 | 320 | 660,000 | `0x471c8109…7ef1` | `0xff34bcad7f2abcb126327e61b648bae1d6a446ad3bd15924ec2218c742d51107` |

## Target

- Network: Base Sepolia (chain id 84532).
- Token: Circle's testnet USDC, `0x036CbD53842c5426634e7929541eC2318f3dCF7e`.
- Deployer: a fresh account used for this testnet only. Its address is not recorded in this repository.

## Order

1. `VerifierRegistry`.
2. `Halo2EzklAdapter`.
3. The two pinned EZKL verifiers, from the runtime bytecode in `test/fixtures/` (solo and K=8), deployed as they are behind an 11-byte creation prefix that returns them, not recompiled. Their code hashes must equal the pinned ones before anything is registered: the entries carry the pinned hashes, so registration reverts otherwise.
4. Register the solo and K=8 entries. The returned ids must equal the ids the tests compute for the same entries.
5. `SoloSettlement(registry)` and `ChannelSettlement(registry)`.
6. Seed each settlement contract with one unit of USDC (0.000001 USDC), sent by the deployer with a plain `transfer`.
7. `ProofEvaluator8183(registry)`. It takes no job contract: it serves any job contract with the ABI of the ERC-8183 reference implementation, named per call.
8. `ProofValidator8004(registry, validationRegistry)`, with the ERC-8004 authors' testnet Validation Registry (below).
9. `AuthCaptureProofOperator(escrow, registry)`, with x402's canonical `auth-capture` escrow (below).

## Why the seed

An ERC-20 balance that goes from zero to non-zero costs 22,100 gas to write instead of 5,000. A settlement contract's own USDC balance is zero whenever it holds no lock and no deposit, so the transaction that takes it from empty pays the extra 17,100. Measured on a fork of Base Sepolia with the real USDC:

| Transaction | Contract holds no USDC | Contract holds USDC |
|---|---:|---:|
| `SoloSettlement.open` | 133,331 | 116,231 |
| `ChannelSettlement.openChannel` | 135,019 | 117,919 |

With one unit in each contract the balance never returns to zero, and the second column applies from the first deposit. The unit is never paid out: every amount either contract pays was paid in for a specific request or channel, and neither has a function that sweeps the rest. Gas targets are judged in steady state; the first-time rows are still reported, as separate rows.

## First-time costs the deployment cannot remove

- A provider's own USDC balance going from zero to non-zero (its first payment ever in USDC): 22,100 instead of 5,000, paid by the transaction that pays it.
- A payer's own USDC balance going from zero to non-zero when a closing channel pays it back (`finalizeClose`, `sweepExpiredHold`, or `waive` after finalization): 17,100 more than when the payer already holds USDC.
- `ChannelSettlement.accrued` for a provider going from zero to non-zero: 20,000 instead of 2,900 in the batch that settles to it. A provider that withdraws all but one unit (`withdraw(asset, accrued - 1)`) keeps the next batch's write at 2,900.

## Client defaults for channel windows

The contract enforces only minimums (prove 60 s, challenge 300 s). Client libraries, when they are added, default to a prove window of 10 minutes and a challenge window of 24 hours; the README gives the reasons.

## Held option: provider and asset once per batch

Every channel config in a batch carries the provider and the asset, and the contract skips a lane whose channel names another. Passing the two once per batch instead, and leaving them out of each config's calldata, would save about 5,900 gas per K=8 batch, at the price of an asymmetric interface (a lane for another provider would then read as an unknown channel). Not applied: the K=8 batch is within its limit. It is applied only if a K=16 batch with the real proof costs more than 1,170,000 gas.

## ERC-8004 and ERC-8183 contracts on the testnet

The validator is bound at deployment to one ERC-8004 Validation Registry. The ERC's authors list their testnet proxies at the commit tested here (`TESTNET_ADDRESSES` in `lib/erc-8004-contracts/scripts/addresses.ts`), at the same addresses on every testnet they deployed to, Base Sepolia included. The proxies are upgradeable by their owner, and the repository's README says the validation part of the ERC is still being revised. **Checked 2026-11-24, Base Sepolia block 62,931,088** (`python3 scripts/erc8004_live_check.py testnet https://sepolia.base.org <solc 0.8.24>`): the implementations behind the Validation Registry proxy and the Identity Registry proxy it points to are the pinned source, byte for byte once the compiler metadata is removed and the two immutables zeroed (Validation Registry implementation `0xdb31f5d9…7f99`, compared code keccak256 `0x45a621c9257c0acda6d061e2c58ef8a97aec95bff2102b370a5ba2ace5ccbe23`; Identity Registry implementation `0x7274e874…9c02`, `0x6a035e2721ffdb11e98c8bd1d82404292499be4a06efdb455ab9a3d942b3e6b0`). Only the metadata hash differs, as it does when the same source is compiled under other file names. The same implementations run behind the Base mainnet proxies (block 61,588,589). So the caller rules the validator relies on, tested in `test/ProofValidator8004.t.sol`, are the ones running on Base Sepolia, and the testnet deployment points the validator at the authors' testnet Validation Registry.

The proxies stay upgradeable by their owner. Run the check again on the day of deployment, and before relying on any answer the validator wrote, if the implementation slot has changed since. **Checked again on the day of deployment, 2026-11-24, Base Sepolia block 62,956,435:** same implementations, same compared code, match. The deployment script refuses to run if either implementation address has changed since.

## x402's escrow on the testnet

`AuthCaptureProofOperator` is bound at deployment to one `auth-capture` escrow. x402's client signs only for the canonical v1.1 addresses, and on Base Sepolia both are deployed: the escrow at `0xf96815976523E00e65Be8f34cA5e64b4f41EB19c` and the ERC-3009 collector at `0x8612dfdc421f80336cd14E8EF9cb1E765dB5ab88`. **Checked 2026-11-24, Base Sepolia block 62,963,152** (`python3 scripts/escrow_live_check.py https://sepolia.base.org <solc 0.8.28>`): both are base/commerce-payments v1.1.0, the source tested here, byte for byte once the compiler metadata is removed and the immutables zeroed, when built with that repository's deploy profile (solc 0.8.28, Cancun, via-IR, 100,000 runs). Compared code keccak256: escrow `0x959d6549d573960aea743edea6287960b322139b8df48ced18256637f3c420be`, collector `0x70e974cd4484f8c452c21caf8f61a2385696aff32fc3a1f923f539a1e0b0b8f8`. The collector serves that escrow. Built with 200 optimiser runs instead, both differ, so the comparison does tell builds apart. The deployment script pins the two live code hashes (`0x33558f6c…702a`, `0xe27322c8…b62f`) and refuses to run if either changes. The escrow has no owner and no upgrade path.

ERC-8183 has no deployment named by the ERC. Unless one with the reference ABI exists on Base Sepolia at deployment time, the end-to-end check deploys the reference job contract from `test/external/erc8183/` with testnet USDC as its payment token, and says so.

## Second proof system (preliminary)

A Groth16 prototype of the same model was built and measured after the testnet measurements (`measurements/experimental/groth16/`). It is EXPERIMENTAL and preliminary: its setup is a single-party local setup, and its input commitment is Poseidon2, not the canonical one, so it does not prove the same statement. Nothing from it is registered or deployed.

A Groth16 verifier needs a trusted setup specific to its circuit: whoever runs that setup and keeps its secret randomness could forge proofs that the verifier accepts. Wherever figures for such a verifier appear in this repository, they say who ran the setup and how (one party or a ceremony, with which tool and inputs). A setup run by us for the prototype is a single-party setup and is labelled as one.

## Version 3.1

**2026-11-26 (UTC), from commit `e1beaa7`, Base Sepolia blocks 64,043,944 to 64,043,988.** `script/DeployV31BaseSepolia.s.sol`, `runV31()`: 9 transactions, all successful, 7,504,813 gas, 0.0000392 ETH including L1 data fees. It deployed `Halo2EzklAdapterV2` and registered the two v3.1 entries in the v3.0 registry. It also deployed new versions of `SoloSettlement`, `ChannelSettlement`, `ProofEvaluator8183` and `AuthCaptureProofOperator`, and seeded both settlement contracts with one unit of USDC, as in v3.0. `ProofValidator8004` follows in a second step (`runV31Validator()`). The addresses, ids and transaction hashes are in [deployments/base-sepolia-v3.1.json](../deployments/base-sepolia-v3.1.json), and the checks made after the deployment are in [docs/known-issues/2026-11-out-of-gas-as-invalid.md](known-issues/2026-11-out-of-gas-as-invalid.md). The v3.0 contracts and entries above stay on chain unchanged and are superseded.
