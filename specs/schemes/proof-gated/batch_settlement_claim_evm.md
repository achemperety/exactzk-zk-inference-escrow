# `batch-settlement` on EVM: a proof claim condition (proposal)

> **Status: proposal, not normative.** Nothing here is a requirement. The design below was proposed in [x402-foundation/x402#4390](https://github.com/x402-foundation/x402/issues/4390), and a prototype checks that it runs against x402's own channel contract. The open points must be settled, and interop runs between independent implementations must pass, before any of it hardens into a binding.

## Summary

[`batch-settlement`](https://github.com/x402-foundation/x402/blob/main/specs/schemes/batch-settlement/scheme_batch_settlement_evm.md) lets a server claim a client's cumulative vouchers from a prepaid channel. The proposal adds a condition on those claims: a voucher's value is claimed only for requests whose input commitments the client signed and a valid proof covers ([proof_condition.md](./proof_condition.md)).

1. Once per batch, the client signs a **commitment root**: one hash over the batch's ordered per-request input commitments.
2. Each claim presents one commitment with its **position** and an **inclusion proof** (a Merkle path), and a proof of the computation for that commitment.
3. A **gate**, acting as the channel's `receiverAuthorizer`, checks the root signature, the inclusion at that position, and that the proof is for that very commitment. Only then does it claim the voucher.
4. The **voucher format is unchanged**. The client keeps signing `Voucher(bytes32 channelId,uint128 maxClaimableAmount)`; the root is a second, separate signature per batch.

## The prototype

`test/experimental/batch-gate/ProofClaimGate.sol`, tested in `ProofClaimGate.t.sol` against `x402BatchSettlement` from x402's repository (commit `d7d0a435`, copied unchanged into `test/external/x402/`, built locally). It is a test-only contract and is not deployed.

**What the client signs once per batch**, EIP-712 in the gate's domain (`name` "x402 proof claim gate", `version` "0", chain id, the gate's address):

```
CommitmentRoot(bytes32 channelId,bytes32 verifierId,bytes32 root,uint32 count,uint128 unitPrice,uint128 baseClaimed)
```

`unitPrice` is what one proven request unlocks; `baseClaimed` is what the channel had claimed before this batch. The signer is the channel's `payerAuthorizer`, or the payer if there is none, as for vouchers.

**The tree.** Leaf *i* is `keccak256(abi.encode(LEAF_TAG, i, commitment_i))`, with `LEAF_TAG = keccak256("x402.proof-claim-gate.leaf.v0")`. Leaves past `count` are zero, up to the next power of two. A node is `keccak256(left ‖ right)`. The path runs from the leaf up, and bit *j* of the position says whether the node at height *j* is a right child. The path length must be exactly the tree's depth.

**A claim**, `claimWithProof(voucherClaim, rootTerms, rootSignature, inclusion, entry, output, proof)`, open to anyone:
1. The channel's `receiver` and `receiverAuthorizer` must both be the gate.
2. The root signature verifies for the channel id the gate computes from the voucher's channel.
3. `position < count`, and the path opens the root at that position.
4. The position has not been proven before under this root.
5. The proof verifies for `verifierId` and the included commitment. Failures revert with `ProofInvalid()` or `VerifierUnavailable(bytes32)`, the two outcomes of [proof_condition.md](./proof_condition.md#outcomes-of-a-check).
6. `voucherClaim.totalClaimed ≤ baseClaimed + provenCount × unitPrice`; then the gate calls `x402BatchSettlement.claim` and emits the output.

`payout(token)` sweeps the gate's settled balance from the channel contract and forwards it to the payee fixed at the gate's deployment.

**Tested** (15 tests, all passing): one claim settles and is paid out; the proven commitment presented at a position it does not hold is refused, with its own path and with the path of the claimed position; the padding position and a path one level short are refused; a proof for another commitment than the included one is refused; an invalid proof is refused and the position stays open; a check that cannot run is `VerifierUnavailable`, never `ProofInvalid`; a root signed by someone else, a root altered after signing, a root signed for another channel and a root signed for another gate are refused; one proof unlocks one unit and a position counts once; `baseClaimed` carries earlier batches; nobody but the gate claims for its channel; every position of batches of one to nine opens at its own position only.

**Gas**, Osaka schedule, real solo proof, every account cold. A claim moves no token, so the token does not matter.

| | Gas |
|---|---:|
| `claimWithProof`, the channel's first claim | 797,428 |
| `claimWithProof`, steady (second batch on the channel) | 769,210 |

One proof per request costs about what a native one-transaction payment does (768,174 with USDC). The saving batching promises needs one proof over several lanes with several inclusions, which the prototype does not do.

## What the prototype found

- **The gate must also be the receiver.** `x402BatchSettlement.claim` admits the channel's `receiver` as well as its `receiverAuthorizer`. A receiver other than the gate can claim any signed voucher without a proof; a test shows it. The gate therefore holds the receiver role, collects the settled funds and forwards them.
- **No relayed claims or cooperative refunds.** `claimWithSignature` and `refundWithSignature` need an ERC-1271 answer from the receiver authorizer. The prototype gives none, so its channels have neither. The payer leaves through the timed withdrawal (at least 15 minutes). A gate could answer ERC-1271 for refunds it is told to allow; that is not designed.
- **Two ceilings.** The payer's voucher still caps every claim (`ClaimExceedsCeiling` in the channel contract), and the root caps it at what was proven. A claim needs both.
- **The position is bound twice**, in the leaf and in the path's bits. See leaf encoding below.

## Open points

1. **Ordering.** What fixes position *i*: the order in which the server received the requests, a client counter, or the vouchers' sequence? What happens when a request is dropped or two arrive out of order? In the prototype positions are independent: any subset can be proven, in any order, and an unproven position blocks nothing.
2. **Leaf encoding.** The prototype's leaf tags, then encodes the position and the commitment. Open: whether the leaf also carries the request's price (`batch-settlement` lets the server charge less than the maximum, and a uniform `unitPrice` cannot express that); whether leaves and inner nodes need distinct tags (the prototype relies on their different preimage lengths, 96 and 64 bytes); whether pairs are positional, as here, or sorted. Binding the position in the leaf as well as in the path's bits is redundant; one of the two should be chosen.
3. **Domain separation.** In the prototype: chain id (in the gate's EIP-712 domain, and in the channel id, which the channel contract derives in its own domain); channel id (in the signed struct); gate address (`verifyingContract`); version (the domain's `version` "0" and the leaf tag's "v0"). Open: whether the channel contract and the verifier should be named explicitly rather than through the channel id and the struct, and whether one root may span several channels.
4. **Empty and odd-sized batches.** The prototype pads to the next power of two with zero leaves, so padding is never claimable (`position < count`). A root over one commitment is its leaf. A root with `count` 0 can be signed but nothing claims against it. Open: whether a client must refuse to sign `count` 0, whether padding should be a tagged empty leaf instead of zero, and the largest `count`.
5. **Several batches on one channel.** `baseClaimed` is the payer's statement of what came before. Roots are not chained, so a payer who signs a wrong `baseClaimed` underpays, though it is never overcharged beyond one root's `baseClaimed + provenCount × unitPrice`. Open: whether roots should commit to the previous root.
6. **Several lanes per proof.** One proof for *k* requests would present *k* inclusions and settle *k* units in one claim. Open: the encoding, and whether lane results are reported per position ([property 6](./proof_condition.md#core-properties)).
7. **Interop before hardening.** At least two independent implementations of the client's tree and of the gate should agree on roots, paths and digests, and settle against the same channel contract. In the prototype the test builds the tree and derives the digests on its own and compares them with the gate's; that is one implementation checking another in the same repository, not an interop run.

## Version History

| Version | Date | Changes | Authors |
|---|---|---|---|
| v0.2 | 2026-11-25 | Proposal and prototype | @achemperety |
