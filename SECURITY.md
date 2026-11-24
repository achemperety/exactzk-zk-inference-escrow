# Security

## Status

- **Testnet only.** This code is deployed, if at all, on test networks. There is no mainnet deployment and none is planned from this repository.
- **Unaudited.** No part of this repository has had an independent security review.
- **In development.** Interfaces and contract addresses change without notice until a tagged release says otherwise.

Do not use these contracts to hold anything of value.

## What the proofs do and do not establish

A proof accepted by these contracts shows that a specific pinned circuit maps a committed input to a public output. It says nothing about who asked, on which chain, or for what payment; those are bound by the payer's signature, not by the proof.

A verifier is identified by the hash of its verifying key and the hashes of its on-chain code. The chain enforces the code hashes. It cannot check that the code embeds the declared key, nor which model the key came from; those links are established off-chain by regenerating the key and the verifier from the pinned inputs in `circuits/` (the model files, the pinned `settings.json`, which is part of the circuit's identity, and the SRS) and comparing them with the registry entry: `scripts/verify_entry.py`. Which model a verifier is *meant* to stand for is a statement by whoever publishes the model, not something the chain or this repository can establish.

The pinned circuits use a structured reference string that was generated locally by a single party, not taken from a public ceremony, and were built with EZKL's `check_mode: UNSAFE` setting. They are fixtures for a testnet system, not production parameters.

## Known limits of the settlement contracts

- The proof is not bound to the request. A valid proof for a verifier and an input commitment settles any request that names both. Clients make each commitment unique by putting fresh random values in the committed input.
- The payment token must move exact amounts, as USDC does. With a fee-on-transfer token, releases and refunds could pay out more than was locked for them, at the expense of other locks in the same token.
- In the one-transaction flow nothing is locked. A payer can move its funds while the proof is being made, and the provider then loses that proof's work. Providers that cannot accept this should require the escrow flow.
- A channel's provider must watch for close requests. It has the channel's challenge window to present its latest unsettled voucher; vouchers it did not present cannot be held once the channel is finalized, and whatever they would have paid goes back to the payer. Providers should not accept channels whose challenge window is shorter than they can reliably answer in.
- A payer gets back what is not held as soon as the challenge window ends, and what is held at the latest one prove window later. The contract enforces only minimum windows (60 and 300 seconds); a payer that opens a channel with very long windows waits that long to close it.
- A challenge holds at most the cumulative amount the payer signed in the presented voucher, less what has already been accounted, and never more than the balance. A voucher whose `proveBy` has passed, or lies further ahead than the prove window, cannot be presented.
- Only the provider can waive a voucher. Waiving moves no money to the provider; it advances the channel past a voucher that will not be paid.
- A contract payer's voucher signature is checked when the batch settles, not when the voucher was signed. A wallet that changes its owner or its rules in between makes its vouchers fail; providers that serve contract payers carry that risk.
- A contract payer can make a whole batch run out of gas from inside its signature check. A provider that sees this can resubmit the batch with that lane's frame replaced by one that fails a cheap check, such as a wrong sequence number, which the contract rejects before it calls the payer.
- Anyone may submit a batch. What settles always accrues to the channels' provider. A third party that copies a pending batch and alters frames can only make lanes fail; the provider settles them by resubmitting with the same proof.

## Known limits of the ERC-8183 evaluator and the ERC-8004 validator

- The evaluator trusts the job contract it is given. It reads the job through the ERC-8183 reference implementation's `getJob`, calls `complete` and `reject` on it, and forwards whatever token balance that contract sends it during `complete`. A job contract that misreports a job can only misreport its own jobs; the evaluator holds nothing that another job contract could take.
- The reference job contract is upgradeable by its admin and may charge a platform fee. Neither is under the evaluator's control: a job's terms, its payout and its existence are only as good as that contract's admin.
- Without a hook, the evaluator does not see the provider's deliverable. A completed job means a valid proof for the agreed circuit and input commitment; whatever the provider submitted as its deliverable is not compared with the proven output.
- The client sets the terms and the provider cannot change them. A provider must read `terms` before working: terms naming a verifier or input it did not agree to cannot be completed, and the job then ends by forfeit or expiry.
- The validator's "passed" says that the claimed output is what the circuit gives for the committed input. Proofs are public and do not name an agent, so any agent can obtain a "passed" for any published proof. It is evidence about a claim, not about who did the work.
- The validator answers a request only if the agent the Validation Registry recorded for it is the agent its request hash commits to; otherwise `respond` reverts with `AgentMismatch` and nothing is written.
- Readers of the Validation Registry should filter `getSummary` by this validator's address. A tag is no protection: any validator can write the same tag.

## Known limits of the auth-capture operator and the x402 server

- The operator binds a payment to its terms through `receiverAuthorizer`, an address derived from the verifier id and the input commitment. An address is 160 bits of a 256-bit hash. A server that sees the input commitment before it chooses the verifier can search for two sets of terms with the same address with about 2^80 work, and could then show a payer one set of terms and be paid for proving the other. A client that adds fresh randomness to its input commitment after the server has named the verifier, as `docs/spec-notes.md` requires, leaves the server a search for one fixed 160-bit target instead: about 2^160.
- x402's own `auth-capture` client binds whatever `receiverAuthorizer` the server sends; it knows nothing of proof terms. It gets the escrow's guarantees (amount, receiver, reclaim after expiry), not the proof gating: only a client that recomputes the address from the terms it means to pay for knows that a capture needs a proof of those terms.
- The operator relies on x402's escrow (base/commerce-payments v1.1.0) for amounts, deadlines, fees and the payer's `reclaim`. The tests run against that escrow built from source. The escrow and ERC-3009 collector at the canonical addresses on Base Sepolia were compared with that source on 2026-11-24 (`docs/deployment-notes.md`); they are someone else's contracts, and the comparison says nothing about other chains.
- The operator has no refund entry point. Once a hold is captured, getting money back to the payer is outside this contract.
- The x402 server in `x402/` is a demonstration: it holds no key, sends from a local node's unlocked account, and serves one stored proof.
- `ProofCapturePolicy` binds the terms through the client's salt nonce, derived from the verifier id and the input commitment, so the binding is the full 256-bit hash rather than a 160-bit address. A client that draws the salt nonce at random, as x402's own client does, cannot be captured under it; its hold goes back to it after the capture deadline. The policy does not constrain the amount or the fee: `PolicyCaptureOperator` takes the whole hold and the payer's minimum fee, and under the reserved `"policy"` type the authorizer's signature would fix them.
- The `batch-settlement` claim gate (`test/experimental/batch-gate/`) is a prototype for a proposal. A gate is only a condition if it is the channel's receiver as well as its receiver authorizer, because x402's channel contract lets the receiver claim directly; its channels have no relayed claims and no cooperative refunds.

## The Groth16 prototype is a prototype

`measurements/experimental/groth16/` and `test/experimental/groth16/` hold a Groth16 version of the same model, built to measure what a second proof system would cost. It is EXPERIMENTAL and not part of the system:
- **Its trusted setup is a single-party local setup.** Whoever ran it could forge proofs that its verifier accepts. It is insecure for anything but measurement.
- **It does not prove the same statement.** Its input commitment is Poseidon2 over the quantised input, not the canonical EZKL Poseidon commitment, so a payment signed for one commitment cannot be settled with the other circuit's proof.
- Nothing from it is registered or deployed on any network, and its USDC gas figure is derived from the test-token figure, not measured.

## Known limits of the specification draft

`specs/schemes/proof-gated/` is a draft for discussion with the x402 maintainers, not accepted by x402. It proposes the proof as a condition on `auth-capture` (a normative policy profile) and on `batch-settlement` (a proposal, not normative); the folder keeps its earlier working name. There is no facilitator implementation: the reference server settles directly, and the facilitator steps of the policy profile are specified but not implemented. The policy profile assumes two changes to `auth-capture`'s reserved `"policy"` type that its maintainers have not agreed to: a status word instead of a boolean, and a `policyData` parameter. `ProofCapturePolicy` and `PolicyCaptureOperator` are tested against the escrow built from source and are not deployed. The `batch-settlement` claim gate is a test-only prototype.

## Known limits of the clients and the quickstart

- The quickstart writes a throwaway private key to `.quickstart/key` (mode 600, ignored by git) and asks you to fund it from faucets. It is for testnet funds only; do not reuse it or send it anything of value.
- `clients/ts` checks an offer against this deployment's addresses and the verifiers it is told to accept. It cannot tell whether a verifier id belongs to the model you meant: that is established off-chain, by regenerating the key and the verifier from the published files (`python3 scripts/verify_entry.py`, `circuits/spike-mlp/MANIFEST.md`).
- The published-proof mode sells one fixed, public input. It shows the payment path; it gives no privacy and no fresh randomness for the commitment.
- `clients/python` sends transactions from the key it is given and pays their gas. A payment that fails in simulation costs nothing; one whose transaction reverts after simulation (for example because the chain moved) costs the server its gas.

## Reporting

Please report a suspected vulnerability privately through GitHub's "Report a vulnerability" form on this repository's Security tab. Do not open a public issue for it. Include the commit you tested, what you observed, and a minimal way to reproduce it.

There is no bounty.
