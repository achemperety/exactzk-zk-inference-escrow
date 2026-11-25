# `batch-settlement` on EVM: a proof claim condition (proposal)

> **Status: proposal, not normative.** Nothing here is a requirement. The design below was proposed in [x402-foundation/x402#4390](https://github.com/x402-foundation/x402/issues/4390), and a prototype checks that it runs against x402's own channel contract. The open points must be settled, and interop runs between independent implementations must pass, before any of it hardens into a binding.

## Summary

[`batch-settlement`](https://github.com/x402-foundation/x402/blob/main/specs/schemes/batch-settlement/scheme_batch_settlement_evm.md) lets a server claim a client's cumulative vouchers from a prepaid channel. The proposal adds a condition on those claims: a voucher's value is claimed only for requests whose input commitments the client signed and a valid proof covers, and it is paid to the payee the client named for that request ([proof_condition.md](./proof_condition.md)).

1. Once per batch, the client signs a **commitment root**: one hash over the batch's ordered requests. Each request is its input commitment **and its payee**.
2. Each claim presents one request with its **position** and an **inclusion proof** (a Merkle path), and a proof of the computation for that request's input commitment.
3. A **gate**, acting as the channel's `receiverAuthorizer` and its `receiver`, checks the root signature, the inclusion at that position, and that the proof is for that very commitment. Only then does it claim one unit of the voucher, and it pays that unit to the request's payee in the same transaction.
4. **Presenting is permissionless.** The gate does not check who calls. Where the unit goes comes from inside the signed root, so the caller cannot change it.
5. The **voucher format is unchanged**. The client keeps signing `Voucher(bytes32 channelId,uint128 maxClaimableAmount)`; the root is a second, separate signature per batch.

## Decision: one root per batch

The client signs the commitment root once per batch. Considered and rejected: a voucher extension that carries each request's commitment. @zambodotdev gave two reasons in [#4390](https://github.com/x402-foundation/x402/issues/4390):
- The per-request commitments already sit inside the root, so a commitment in each voucher makes the client sign N times what one root signature already says.
- Per-voucher commitments admit partial batches, with some vouchers present and some missing. A root rules that out by construction: the batch is one signed object, checkable in one pass.

The root fixes which requests make up the batch. Which of them get proven, and in which order, is still per position (open point 1).

## The prototype

`test/experimental/batch-gate/ProofClaimGate.sol`, tested in `ProofClaimGate.t.sol` against `x402BatchSettlement` from x402's repository (commit `d7d0a435`, copied unchanged into `test/external/x402/`, built locally). It is a test-only contract and is not deployed.

**What the client signs once per batch**, EIP-712 in the gate's domain (`name` "x402 proof claim gate", `version` "0", chain id, the gate's address):

```
CommitmentRoot(bytes32 channelId,bytes32 verifierId,bytes32 root,uint32 count,uint128 unitPrice,uint128 baseClaimed)
```

`unitPrice` is what one proven request unlocks; `baseClaimed` is what the channel had claimed before this batch. The signer is the channel's `payerAuthorizer`, or the payer if there is none, as for vouchers.

**The tree.** Leaf *i* is `keccak256(abi.encode(LEAF_TAG, i, commitment_i, payee_i))`, with `LEAF_TAG = keccak256("x402.proof-claim-gate.leaf.v1")`. A batch may name a different payee for each request. Leaves past `count` are zero, up to the next power of two. A node is `keccak256(left ‖ right)`. The path runs from the leaf up, and bit *j* of the position says whether the node at height *j* is a right child. The path length must be exactly the tree's depth.

**A claim**, `claimWithProof(voucherClaim, rootTerms, rootSignature, inclusion, entry, output, proof)`, open to anyone:
1. The channel's `receiver` and `receiverAuthorizer` must both be the gate.
2. The root signature verifies for the channel id the gate computes from the voucher's channel.
3. `position < count`, and the path opens the root at that position for the presented commitment and payee. A payee other than the committed one does not open it (`InclusionInvalid()`).
4. The position has not been proven before under this root.
5. The proof verifies for `verifierId` and the included commitment. Failures revert with `ProofInvalid()` or `VerifierUnavailable(bytes32)`, the two outcomes of [proof_condition.md](./proof_condition.md#outcomes-of-a-check).
6. `voucherClaim.totalClaimed ≤ baseClaimed + provenCount × unitPrice`.
7. `voucherClaim.totalClaimed` is exactly the channel's claimed total plus one `unitPrice` (`ClaimNotOneUnit(uint128,uint256)` otherwise). A claim that moved less would leave a unit for a later request's payee to collect; one that moved more would take it from an earlier one.
8. The gate calls `x402BatchSettlement.claim`, then `settle` for itself, transfers one `unitPrice` to the request's payee, and emits `ClaimProven` with the payee and the output.

The caller is not checked anywhere, and nothing stays with the gate after a claim.

**Tested** (21 tests, all passing; one is a fuzz test of 512 runs):
- (a) a proof presented by a third party pays the committed payee in the same call, and nobody else; any of four callers presenting the same proof pays the same payee.
- (b) a claim naming any of seven other addresses as the payee (the caller, the payer, the batch's other payees, the gate, the channel contract, zero) is refused; no other payee opens the committed request (fuzz); two requests with the same commitment for two payees cannot shift a unit from one to the other by under-claiming the first; an overstated `baseClaimed` does not let one proof take two units.
- (c) nobody but the gate claims or signs for its channel (the payer, the stranger, every payee); a channel whose `receiver`, or whose `receiverAuthorizer`, is not the gate is refused, and a test shows that the other holder could claim on it with no proof.
- The proven commitment presented at a position it does not hold is refused, with its own path and with the path of the claimed position; the padding position and a path one level short are refused; a proof for another commitment than the included one is refused; an invalid proof is refused and the position stays open; a check that cannot run is `VerifierUnavailable`, never `ProofInvalid`; a root signed by someone else, a root altered after signing, a root signed for another channel and a root signed for another gate are refused; one proof unlocks one unit and a position counts once; `baseClaimed` carries earlier batches; every position of batches of one to nine opens at its own position only.

**Gas**, Osaka schedule, real solo proof, every account cold. A claim now moves the token twice (channel contract to gate, gate to payee); measured with the six-decimal test token, not USDC, whose transfers cost more.

| | Gas |
|---|---:|
| `claimWithProof`, the channel's first claim | 841,445 |
| `claimWithProof`, steady (second batch on the channel) | 793,639 |

Paying the payee in the claim costs 24,429 gas more than v0.2's claim, which left the funds with the gate for a separate payout. One proof per request costs about what a native one-transaction payment does (768,174 with USDC). The saving batching promises needs one proof over several lanes with several inclusions, which the prototype does not do.

## What the prototype found

- **The gate must also be the receiver.** `x402BatchSettlement.claim` admits the channel's `receiver` as well as its `receiverAuthorizer`. A receiver other than the gate can claim any signed voucher without a proof; a test shows it. The gate therefore holds the receiver role and forwards each unit.
- **The payee belongs inside the root.** With the gate as receiver, a payee fixed anywhere outside what the client signed could still be paid for a well-formed claim. Each request's leaf names its payee, so the gate pays only what the root says, whoever presents. The payee is still part of the call: it is presented with the commitment to open the leaf, and a wrong one fails the inclusion check rather than being impossible to name.
- **One unit per proof.** Once requests have their own payees, the cumulative voucher must move exactly one `unitPrice` per proven request; otherwise one payee's unit can be left for, or taken by, another's claim. The gate enforces it against the channel's recorded total.
- **A payee that cannot receive blocks its request.** If the transfer to the payee reverts (for example a token that blocks the address), the claim reverts and the position stays open; the unit stays with the channel until the payer's timed withdrawal.
- **No relayed claims or cooperative refunds.** `claimWithSignature` and `refundWithSignature` need an ERC-1271 answer from the receiver authorizer. The prototype gives none, so its channels have neither. The payer leaves through the timed withdrawal (at least 15 minutes). A gate could answer ERC-1271 for refunds it is told to allow; that is not designed.
- **Two ceilings.** The payer's voucher still caps every claim (`ClaimExceedsCeiling` in the channel contract), and the root caps it at what was proven. A claim needs both.
- **The position is bound twice**, in the leaf and in the path's bits. See leaf encoding below.

## Open points

1. **Ordering.** What fixes position *i*: the order in which the server received the requests, a client counter, or the vouchers' sequence? What happens when a request is dropped or two arrive out of order? In the prototype positions are independent: any subset can be proven, in any order, and an unproven position blocks nothing.
2. **Leaf encoding.** The prototype's leaf tags, then encodes the position, the commitment and the payee. Open: whether the leaf also carries the request's price (`batch-settlement` lets the server charge less than the maximum, and a uniform `unitPrice` cannot express that); whether leaves and inner nodes need distinct tags (the prototype relies on their different preimage lengths, 128 and 64 bytes); whether pairs are positional, as here, or sorted. Binding the position in the leaf as well as in the path's bits is redundant; one of the two should be chosen.
3. **Domain separation.** In the prototype: chain id (in the gate's EIP-712 domain, and in the channel id, which the channel contract derives in its own domain); channel id (in the signed struct); gate address (`verifyingContract`); version (the domain's `version` "0" and the leaf tag's "v1"). Open: whether the channel contract and the verifier should be named explicitly rather than through the channel id and the struct, and whether one root may span several channels.
4. **Empty and odd-sized batches.** The prototype pads to the next power of two with zero leaves, so padding is never claimable (`position < count`). A root over one commitment is its leaf. A root with `count` 0 can be signed but nothing claims against it. Open: whether a client must refuse to sign `count` 0, whether padding should be a tagged empty leaf instead of zero, and the largest `count`.
5. **Several batches on one channel.** `baseClaimed` is the payer's statement of what came before. Roots are not chained. With one unit per proof, a root never costs the payer more than `count × unitPrice`, whatever its `baseClaimed`; an understated `baseClaimed` blocks claims, so the server is underpaid, and two batches signed against the same `baseClaimed` block each other once one of them is claimed. Open: whether roots should commit to the previous root, or whether `baseClaimed` can go.
6. **Several lanes per proof.** One proof for *k* requests would present *k* inclusions and settle *k* units in one claim. Open: the encoding, and whether lane results are reported per position ([property 7](./proof_condition.md#core-properties)).
7. **Interop before hardening.** At least two independent implementations of the client's tree and of the gate should agree on roots, paths and digests, and settle against the same channel contract. In the prototype the test builds the tree and derives the digests on its own and compares them with the gate's; that is one implementation checking another in the same repository, not an interop run.

## Version History

| Version | Date | Changes | Authors |
|---|---|---|---|
| v0.2 | 2026-11-25 | Proposal and prototype | @achemperety |
| v0.3 | 2026-11-25 | Each request's leaf names its payee; the gate pays it in the claim, one unit per proof; presenting stays permissionless; one root per batch decided, the voucher extension recorded as rejected | @achemperety |
