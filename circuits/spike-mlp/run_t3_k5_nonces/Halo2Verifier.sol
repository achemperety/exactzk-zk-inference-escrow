// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract Halo2Verifier {
    uint256 internal constant    DELTA = 4131629893567559867359510883348571134090853742863529169391034518566172092834;
    uint256 internal constant        R = 21888242871839275222246405745257275088548364400416034343698204186575808495617; 

    uint256 internal constant FIRST_QUOTIENT_X_CPTR = 0x05a4;
    uint256 internal constant  LAST_QUOTIENT_X_CPTR = 0x06a4;

    uint256 internal constant                VK_MPTR = 0x0820;
    uint256 internal constant         VK_DIGEST_MPTR = 0x0820;
    uint256 internal constant     NUM_INSTANCES_MPTR = 0x0840;
    uint256 internal constant                 K_MPTR = 0x0860;
    uint256 internal constant             N_INV_MPTR = 0x0880;
    uint256 internal constant             OMEGA_MPTR = 0x08a0;
    uint256 internal constant         OMEGA_INV_MPTR = 0x08c0;
    uint256 internal constant    OMEGA_INV_TO_L_MPTR = 0x08e0;
    uint256 internal constant   HAS_ACCUMULATOR_MPTR = 0x0900;
    uint256 internal constant        ACC_OFFSET_MPTR = 0x0920;
    uint256 internal constant     NUM_ACC_LIMBS_MPTR = 0x0940;
    uint256 internal constant NUM_ACC_LIMB_BITS_MPTR = 0x0960;
    uint256 internal constant              G1_X_MPTR = 0x0980;
    uint256 internal constant              G1_Y_MPTR = 0x09a0;
    uint256 internal constant            G2_X_1_MPTR = 0x09c0;
    uint256 internal constant            G2_X_2_MPTR = 0x09e0;
    uint256 internal constant            G2_Y_1_MPTR = 0x0a00;
    uint256 internal constant            G2_Y_2_MPTR = 0x0a20;
    uint256 internal constant      NEG_S_G2_X_1_MPTR = 0x0a40;
    uint256 internal constant      NEG_S_G2_X_2_MPTR = 0x0a60;
    uint256 internal constant      NEG_S_G2_Y_1_MPTR = 0x0a80;
    uint256 internal constant      NEG_S_G2_Y_2_MPTR = 0x0aa0;

    uint256 internal constant CHALLENGE_MPTR = 0x1200;

    uint256 internal constant THETA_MPTR = 0x1200;
    uint256 internal constant  BETA_MPTR = 0x1220;
    uint256 internal constant GAMMA_MPTR = 0x1240;
    uint256 internal constant     Y_MPTR = 0x1260;
    uint256 internal constant     X_MPTR = 0x1280;
    uint256 internal constant  ZETA_MPTR = 0x12a0;
    uint256 internal constant    NU_MPTR = 0x12c0;
    uint256 internal constant    MU_MPTR = 0x12e0;

    uint256 internal constant       ACC_LHS_X_MPTR = 0x1300;
    uint256 internal constant       ACC_LHS_Y_MPTR = 0x1320;
    uint256 internal constant       ACC_RHS_X_MPTR = 0x1340;
    uint256 internal constant       ACC_RHS_Y_MPTR = 0x1360;
    uint256 internal constant             X_N_MPTR = 0x1380;
    uint256 internal constant X_N_MINUS_1_INV_MPTR = 0x13a0;
    uint256 internal constant          L_LAST_MPTR = 0x13c0;
    uint256 internal constant         L_BLIND_MPTR = 0x13e0;
    uint256 internal constant             L_0_MPTR = 0x1400;
    uint256 internal constant   INSTANCE_EVAL_MPTR = 0x1420;
    uint256 internal constant   QUOTIENT_EVAL_MPTR = 0x1440;
    uint256 internal constant      QUOTIENT_X_MPTR = 0x1460;
    uint256 internal constant      QUOTIENT_Y_MPTR = 0x1480;
    uint256 internal constant          R_EVAL_MPTR = 0x14a0;
    uint256 internal constant   PAIRING_LHS_X_MPTR = 0x14c0;
    uint256 internal constant   PAIRING_LHS_Y_MPTR = 0x14e0;
    uint256 internal constant   PAIRING_RHS_X_MPTR = 0x1500;
    uint256 internal constant   PAIRING_RHS_Y_MPTR = 0x1520;

    function verifyProof(
        bytes calldata proof,
        uint256[] calldata instances
    ) public returns (bool) {
        assembly {
            // Read EC point (x, y) at (proof_cptr, proof_cptr + 0x20),
            // and check if the point is on affine plane,
            // and store them in (hash_mptr, hash_mptr + 0x20).
            // Return updated (success, proof_cptr, hash_mptr).
            function read_ec_point(success, proof_cptr, hash_mptr, q) -> ret0, ret1, ret2 {
                let x := calldataload(proof_cptr)
                let y := calldataload(add(proof_cptr, 0x20))
                ret0 := and(success, lt(x, q))
                ret0 := and(ret0, lt(y, q))
                ret0 := and(ret0, eq(mulmod(y, y, q), addmod(mulmod(x, mulmod(x, x, q), q), 3, q)))
                mstore(hash_mptr, x)
                mstore(add(hash_mptr, 0x20), y)
                ret1 := add(proof_cptr, 0x40)
                ret2 := add(hash_mptr, 0x40)
            }

            // Squeeze challenge by keccak256(memory[0..hash_mptr]),
            // and store hash mod r as challenge in challenge_mptr,
            // and push back hash in 0x00 as the first input for next squeeze.
            // Return updated (challenge_mptr, hash_mptr).
            function squeeze_challenge(challenge_mptr, hash_mptr, r) -> ret0, ret1 {
                let hash := keccak256(0x00, hash_mptr)
                mstore(challenge_mptr, mod(hash, r))
                mstore(0x00, hash)
                ret0 := add(challenge_mptr, 0x20)
                ret1 := 0x20
            }

            // Squeeze challenge without absorbing new input from calldata,
            // by putting an extra 0x01 in memory[0x20] and squeeze by keccak256(memory[0..21]),
            // and store hash mod r as challenge in challenge_mptr,
            // and push back hash in 0x00 as the first input for next squeeze.
            // Return updated (challenge_mptr).
            function squeeze_challenge_cont(challenge_mptr, r) -> ret {
                mstore8(0x20, 0x01)
                let hash := keccak256(0x00, 0x21)
                mstore(challenge_mptr, mod(hash, r))
                mstore(0x00, hash)
                ret := add(challenge_mptr, 0x20)
            }

            // Batch invert values in memory[mptr_start..mptr_end] in place.
            // Return updated (success).
            function batch_invert(success, mptr_start, mptr_end) -> ret {
                let gp_mptr := mptr_end
                let gp := mload(mptr_start)
                let mptr := add(mptr_start, 0x20)
                for
                    {}
                    lt(mptr, sub(mptr_end, 0x20))
                    {}
                {
                    gp := mulmod(gp, mload(mptr), R)
                    mstore(gp_mptr, gp)
                    mptr := add(mptr, 0x20)
                    gp_mptr := add(gp_mptr, 0x20)
                }
                gp := mulmod(gp, mload(mptr), R)

                mstore(gp_mptr, 0x20)
                mstore(add(gp_mptr, 0x20), 0x20)
                mstore(add(gp_mptr, 0x40), 0x20)
                mstore(add(gp_mptr, 0x60), gp)
                mstore(add(gp_mptr, 0x80), sub(R, 2))
                mstore(add(gp_mptr, 0xa0), R)
                ret := and(success, staticcall(gas(), 0x05, gp_mptr, 0xc0, gp_mptr, 0x20))
                let all_inv := mload(gp_mptr)

                let first_mptr := mptr_start
                let second_mptr := add(first_mptr, 0x20)
                gp_mptr := sub(gp_mptr, 0x20)
                for
                    {}
                    lt(second_mptr, mptr)
                    {}
                {
                    let inv := mulmod(all_inv, mload(gp_mptr), R)
                    all_inv := mulmod(all_inv, mload(mptr), R)
                    mstore(mptr, inv)
                    mptr := sub(mptr, 0x20)
                    gp_mptr := sub(gp_mptr, 0x20)
                }
                let inv_first := mulmod(all_inv, mload(second_mptr), R)
                let inv_second := mulmod(all_inv, mload(first_mptr), R)
                mstore(first_mptr, inv_first)
                mstore(second_mptr, inv_second)
            }

            // Add (x, y) into point at (0x00, 0x20).
            // Return updated (success).
            function ec_add_acc(success, x, y) -> ret {
                mstore(0x40, x)
                mstore(0x60, y)
                ret := and(success, staticcall(gas(), 0x06, 0x00, 0x80, 0x00, 0x40))
            }

            // Scale point at (0x00, 0x20) by scalar.
            function ec_mul_acc(success, scalar) -> ret {
                mstore(0x40, scalar)
                ret := and(success, staticcall(gas(), 0x07, 0x00, 0x60, 0x00, 0x40))
            }

            // Add (x, y) into point at (0x80, 0xa0).
            // Return updated (success).
            function ec_add_tmp(success, x, y) -> ret {
                mstore(0xc0, x)
                mstore(0xe0, y)
                ret := and(success, staticcall(gas(), 0x06, 0x80, 0x80, 0x80, 0x40))
            }

            // Scale point at (0x80, 0xa0) by scalar.
            // Return updated (success).
            function ec_mul_tmp(success, scalar) -> ret {
                mstore(0xc0, scalar)
                ret := and(success, staticcall(gas(), 0x07, 0x80, 0x60, 0x80, 0x40))
            }

            // Perform pairing check.
            // Return updated (success).
            function ec_pairing(success, lhs_x, lhs_y, rhs_x, rhs_y) -> ret {
                mstore(0x00, lhs_x)
                mstore(0x20, lhs_y)
                mstore(0x40, mload(G2_X_1_MPTR))
                mstore(0x60, mload(G2_X_2_MPTR))
                mstore(0x80, mload(G2_Y_1_MPTR))
                mstore(0xa0, mload(G2_Y_2_MPTR))
                mstore(0xc0, rhs_x)
                mstore(0xe0, rhs_y)
                mstore(0x100, mload(NEG_S_G2_X_1_MPTR))
                mstore(0x120, mload(NEG_S_G2_X_2_MPTR))
                mstore(0x140, mload(NEG_S_G2_Y_1_MPTR))
                mstore(0x160, mload(NEG_S_G2_Y_2_MPTR))
                ret := and(success, staticcall(gas(), 0x08, 0x00, 0x180, 0x00, 0x20))
                ret := and(ret, mload(0x00))
            }

            // Modulus
            let q := 21888242871839275222246405745257275088696311157297823662689037894645226208583 // BN254 base field
            let r := 21888242871839275222246405745257275088548364400416034343698204186575808495617 // BN254 scalar field 

            // Initialize success as true
            let success := true

            {
                // Load vk_digest and num_instances of vk into memory
                mstore(0x0820, 0x1ff1da7523f3f0b3836df5658c59f791ec7735032c32ec6de8a175b7e6395c60) // vk_digest
                mstore(0x0840, 0x000000000000000000000000000000000000000000000000000000000000000b) // num_instances

                // Check valid length of proof
                success := and(success, eq(0x0f00, proof.length))

                // Check valid length of instances
                let num_instances := mload(NUM_INSTANCES_MPTR)
                success := and(success, eq(num_instances, instances.length))

                // Absorb vk diegst
                mstore(0x00, mload(VK_DIGEST_MPTR))

                // Read instances and witness commitments and generate challenges
                let hash_mptr := 0x20
                let instance_cptr := instances.offset
                for
                    { let instance_cptr_end := add(instance_cptr, mul(0x20, num_instances)) }
                    lt(instance_cptr, instance_cptr_end)
                    {}
                {
                    let instance := calldataload(instance_cptr)
                    success := and(success, lt(instance, r))
                    mstore(hash_mptr, instance)
                    instance_cptr := add(instance_cptr, 0x20)
                    hash_mptr := add(hash_mptr, 0x20)
                }

                let proof_cptr := proof.offset
                let challenge_mptr := CHALLENGE_MPTR

                // Phase 1
                for
                    { let proof_cptr_end := add(proof_cptr, 0x0240) }
                    lt(proof_cptr, proof_cptr_end)
                    {}
                {
                    success, proof_cptr, hash_mptr := read_ec_point(success, proof_cptr, hash_mptr, q)
                }

                challenge_mptr, hash_mptr := squeeze_challenge(challenge_mptr, hash_mptr, r)

                // Phase 2
                for
                    { let proof_cptr_end := add(proof_cptr, 0x0100) }
                    lt(proof_cptr, proof_cptr_end)
                    {}
                {
                    success, proof_cptr, hash_mptr := read_ec_point(success, proof_cptr, hash_mptr, q)
                }

                challenge_mptr, hash_mptr := squeeze_challenge(challenge_mptr, hash_mptr, r)
                challenge_mptr := squeeze_challenge_cont(challenge_mptr, r)

                // Phase 3
                for
                    { let proof_cptr_end := add(proof_cptr, 0x0200) }
                    lt(proof_cptr, proof_cptr_end)
                    {}
                {
                    success, proof_cptr, hash_mptr := read_ec_point(success, proof_cptr, hash_mptr, q)
                }

                challenge_mptr, hash_mptr := squeeze_challenge(challenge_mptr, hash_mptr, r)

                // Phase 4
                for
                    { let proof_cptr_end := add(proof_cptr, 0x0140) }
                    lt(proof_cptr, proof_cptr_end)
                    {}
                {
                    success, proof_cptr, hash_mptr := read_ec_point(success, proof_cptr, hash_mptr, q)
                }

                challenge_mptr, hash_mptr := squeeze_challenge(challenge_mptr, hash_mptr, r)

                // Read evaluations
                for
                    { let proof_cptr_end := add(proof_cptr, 0x0800) }
                    lt(proof_cptr, proof_cptr_end)
                    {}
                {
                    let eval := calldataload(proof_cptr)
                    success := and(success, lt(eval, r))
                    mstore(hash_mptr, eval)
                    proof_cptr := add(proof_cptr, 0x20)
                    hash_mptr := add(hash_mptr, 0x20)
                }

                // Read batch opening proof and generate challenges
                challenge_mptr, hash_mptr := squeeze_challenge(challenge_mptr, hash_mptr, r)       // zeta
                challenge_mptr := squeeze_challenge_cont(challenge_mptr, r)                        // nu

                success, proof_cptr, hash_mptr := read_ec_point(success, proof_cptr, hash_mptr, q) // W

                challenge_mptr, hash_mptr := squeeze_challenge(challenge_mptr, hash_mptr, r)       // mu

                success, proof_cptr, hash_mptr := read_ec_point(success, proof_cptr, hash_mptr, q) // W'

                // Load full vk into memory
                mstore(0x0820, 0x1ff1da7523f3f0b3836df5658c59f791ec7735032c32ec6de8a175b7e6395c60) // vk_digest
                mstore(0x0840, 0x000000000000000000000000000000000000000000000000000000000000000b) // num_instances
                mstore(0x0860, 0x0000000000000000000000000000000000000000000000000000000000000010) // k
                mstore(0x0880, 0x30641e0e92bebef818268d663bcad6dbcfd6c0149170f6d7d350b1b1fa6c1001) // n_inv
                mstore(0x08a0, 0x09d2cc4b5782fbe923e49ace3f647643a5f5d8fb89091c3ababd582133584b29) // omega
                mstore(0x08c0, 0x0cf312e84f2456134e812826473d3dfb577b2bfdba762aba88b47b740472c1f0) // omega_inv
                mstore(0x08e0, 0x17cbd779ed6ea1b8e9dbcde0345b2cfdb96e80bea0dd1318bdd0e183a00e0492) // omega_inv_to_l
                mstore(0x0900, 0x0000000000000000000000000000000000000000000000000000000000000000) // has_accumulator
                mstore(0x0920, 0x0000000000000000000000000000000000000000000000000000000000000000) // acc_offset
                mstore(0x0940, 0x0000000000000000000000000000000000000000000000000000000000000000) // num_acc_limbs
                mstore(0x0960, 0x0000000000000000000000000000000000000000000000000000000000000000) // num_acc_limb_bits
                mstore(0x0980, 0x0000000000000000000000000000000000000000000000000000000000000001) // g1_x
                mstore(0x09a0, 0x0000000000000000000000000000000000000000000000000000000000000002) // g1_y
                mstore(0x09c0, 0x198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2) // g2_x_1
                mstore(0x09e0, 0x1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed) // g2_x_2
                mstore(0x0a00, 0x090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b) // g2_y_1
                mstore(0x0a20, 0x12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa) // g2_y_2
                mstore(0x0a40, 0x16a069a01ebf6d2ed6a8a472d1f5c89378a74eab793b08440613cf2eb3664f35) // neg_s_g2_x_1
                mstore(0x0a60, 0x248769a2ebd577499188ac1853c64456686c916d02135169f35245a8f8d20190) // neg_s_g2_x_2
                mstore(0x0a80, 0x2ef853c3f422287dcf6747afe56184c23b075b0938607d3a199cd09cee68e2e9) // neg_s_g2_y_1
                mstore(0x0aa0, 0x01304b9233efdcf5cbe703e14e8f67a01a1d3cb764d8c86179480f8250ceee89) // neg_s_g2_y_2
                mstore(0x0ac0, 0x0c7ccd87e50f025d3084243e469888f26b39942cd3f41ed07f43e1bda0e2f1bc) // fixed_comms[0].x
                mstore(0x0ae0, 0x289b23fa9fd4978c8d32a42294c16e1c28a6bea0f973476b89d7c817cd929683) // fixed_comms[0].y
                mstore(0x0b00, 0x29da04a4ef1d793b276c7d4444b56a6ae2025ed5b8d77af347542b8a868b3f78) // fixed_comms[1].x
                mstore(0x0b20, 0x11afba3526869db4924b992e63718b910215c0f24e9a308f20bc90ac0591f1d1) // fixed_comms[1].y
                mstore(0x0b40, 0x267850e1c49717f5e985753477ec4c939234095787418d853d3a843e1a792432) // fixed_comms[2].x
                mstore(0x0b60, 0x0b813025342f51e304f9a24f35e7a9c2a0b85e6532b91efa0d609f30dee6e20d) // fixed_comms[2].y
                mstore(0x0b80, 0x30483764d105c4b46794d3b64f66bdd1d5642d21d797420cc7efdc5fb525fc81) // fixed_comms[3].x
                mstore(0x0ba0, 0x05308139bd34051eeab5ed91359b5e5497b7510ca701ca7e738fdec9ea4a8558) // fixed_comms[3].y
                mstore(0x0bc0, 0x2cd09b160590875fe145b664c1082f78f571f2f28fd12db2cd3956fbd707e4d3) // fixed_comms[4].x
                mstore(0x0be0, 0x0daafca940d54a1a1563fdef5bf7da5966b2f5055983583deb30c1323ffbd125) // fixed_comms[4].y
                mstore(0x0c00, 0x19434db43b8495002cd08c368f17bd2f520b59244daffed7c46eb44172e16f29) // fixed_comms[5].x
                mstore(0x0c20, 0x09d89e36f31d328bafe8b7545a9172dc1fcf1f829f722b33296e1dc32b6b1bc7) // fixed_comms[5].y
                mstore(0x0c40, 0x256b67144f18ff19428b25d87b23da6d03ee6d78d99a9aa97de6290e2e3a5ce4) // fixed_comms[6].x
                mstore(0x0c60, 0x10e036ab4d9b06328038f079ccc207bf2090a255debcc9de4cc1c3b1dfe6e355) // fixed_comms[6].y
                mstore(0x0c80, 0x133653827e4281e02e0ac6317baeb24cee19d91aac59b5394a17589594a1996d) // fixed_comms[7].x
                mstore(0x0ca0, 0x26509ff1deff5e429299e7a42b5810ac086deedeb8ca428495f9103638ef2478) // fixed_comms[7].y
                mstore(0x0cc0, 0x133653827e4281e02e0ac6317baeb24cee19d91aac59b5394a17589594a1996d) // fixed_comms[8].x
                mstore(0x0ce0, 0x26509ff1deff5e429299e7a42b5810ac086deedeb8ca428495f9103638ef2478) // fixed_comms[8].y
                mstore(0x0d00, 0x290039bed1cd9a5188fa7a1d2468311b545718e49a84880cbf272427aaf4d844) // fixed_comms[9].x
                mstore(0x0d20, 0x14f3c2085f673d8674539021f25c01cfdf6f61507861babdcf18b338e0752692) // fixed_comms[9].y
                mstore(0x0d40, 0x290039bed1cd9a5188fa7a1d2468311b545718e49a84880cbf272427aaf4d844) // fixed_comms[10].x
                mstore(0x0d60, 0x14f3c2085f673d8674539021f25c01cfdf6f61507861babdcf18b338e0752692) // fixed_comms[10].y
                mstore(0x0d80, 0x1659ef922d3f5175095416408d7b168ad264c80cb2d01b48372f21052793c0e9) // fixed_comms[11].x
                mstore(0x0da0, 0x1fffaf07e0fadd5328e05b9e1109849a1e844f44a6a3617f9c185370d04fe57b) // fixed_comms[11].y
                mstore(0x0dc0, 0x0c54502f6d627914fecd7ffbd2817faf444e801a3193fcb3bf7bd9637104818d) // fixed_comms[12].x
                mstore(0x0de0, 0x253386f719593f69026e60cc522886037b60b1626a863062614940bace40e55a) // fixed_comms[12].y
                mstore(0x0e00, 0x123cbe0d2325e30119fb355ba80443dcab7855222f582b866128214e0f779324) // fixed_comms[13].x
                mstore(0x0e20, 0x09104424498e912d4c03b4e21910a9c86a267fb0662be4a4b841c70a9acdde17) // fixed_comms[13].y
                mstore(0x0e40, 0x1bc7d66ef591b44d5907a44b646c6ca4e8e453d9ae835ba00c36062d4e7de786) // fixed_comms[14].x
                mstore(0x0e60, 0x13ab01ed0043705c649e66a52f5e318a9a439483c85a33cf5dc97ad8559c55d0) // fixed_comms[14].y
                mstore(0x0e80, 0x131c19b49f5fb96c74575a8cb6626ef544be2184a355fbbe7f17ae7582786edc) // fixed_comms[15].x
                mstore(0x0ea0, 0x1f72a9c027999f87d4a9ff150cd079506ec5d65f975dd6030c8e69f981c4d226) // fixed_comms[15].y
                mstore(0x0ec0, 0x0000000000000000000000000000000000000000000000000000000000000000) // fixed_comms[16].x
                mstore(0x0ee0, 0x0000000000000000000000000000000000000000000000000000000000000000) // fixed_comms[16].y
                mstore(0x0f00, 0x1b3835eb6969d16978a216703c72344d097d4e21553a066167423979e025fd3f) // permutation_comms[0].x
                mstore(0x0f20, 0x0ca872688461e45c44fc6df239b475d0bb96976cd2c5047033e98816cde552f5) // permutation_comms[0].y
                mstore(0x0f40, 0x22ad53e026d92a481ced7654be5bc7cd1e00d3d4c558d9dd2114f1ade5ae7547) // permutation_comms[1].x
                mstore(0x0f60, 0x2fec9dee00d540a48a5bcddfd6e96270bc33ea4487b59f2ca0f0752e4664b8d6) // permutation_comms[1].y
                mstore(0x0f80, 0x2d74056ea70fd949f984beb07c113cceb46912e1406898220300d00dd9da0f92) // permutation_comms[2].x
                mstore(0x0fa0, 0x2180e564f8647f44f70fe11c6c91afd2ba43352e2aed1f6f3970cf1ad7be28d1) // permutation_comms[2].y
                mstore(0x0fc0, 0x155f1520abe145a18b4d2e21f2a99c41128805f4b216f937e241a1624a1b6acb) // permutation_comms[3].x
                mstore(0x0fe0, 0x2d9ac631998857202bb457307defcb881ac32fed20bb9741bded181584ae913b) // permutation_comms[3].y
                mstore(0x1000, 0x048de3070456019736ed2663fee8943888ef939221d764568bc47862f5b58609) // permutation_comms[4].x
                mstore(0x1020, 0x014cebb235414f87b01c30fde13891a3da1f61a08317408a055aebe2418c9a90) // permutation_comms[4].y
                mstore(0x1040, 0x0bfcedfff8e1eaec9662d88e740843d82bd9729d482b8a75e053316aae6d2e23) // permutation_comms[5].x
                mstore(0x1060, 0x0bea803512a9c863e3fe24764c5949c3e8d259cb8efe883bba533793e65a903f) // permutation_comms[5].y
                mstore(0x1080, 0x169171fc790bbb1b9605667714a6c49fdce7aad9fe6b91048066279468cb53cb) // permutation_comms[6].x
                mstore(0x10a0, 0x1cb7f1c2946fc64ccfd5dcad18d40fe5cf313359136c0401df0000b55bebb71a) // permutation_comms[6].y
                mstore(0x10c0, 0x06219e3ba4efdd1880e4121acb8ab23178c3458bb7b304431e7aff21d8be5ba7) // permutation_comms[7].x
                mstore(0x10e0, 0x292d1666b304b465bf498774f7986c70e9a7ad7419871c2388531c15e551ef7d) // permutation_comms[7].y
                mstore(0x1100, 0x138a39615e769cc642f02adfb8d5c05d358d8b84f8c3065243881c9d68d623f1) // permutation_comms[8].x
                mstore(0x1120, 0x118f3c071d826f079cd5eb42cf1a5a50cabb19ec29b4546197d3d163f18c454c) // permutation_comms[8].y
                mstore(0x1140, 0x052b71be189b7c69c6692bac6aff39fac3291493974aecdbe994212656758e98) // permutation_comms[9].x
                mstore(0x1160, 0x0e348164a6d5ec8b288fe4300cd03a176843611f9d74f418b8c826cdef013f68) // permutation_comms[9].y
                mstore(0x1180, 0x0447a9b7dfa34c20fea8bc93e3c634a9de5e208b801dbf103c685b34b1b20099) // permutation_comms[10].x
                mstore(0x11a0, 0x13139bc523afb46e7dd41ba0dc14969c299d858187a23ac5c1006b62ee60e94e) // permutation_comms[10].y
                mstore(0x11c0, 0x14dd536da13db8f99e2ed6d1c91be736b3505c0a1a26a91f73f1fed16e002d4a) // permutation_comms[11].x
                mstore(0x11e0, 0x0b221c50901bb11197b49aa7d9ccff4d68a061b29e34c37f28d392677487dfab) // permutation_comms[11].y

                // Read accumulator from instances
                if mload(HAS_ACCUMULATOR_MPTR) {
                    let num_limbs := mload(NUM_ACC_LIMBS_MPTR)
                    let num_limb_bits := mload(NUM_ACC_LIMB_BITS_MPTR)

                    let cptr := add(instances.offset, mul(mload(ACC_OFFSET_MPTR), 0x20))
                    let lhs_y_off := mul(num_limbs, 0x20)
                    let rhs_x_off := mul(lhs_y_off, 2)
                    let rhs_y_off := mul(lhs_y_off, 3)
                    let lhs_x := calldataload(cptr)
                    let lhs_y := calldataload(add(cptr, lhs_y_off))
                    let rhs_x := calldataload(add(cptr, rhs_x_off))
                    let rhs_y := calldataload(add(cptr, rhs_y_off))
                    for
                        {
                            let cptr_end := add(cptr, mul(0x20, num_limbs))
                            let shift := num_limb_bits
                        }
                        lt(cptr, cptr_end)
                        {}
                    {
                        cptr := add(cptr, 0x20)
                        lhs_x := add(lhs_x, shl(shift, calldataload(cptr)))
                        lhs_y := add(lhs_y, shl(shift, calldataload(add(cptr, lhs_y_off))))
                        rhs_x := add(rhs_x, shl(shift, calldataload(add(cptr, rhs_x_off))))
                        rhs_y := add(rhs_y, shl(shift, calldataload(add(cptr, rhs_y_off))))
                        shift := add(shift, num_limb_bits)
                    }

                    success := and(success, eq(mulmod(lhs_y, lhs_y, q), addmod(mulmod(lhs_x, mulmod(lhs_x, lhs_x, q), q), 3, q)))
                    success := and(success, eq(mulmod(rhs_y, rhs_y, q), addmod(mulmod(rhs_x, mulmod(rhs_x, rhs_x, q), q), 3, q)))

                    mstore(ACC_LHS_X_MPTR, lhs_x)
                    mstore(ACC_LHS_Y_MPTR, lhs_y)
                    mstore(ACC_RHS_X_MPTR, rhs_x)
                    mstore(ACC_RHS_Y_MPTR, rhs_y)
                }

                pop(q)
            }

            // Revert earlier if anything from calldata is invalid
            if iszero(success) {
                revert(0, 0)
            }

            // Compute lagrange evaluations and instance evaluation
            {
                let k := mload(K_MPTR)
                let x := mload(X_MPTR)
                let x_n := x
                for
                    { let idx := 0 }
                    lt(idx, k)
                    { idx := add(idx, 1) }
                {
                    x_n := mulmod(x_n, x_n, r)
                }

                let omega := mload(OMEGA_MPTR)

                let mptr := X_N_MPTR
                let mptr_end := add(mptr, mul(0x20, add(mload(NUM_INSTANCES_MPTR), 6)))
                if iszero(mload(NUM_INSTANCES_MPTR)) {
                    mptr_end := add(mptr_end, 0x20)
                }
                for
                    { let pow_of_omega := mload(OMEGA_INV_TO_L_MPTR) }
                    lt(mptr, mptr_end)
                    { mptr := add(mptr, 0x20) }
                {
                    mstore(mptr, addmod(x, sub(r, pow_of_omega), r))
                    pow_of_omega := mulmod(pow_of_omega, omega, r)
                }
                let x_n_minus_1 := addmod(x_n, sub(r, 1), r)
                mstore(mptr_end, x_n_minus_1)
                success := batch_invert(success, X_N_MPTR, add(mptr_end, 0x20))

                mptr := X_N_MPTR
                let l_i_common := mulmod(x_n_minus_1, mload(N_INV_MPTR), r)
                for
                    { let pow_of_omega := mload(OMEGA_INV_TO_L_MPTR) }
                    lt(mptr, mptr_end)
                    { mptr := add(mptr, 0x20) }
                {
                    mstore(mptr, mulmod(l_i_common, mulmod(mload(mptr), pow_of_omega, r), r))
                    pow_of_omega := mulmod(pow_of_omega, omega, r)
                }

                let l_blind := mload(add(X_N_MPTR, 0x20))
                let l_i_cptr := add(X_N_MPTR, 0x40)
                for
                    { let l_i_cptr_end := add(X_N_MPTR, 0xc0) }
                    lt(l_i_cptr, l_i_cptr_end)
                    { l_i_cptr := add(l_i_cptr, 0x20) }
                {
                    l_blind := addmod(l_blind, mload(l_i_cptr), r)
                }

                let instance_eval := 0
                for
                    {
                        let instance_cptr := instances.offset
                        let instance_cptr_end := add(instance_cptr, mul(0x20, mload(NUM_INSTANCES_MPTR)))
                    }
                    lt(instance_cptr, instance_cptr_end)
                    {
                        instance_cptr := add(instance_cptr, 0x20)
                        l_i_cptr := add(l_i_cptr, 0x20)
                    }
                {
                    instance_eval := addmod(instance_eval, mulmod(mload(l_i_cptr), calldataload(instance_cptr), r), r)
                }

                let x_n_minus_1_inv := mload(mptr_end)
                let l_last := mload(X_N_MPTR)
                let l_0 := mload(add(X_N_MPTR, 0xc0))

                mstore(X_N_MPTR, x_n)
                mstore(X_N_MINUS_1_INV_MPTR, x_n_minus_1_inv)
                mstore(L_LAST_MPTR, l_last)
                mstore(L_BLIND_MPTR, l_blind)
                mstore(L_0_MPTR, l_0)
                mstore(INSTANCE_EVAL_MPTR, instance_eval)
            }

            // Compute quotient evavluation
            {
                let quotient_eval_numer
                let y := mload(Y_MPTR)
                {
                    let f_11 := calldataload(0x0a04)
                    let a_6 := calldataload(0x07a4)
                    let f_1 := calldataload(0x0904)
                    let var0 := addmod(a_6, f_1, R)
                    let var1 := mulmod(var0, var0, R)
                    let var2 := mulmod(var1, var1, R)
                    let var3 := mulmod(var2, var0, R)
                    let var4 := mulmod(var3, 0x66f6f85d6f68a85ec10345351a23a3aaf07f38af8c952a7bceca70bd2af7ad5, R)
                    let a_7 := calldataload(0x07c4)
                    let f_2 := calldataload(0x0924)
                    let var5 := addmod(a_7, f_2, R)
                    let var6 := mulmod(var5, var5, R)
                    let var7 := mulmod(var6, var6, R)
                    let var8 := mulmod(var7, var5, R)
                    let var9 := mulmod(var8, 0x2b9d4b4110c9ae997782e1509b1d0fdb20a7c02bbd8bea7305462b9f8125b1e8, R)
                    let var10 := addmod(var4, var9, R)
                    let a_6_next_1 := calldataload(0x07e4)
                    let var11 := sub(R, a_6_next_1)
                    let var12 := addmod(var10, var11, R)
                    let var13 := mulmod(f_11, var12, R)
                    quotient_eval_numer := var13
                }
                {
                    let f_11 := calldataload(0x0a04)
                    let a_6 := calldataload(0x07a4)
                    let f_1 := calldataload(0x0904)
                    let var0 := addmod(a_6, f_1, R)
                    let var1 := mulmod(var0, var0, R)
                    let var2 := mulmod(var1, var1, R)
                    let var3 := mulmod(var2, var0, R)
                    let var4 := mulmod(var3, 0xcc57cdbb08507d62bf67a4493cc262fb6c09d557013fff1f573f431221f8ff9, R)
                    let a_7 := calldataload(0x07c4)
                    let f_2 := calldataload(0x0924)
                    let var5 := addmod(a_7, f_2, R)
                    let var6 := mulmod(var5, var5, R)
                    let var7 := mulmod(var6, var6, R)
                    let var8 := mulmod(var7, var5, R)
                    let var9 := mulmod(var8, 0x1274e649a32ed355a31a6ed69724e1adade857e86eb5c3a121bcd147943203c8, R)
                    let var10 := addmod(var4, var9, R)
                    let a_7_next_1 := calldataload(0x0804)
                    let var11 := sub(R, a_7_next_1)
                    let var12 := addmod(var10, var11, R)
                    let var13 := mulmod(f_11, var12, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var13, r)
                }
                {
                    let f_12 := calldataload(0x0a24)
                    let a_6 := calldataload(0x07a4)
                    let f_1 := calldataload(0x0904)
                    let var0 := addmod(a_6, f_1, R)
                    let var1 := mulmod(var0, var0, R)
                    let var2 := mulmod(var1, var1, R)
                    let var3 := mulmod(var2, var0, R)
                    let a_8 := calldataload(0x0824)
                    let var4 := sub(R, a_8)
                    let var5 := addmod(var3, var4, R)
                    let var6 := mulmod(f_12, var5, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var6, r)
                }
                {
                    let f_12 := calldataload(0x0a24)
                    let a_8 := calldataload(0x0824)
                    let var0 := mulmod(a_8, 0x66f6f85d6f68a85ec10345351a23a3aaf07f38af8c952a7bceca70bd2af7ad5, R)
                    let a_7 := calldataload(0x07c4)
                    let f_2 := calldataload(0x0924)
                    let var1 := addmod(a_7, f_2, R)
                    let var2 := mulmod(var1, 0x2b9d4b4110c9ae997782e1509b1d0fdb20a7c02bbd8bea7305462b9f8125b1e8, R)
                    let var3 := addmod(var0, var2, R)
                    let f_3 := calldataload(0x08c4)
                    let var4 := addmod(var3, f_3, R)
                    let var5 := mulmod(var4, var4, R)
                    let var6 := mulmod(var5, var5, R)
                    let var7 := mulmod(var6, var4, R)
                    let a_6_next_1 := calldataload(0x07e4)
                    let var8 := mulmod(a_6_next_1, 0x13abec390ada7f4370819ab1c7846f210554569d9b29d1ea8dbebd0fa8c53e66, R)
                    let a_7_next_1 := calldataload(0x0804)
                    let var9 := mulmod(a_7_next_1, 0x1eb9e1dc19a33a624c9862a1d97d1510bd521ead5dfe0345aaf6185b1a1e60fe, R)
                    let var10 := addmod(var8, var9, R)
                    let var11 := sub(R, var10)
                    let var12 := addmod(var7, var11, R)
                    let var13 := mulmod(f_12, var12, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var13, r)
                }
                {
                    let f_12 := calldataload(0x0a24)
                    let a_8 := calldataload(0x0824)
                    let var0 := mulmod(a_8, 0xcc57cdbb08507d62bf67a4493cc262fb6c09d557013fff1f573f431221f8ff9, R)
                    let a_7 := calldataload(0x07c4)
                    let f_2 := calldataload(0x0924)
                    let var1 := addmod(a_7, f_2, R)
                    let var2 := mulmod(var1, 0x1274e649a32ed355a31a6ed69724e1adade857e86eb5c3a121bcd147943203c8, R)
                    let var3 := addmod(var0, var2, R)
                    let f_4 := calldataload(0x08e4)
                    let var4 := addmod(var3, f_4, R)
                    let a_6_next_1 := calldataload(0x07e4)
                    let var5 := mulmod(a_6_next_1, 0xfc1c9394db89bb2601abc49fdad4f038ce5169030a2ad69763f7875036bcb02, R)
                    let a_7_next_1 := calldataload(0x0804)
                    let var6 := mulmod(a_7_next_1, 0x16a9e98c493a902b9502054edc03e7b22b7eac34345961bc8abced6bd147c8be, R)
                    let var7 := addmod(var5, var6, R)
                    let var8 := sub(R, var7)
                    let var9 := addmod(var4, var8, R)
                    let var10 := mulmod(f_12, var9, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var10, r)
                }
                {
                    let f_13 := calldataload(0x0a44)
                    let var0 := 0x2
                    let var1 := sub(R, f_13)
                    let var2 := addmod(var0, var1, R)
                    let var3 := mulmod(f_13, var2, R)
                    let var4 := 0x3
                    let var5 := addmod(var4, var1, R)
                    let var6 := mulmod(var3, var5, R)
                    let a_6_prev_1 := calldataload(0x0864)
                    let a_6 := calldataload(0x07a4)
                    let var7 := addmod(a_6_prev_1, a_6, R)
                    let a_6_next_1 := calldataload(0x07e4)
                    let var8 := sub(R, a_6_next_1)
                    let var9 := addmod(var7, var8, R)
                    let var10 := mulmod(var6, var9, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var10, r)
                }
                {
                    let f_13 := calldataload(0x0a44)
                    let var0 := 0x2
                    let var1 := sub(R, f_13)
                    let var2 := addmod(var0, var1, R)
                    let var3 := mulmod(f_13, var2, R)
                    let var4 := 0x3
                    let var5 := addmod(var4, var1, R)
                    let var6 := mulmod(var3, var5, R)
                    let a_7_prev_1 := calldataload(0x0844)
                    let a_7_next_1 := calldataload(0x0804)
                    let var7 := sub(R, a_7_next_1)
                    let var8 := addmod(a_7_prev_1, var7, R)
                    let var9 := mulmod(var6, var8, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var9, r)
                }
                {
                    let f_14 := calldataload(0x0a64)
                    let var0 := 0x2
                    let var1 := sub(R, f_14)
                    let var2 := addmod(var0, var1, R)
                    let var3 := mulmod(f_14, var2, R)
                    let var4 := 0x3
                    let var5 := addmod(var4, var1, R)
                    let var6 := mulmod(var3, var5, R)
                    let var7 := 0x4
                    let var8 := addmod(var7, var1, R)
                    let var9 := mulmod(var6, var8, R)
                    let a_4 := calldataload(0x0764)
                    let a_0 := calldataload(0x06e4)
                    let a_2 := calldataload(0x0724)
                    let var10 := addmod(a_0, a_2, R)
                    let var11 := sub(R, var10)
                    let var12 := addmod(a_4, var11, R)
                    let var13 := mulmod(var9, var12, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var13, r)
                }
                {
                    let f_15 := calldataload(0x0a84)
                    let var0 := 0x2
                    let var1 := sub(R, f_15)
                    let var2 := addmod(var0, var1, R)
                    let var3 := mulmod(f_15, var2, R)
                    let var4 := 0x3
                    let var5 := addmod(var4, var1, R)
                    let var6 := mulmod(var3, var5, R)
                    let var7 := 0x4
                    let var8 := addmod(var7, var1, R)
                    let var9 := mulmod(var6, var8, R)
                    let a_5 := calldataload(0x0784)
                    let a_1 := calldataload(0x0704)
                    let a_3 := calldataload(0x0744)
                    let var10 := addmod(a_1, a_3, R)
                    let var11 := sub(R, var10)
                    let var12 := addmod(a_5, var11, R)
                    let var13 := mulmod(var9, var12, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var13, r)
                }
                {
                    let f_14 := calldataload(0x0a64)
                    let var0 := 0x1
                    let var1 := sub(R, f_14)
                    let var2 := addmod(var0, var1, R)
                    let var3 := mulmod(f_14, var2, R)
                    let var4 := 0x2
                    let var5 := addmod(var4, var1, R)
                    let var6 := mulmod(var3, var5, R)
                    let var7 := 0x4
                    let var8 := addmod(var7, var1, R)
                    let var9 := mulmod(var6, var8, R)
                    let a_4 := calldataload(0x0764)
                    let a_0 := calldataload(0x06e4)
                    let a_2 := calldataload(0x0724)
                    let var10 := mulmod(a_0, a_2, R)
                    let var11 := sub(R, var10)
                    let var12 := addmod(a_4, var11, R)
                    let var13 := mulmod(var9, var12, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var13, r)
                }
                {
                    let f_15 := calldataload(0x0a84)
                    let var0 := 0x1
                    let var1 := sub(R, f_15)
                    let var2 := addmod(var0, var1, R)
                    let var3 := mulmod(f_15, var2, R)
                    let var4 := 0x2
                    let var5 := addmod(var4, var1, R)
                    let var6 := mulmod(var3, var5, R)
                    let var7 := 0x4
                    let var8 := addmod(var7, var1, R)
                    let var9 := mulmod(var6, var8, R)
                    let a_5 := calldataload(0x0784)
                    let a_1 := calldataload(0x0704)
                    let a_3 := calldataload(0x0744)
                    let var10 := mulmod(a_1, a_3, R)
                    let var11 := sub(R, var10)
                    let var12 := addmod(a_5, var11, R)
                    let var13 := mulmod(var9, var12, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var13, r)
                }
                {
                    let f_14 := calldataload(0x0a64)
                    let var0 := 0x1
                    let var1 := sub(R, f_14)
                    let var2 := addmod(var0, var1, R)
                    let var3 := mulmod(f_14, var2, R)
                    let var4 := 0x3
                    let var5 := addmod(var4, var1, R)
                    let var6 := mulmod(var3, var5, R)
                    let var7 := 0x4
                    let var8 := addmod(var7, var1, R)
                    let var9 := mulmod(var6, var8, R)
                    let a_4 := calldataload(0x0764)
                    let a_0 := calldataload(0x06e4)
                    let a_2 := calldataload(0x0724)
                    let var10 := sub(R, a_2)
                    let var11 := addmod(a_0, var10, R)
                    let var12 := sub(R, var11)
                    let var13 := addmod(a_4, var12, R)
                    let var14 := mulmod(var9, var13, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var14, r)
                }
                {
                    let f_15 := calldataload(0x0a84)
                    let var0 := 0x1
                    let var1 := sub(R, f_15)
                    let var2 := addmod(var0, var1, R)
                    let var3 := mulmod(f_15, var2, R)
                    let var4 := 0x3
                    let var5 := addmod(var4, var1, R)
                    let var6 := mulmod(var3, var5, R)
                    let var7 := 0x4
                    let var8 := addmod(var7, var1, R)
                    let var9 := mulmod(var6, var8, R)
                    let a_5 := calldataload(0x0784)
                    let a_1 := calldataload(0x0704)
                    let a_3 := calldataload(0x0744)
                    let var10 := sub(R, a_3)
                    let var11 := addmod(a_1, var10, R)
                    let var12 := sub(R, var11)
                    let var13 := addmod(a_5, var12, R)
                    let var14 := mulmod(var9, var13, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var14, r)
                }
                {
                    let f_15 := calldataload(0x0a84)
                    let var0 := 0x1
                    let var1 := sub(R, f_15)
                    let var2 := addmod(var0, var1, R)
                    let var3 := mulmod(f_15, var2, R)
                    let var4 := 0x2
                    let var5 := addmod(var4, var1, R)
                    let var6 := mulmod(var3, var5, R)
                    let var7 := 0x3
                    let var8 := addmod(var7, var1, R)
                    let var9 := mulmod(var6, var8, R)
                    let a_4 := calldataload(0x0764)
                    let a_4_prev_1 := calldataload(0x0884)
                    let var10 := 0x0
                    let a_0 := calldataload(0x06e4)
                    let a_2 := calldataload(0x0724)
                    let var11 := mulmod(a_0, a_2, R)
                    let var12 := addmod(var10, var11, R)
                    let a_1 := calldataload(0x0704)
                    let a_3 := calldataload(0x0744)
                    let var13 := mulmod(a_1, a_3, R)
                    let var14 := addmod(var12, var13, R)
                    let var15 := addmod(a_4_prev_1, var14, R)
                    let var16 := sub(R, var15)
                    let var17 := addmod(a_4, var16, R)
                    let var18 := mulmod(var9, var17, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var18, r)
                }
                {
                    let f_14 := calldataload(0x0a64)
                    let var0 := 0x1
                    let var1 := sub(R, f_14)
                    let var2 := addmod(var0, var1, R)
                    let var3 := mulmod(f_14, var2, R)
                    let var4 := 0x2
                    let var5 := addmod(var4, var1, R)
                    let var6 := mulmod(var3, var5, R)
                    let var7 := 0x3
                    let var8 := addmod(var7, var1, R)
                    let var9 := mulmod(var6, var8, R)
                    let a_4 := calldataload(0x0764)
                    let var10 := 0x0
                    let a_0 := calldataload(0x06e4)
                    let a_2 := calldataload(0x0724)
                    let var11 := mulmod(a_0, a_2, R)
                    let var12 := addmod(var10, var11, R)
                    let a_1 := calldataload(0x0704)
                    let a_3 := calldataload(0x0744)
                    let var13 := mulmod(a_1, a_3, R)
                    let var14 := addmod(var12, var13, R)
                    let var15 := sub(R, var14)
                    let var16 := addmod(a_4, var15, R)
                    let var17 := mulmod(var9, var16, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var17, r)
                }
                {
                    let f_13 := calldataload(0x0a44)
                    let var0 := 0x1
                    let var1 := sub(R, f_13)
                    let var2 := addmod(var0, var1, R)
                    let var3 := mulmod(f_13, var2, R)
                    let var4 := 0x2
                    let var5 := addmod(var4, var1, R)
                    let var6 := mulmod(var3, var5, R)
                    let a_4 := calldataload(0x0764)
                    let a_2 := calldataload(0x0724)
                    let var7 := mulmod(var0, a_2, R)
                    let a_3 := calldataload(0x0744)
                    let var8 := mulmod(var7, a_3, R)
                    let var9 := sub(R, var8)
                    let var10 := addmod(a_4, var9, R)
                    let var11 := mulmod(var6, var10, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var11, r)
                }
                {
                    let f_13 := calldataload(0x0a44)
                    let var0 := 0x1
                    let var1 := sub(R, f_13)
                    let var2 := addmod(var0, var1, R)
                    let var3 := mulmod(f_13, var2, R)
                    let var4 := 0x3
                    let var5 := addmod(var4, var1, R)
                    let var6 := mulmod(var3, var5, R)
                    let a_4 := calldataload(0x0764)
                    let a_4_prev_1 := calldataload(0x0884)
                    let a_2 := calldataload(0x0724)
                    let var7 := mulmod(var0, a_2, R)
                    let a_3 := calldataload(0x0744)
                    let var8 := mulmod(var7, a_3, R)
                    let var9 := mulmod(a_4_prev_1, var8, R)
                    let var10 := sub(R, var9)
                    let var11 := addmod(a_4, var10, R)
                    let var12 := mulmod(var6, var11, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var12, r)
                }
                {
                    let f_16 := calldataload(0x0aa4)
                    let var0 := 0x1
                    let var1 := sub(R, f_16)
                    let var2 := addmod(var0, var1, R)
                    let var3 := mulmod(f_16, var2, R)
                    let a_4 := calldataload(0x0764)
                    let var4 := 0x0
                    let a_2 := calldataload(0x0724)
                    let var5 := addmod(var4, a_2, R)
                    let a_3 := calldataload(0x0744)
                    let var6 := addmod(var5, a_3, R)
                    let var7 := sub(R, var6)
                    let var8 := addmod(a_4, var7, R)
                    let var9 := mulmod(var3, var8, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var9, r)
                }
                {
                    let f_16 := calldataload(0x0aa4)
                    let var0 := 0x2
                    let var1 := sub(R, f_16)
                    let var2 := addmod(var0, var1, R)
                    let var3 := mulmod(f_16, var2, R)
                    let a_4 := calldataload(0x0764)
                    let a_4_prev_1 := calldataload(0x0884)
                    let var4 := 0x0
                    let a_2 := calldataload(0x0724)
                    let var5 := addmod(var4, a_2, R)
                    let a_3 := calldataload(0x0744)
                    let var6 := addmod(var5, a_3, R)
                    let var7 := addmod(a_4_prev_1, var6, R)
                    let var8 := sub(R, var7)
                    let var9 := addmod(a_4, var8, R)
                    let var10 := mulmod(var3, var9, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var10, r)
                }
                {
                    let f_7 := calldataload(0x0984)
                    let var0 := 0x0
                    let var1 := mulmod(f_7, var0, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var1, r)
                }
                {
                    let f_8 := calldataload(0x09a4)
                    let var0 := 0x0
                    let var1 := mulmod(f_8, var0, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var1, r)
                }
                {
                    let f_9 := calldataload(0x09c4)
                    let var0 := 0x0
                    let var1 := mulmod(f_9, var0, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var1, r)
                }
                {
                    let f_10 := calldataload(0x09e4)
                    let var0 := 0x0
                    let var1 := mulmod(f_10, var0, R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), var1, r)
                }
                {
                    let l_0 := mload(L_0_MPTR)
                    let eval := addmod(l_0, sub(R, mulmod(l_0, calldataload(0x0c64), R)), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let perm_z_last := calldataload(0x0d24)
                    let eval := mulmod(mload(L_LAST_MPTR), addmod(mulmod(perm_z_last, perm_z_last, R), sub(R, perm_z_last), R), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let eval := mulmod(mload(L_0_MPTR), addmod(calldataload(0x0cc4), sub(R, calldataload(0x0ca4)), R), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let eval := mulmod(mload(L_0_MPTR), addmod(calldataload(0x0d24), sub(R, calldataload(0x0d04)), R), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let gamma := mload(GAMMA_MPTR)
                    let beta := mload(BETA_MPTR)
                    let lhs := calldataload(0x0c84)
                    let rhs := calldataload(0x0c64)
                    lhs := mulmod(lhs, addmod(addmod(calldataload(0x06e4), mulmod(beta, calldataload(0x0ae4), R), R), gamma, R), R)
                    lhs := mulmod(lhs, addmod(addmod(calldataload(0x0704), mulmod(beta, calldataload(0x0b04), R), R), gamma, R), R)
                    lhs := mulmod(lhs, addmod(addmod(calldataload(0x0724), mulmod(beta, calldataload(0x0b24), R), R), gamma, R), R)
                    lhs := mulmod(lhs, addmod(addmod(calldataload(0x0744), mulmod(beta, calldataload(0x0b44), R), R), gamma, R), R)
                    mstore(0x00, mulmod(beta, mload(X_MPTR), R))
                    rhs := mulmod(rhs, addmod(addmod(calldataload(0x06e4), mload(0x00), R), gamma, R), R)
                    mstore(0x00, mulmod(mload(0x00), DELTA, R))
                    rhs := mulmod(rhs, addmod(addmod(calldataload(0x0704), mload(0x00), R), gamma, R), R)
                    mstore(0x00, mulmod(mload(0x00), DELTA, R))
                    rhs := mulmod(rhs, addmod(addmod(calldataload(0x0724), mload(0x00), R), gamma, R), R)
                    mstore(0x00, mulmod(mload(0x00), DELTA, R))
                    rhs := mulmod(rhs, addmod(addmod(calldataload(0x0744), mload(0x00), R), gamma, R), R)
                    mstore(0x00, mulmod(mload(0x00), DELTA, R))
                    let left_sub_right := addmod(lhs, sub(R, rhs), R)
                    let eval := addmod(left_sub_right, sub(R, mulmod(left_sub_right, addmod(mload(L_LAST_MPTR), mload(L_BLIND_MPTR), R), R)), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let gamma := mload(GAMMA_MPTR)
                    let beta := mload(BETA_MPTR)
                    let lhs := calldataload(0x0ce4)
                    let rhs := calldataload(0x0cc4)
                    lhs := mulmod(lhs, addmod(addmod(calldataload(0x0764), mulmod(beta, calldataload(0x0b64), R), R), gamma, R), R)
                    lhs := mulmod(lhs, addmod(addmod(calldataload(0x0784), mulmod(beta, calldataload(0x0b84), R), R), gamma, R), R)
                    lhs := mulmod(lhs, addmod(addmod(calldataload(0x08a4), mulmod(beta, calldataload(0x0ba4), R), R), gamma, R), R)
                    lhs := mulmod(lhs, addmod(addmod(calldataload(0x07a4), mulmod(beta, calldataload(0x0bc4), R), R), gamma, R), R)
                    rhs := mulmod(rhs, addmod(addmod(calldataload(0x0764), mload(0x00), R), gamma, R), R)
                    mstore(0x00, mulmod(mload(0x00), DELTA, R))
                    rhs := mulmod(rhs, addmod(addmod(calldataload(0x0784), mload(0x00), R), gamma, R), R)
                    mstore(0x00, mulmod(mload(0x00), DELTA, R))
                    rhs := mulmod(rhs, addmod(addmod(calldataload(0x08a4), mload(0x00), R), gamma, R), R)
                    mstore(0x00, mulmod(mload(0x00), DELTA, R))
                    rhs := mulmod(rhs, addmod(addmod(calldataload(0x07a4), mload(0x00), R), gamma, R), R)
                    mstore(0x00, mulmod(mload(0x00), DELTA, R))
                    let left_sub_right := addmod(lhs, sub(R, rhs), R)
                    let eval := addmod(left_sub_right, sub(R, mulmod(left_sub_right, addmod(mload(L_LAST_MPTR), mload(L_BLIND_MPTR), R), R)), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let gamma := mload(GAMMA_MPTR)
                    let beta := mload(BETA_MPTR)
                    let lhs := calldataload(0x0d44)
                    let rhs := calldataload(0x0d24)
                    lhs := mulmod(lhs, addmod(addmod(calldataload(0x07c4), mulmod(beta, calldataload(0x0be4), R), R), gamma, R), R)
                    lhs := mulmod(lhs, addmod(addmod(calldataload(0x08c4), mulmod(beta, calldataload(0x0c04), R), R), gamma, R), R)
                    lhs := mulmod(lhs, addmod(addmod(mload(INSTANCE_EVAL_MPTR), mulmod(beta, calldataload(0x0c24), R), R), gamma, R), R)
                    lhs := mulmod(lhs, addmod(addmod(calldataload(0x08e4), mulmod(beta, calldataload(0x0c44), R), R), gamma, R), R)
                    rhs := mulmod(rhs, addmod(addmod(calldataload(0x07c4), mload(0x00), R), gamma, R), R)
                    mstore(0x00, mulmod(mload(0x00), DELTA, R))
                    rhs := mulmod(rhs, addmod(addmod(calldataload(0x08c4), mload(0x00), R), gamma, R), R)
                    mstore(0x00, mulmod(mload(0x00), DELTA, R))
                    rhs := mulmod(rhs, addmod(addmod(mload(INSTANCE_EVAL_MPTR), mload(0x00), R), gamma, R), R)
                    mstore(0x00, mulmod(mload(0x00), DELTA, R))
                    rhs := mulmod(rhs, addmod(addmod(calldataload(0x08e4), mload(0x00), R), gamma, R), R)
                    let left_sub_right := addmod(lhs, sub(R, rhs), R)
                    let eval := addmod(left_sub_right, sub(R, mulmod(left_sub_right, addmod(mload(L_LAST_MPTR), mload(L_BLIND_MPTR), R), R)), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let l_0 := mload(L_0_MPTR)
                    let eval := mulmod(l_0, calldataload(0x0d64), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let l_last := mload(L_LAST_MPTR)
                    let eval := mulmod(l_last, calldataload(0x0d64), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let theta := mload(THETA_MPTR)
                    let beta := mload(BETA_MPTR)
                    let table
                    {
                        let f_5 := calldataload(0x0944)
                        table := f_5
                        table := addmod(table, beta, R)
                    }
                    let input_0
                    {
                        let f_7 := calldataload(0x0984)
                        let var0 := 0x1
                        let var1 := mulmod(f_7, var0, R)
                        let a_0 := calldataload(0x06e4)
                        let var2 := mulmod(var1, a_0, R)
                        let var3 := sub(R, var1)
                        let var4 := addmod(var0, var3, R)
                        let var5 := 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000000
                        let var6 := mulmod(var4, var5, R)
                        let var7 := addmod(var2, var6, R)
                        input_0 := var7
                        input_0 := addmod(input_0, beta, R)
                    }
                    let lhs
                    let rhs
                    rhs := table
                    {
                        let tmp := input_0
                        rhs := addmod(rhs, sub(R, mulmod(calldataload(0x0da4), tmp, R)), R)
                        lhs := mulmod(mulmod(table, tmp, R), addmod(calldataload(0x0d84), sub(R, calldataload(0x0d64)), R), R)
                    }
                    let eval := mulmod(addmod(1, sub(R, addmod(mload(L_BLIND_MPTR), mload(L_LAST_MPTR), R)), R), addmod(lhs, sub(R, rhs), R), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let l_0 := mload(L_0_MPTR)
                    let eval := mulmod(l_0, calldataload(0x0dc4), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let l_last := mload(L_LAST_MPTR)
                    let eval := mulmod(l_last, calldataload(0x0dc4), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let theta := mload(THETA_MPTR)
                    let beta := mload(BETA_MPTR)
                    let table
                    {
                        let f_5 := calldataload(0x0944)
                        table := f_5
                        table := addmod(table, beta, R)
                    }
                    let input_0
                    {
                        let f_8 := calldataload(0x09a4)
                        let var0 := 0x1
                        let var1 := mulmod(f_8, var0, R)
                        let a_1 := calldataload(0x0704)
                        let var2 := mulmod(var1, a_1, R)
                        let var3 := sub(R, var1)
                        let var4 := addmod(var0, var3, R)
                        let var5 := 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000000
                        let var6 := mulmod(var4, var5, R)
                        let var7 := addmod(var2, var6, R)
                        input_0 := var7
                        input_0 := addmod(input_0, beta, R)
                    }
                    let lhs
                    let rhs
                    rhs := table
                    {
                        let tmp := input_0
                        rhs := addmod(rhs, sub(R, mulmod(calldataload(0x0e04), tmp, R)), R)
                        lhs := mulmod(mulmod(table, tmp, R), addmod(calldataload(0x0de4), sub(R, calldataload(0x0dc4)), R), R)
                    }
                    let eval := mulmod(addmod(1, sub(R, addmod(mload(L_BLIND_MPTR), mload(L_LAST_MPTR), R)), R), addmod(lhs, sub(R, rhs), R), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let l_0 := mload(L_0_MPTR)
                    let eval := mulmod(l_0, calldataload(0x0e24), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let l_last := mload(L_LAST_MPTR)
                    let eval := mulmod(l_last, calldataload(0x0e24), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let theta := mload(THETA_MPTR)
                    let beta := mload(BETA_MPTR)
                    let table
                    {
                        let f_6 := calldataload(0x0964)
                        table := f_6
                        table := addmod(table, beta, R)
                    }
                    let input_0
                    {
                        let f_9 := calldataload(0x09c4)
                        let var0 := 0x1
                        let var1 := mulmod(f_9, var0, R)
                        let a_0 := calldataload(0x06e4)
                        let var2 := mulmod(var1, a_0, R)
                        let var3 := sub(R, var1)
                        let var4 := addmod(var0, var3, R)
                        let var5 := 0x0
                        let var6 := mulmod(var4, var5, R)
                        let var7 := addmod(var2, var6, R)
                        input_0 := var7
                        input_0 := addmod(input_0, beta, R)
                    }
                    let lhs
                    let rhs
                    rhs := table
                    {
                        let tmp := input_0
                        rhs := addmod(rhs, sub(R, mulmod(calldataload(0x0e64), tmp, R)), R)
                        lhs := mulmod(mulmod(table, tmp, R), addmod(calldataload(0x0e44), sub(R, calldataload(0x0e24)), R), R)
                    }
                    let eval := mulmod(addmod(1, sub(R, addmod(mload(L_BLIND_MPTR), mload(L_LAST_MPTR), R)), R), addmod(lhs, sub(R, rhs), R), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let l_0 := mload(L_0_MPTR)
                    let eval := mulmod(l_0, calldataload(0x0e84), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let l_last := mload(L_LAST_MPTR)
                    let eval := mulmod(l_last, calldataload(0x0e84), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }
                {
                    let theta := mload(THETA_MPTR)
                    let beta := mload(BETA_MPTR)
                    let table
                    {
                        let f_6 := calldataload(0x0964)
                        table := f_6
                        table := addmod(table, beta, R)
                    }
                    let input_0
                    {
                        let f_10 := calldataload(0x09e4)
                        let var0 := 0x1
                        let var1 := mulmod(f_10, var0, R)
                        let a_1 := calldataload(0x0704)
                        let var2 := mulmod(var1, a_1, R)
                        let var3 := sub(R, var1)
                        let var4 := addmod(var0, var3, R)
                        let var5 := 0x0
                        let var6 := mulmod(var4, var5, R)
                        let var7 := addmod(var2, var6, R)
                        input_0 := var7
                        input_0 := addmod(input_0, beta, R)
                    }
                    let lhs
                    let rhs
                    rhs := table
                    {
                        let tmp := input_0
                        rhs := addmod(rhs, sub(R, mulmod(calldataload(0x0ec4), tmp, R)), R)
                        lhs := mulmod(mulmod(table, tmp, R), addmod(calldataload(0x0ea4), sub(R, calldataload(0x0e84)), R), R)
                    }
                    let eval := mulmod(addmod(1, sub(R, addmod(mload(L_BLIND_MPTR), mload(L_LAST_MPTR), R)), R), addmod(lhs, sub(R, rhs), R), R)
                    quotient_eval_numer := addmod(mulmod(quotient_eval_numer, y, r), eval, r)
                }

                pop(y)

                let quotient_eval := mulmod(quotient_eval_numer, mload(X_N_MINUS_1_INV_MPTR), r)
                mstore(QUOTIENT_EVAL_MPTR, quotient_eval)
            }

            // Compute quotient commitment
            {
                mstore(0x00, calldataload(LAST_QUOTIENT_X_CPTR))
                mstore(0x20, calldataload(add(LAST_QUOTIENT_X_CPTR, 0x20)))
                let x_n := mload(X_N_MPTR)
                for
                    {
                        let cptr := sub(LAST_QUOTIENT_X_CPTR, 0x40)
                        let cptr_end := sub(FIRST_QUOTIENT_X_CPTR, 0x40)
                    }
                    lt(cptr_end, cptr)
                    {}
                {
                    success := ec_mul_acc(success, x_n)
                    success := ec_add_acc(success, calldataload(cptr), calldataload(add(cptr, 0x20)))
                    cptr := sub(cptr, 0x40)
                }
                mstore(QUOTIENT_X_MPTR, mload(0x00))
                mstore(QUOTIENT_Y_MPTR, mload(0x20))
            }

            // Compute pairing lhs and rhs
            {
                {
                    let x := mload(X_MPTR)
                    let omega := mload(OMEGA_MPTR)
                    let omega_inv := mload(OMEGA_INV_MPTR)
                    let x_pow_of_omega := mulmod(x, omega, R)
                    mstore(0x0420, x_pow_of_omega)
                    mstore(0x0400, x)
                    x_pow_of_omega := mulmod(x, omega_inv, R)
                    mstore(0x03e0, x_pow_of_omega)
                    x_pow_of_omega := mulmod(x_pow_of_omega, omega_inv, R)
                    x_pow_of_omega := mulmod(x_pow_of_omega, omega_inv, R)
                    x_pow_of_omega := mulmod(x_pow_of_omega, omega_inv, R)
                    x_pow_of_omega := mulmod(x_pow_of_omega, omega_inv, R)
                    x_pow_of_omega := mulmod(x_pow_of_omega, omega_inv, R)
                    mstore(0x03c0, x_pow_of_omega)
                }
                {
                    let mu := mload(MU_MPTR)
                    for
                        {
                            let mptr := 0x0440
                            let mptr_end := 0x04c0
                            let point_mptr := 0x03c0
                        }
                        lt(mptr, mptr_end)
                        {
                            mptr := add(mptr, 0x20)
                            point_mptr := add(point_mptr, 0x20)
                        }
                    {
                        mstore(mptr, addmod(mu, sub(R, mload(point_mptr)), R))
                    }
                    let s
                    s := mload(0x0480)
                    mstore(0x04c0, s)
                    let diff
                    diff := mload(0x0440)
                    diff := mulmod(diff, mload(0x0460), R)
                    diff := mulmod(diff, mload(0x04a0), R)
                    mstore(0x04e0, diff)
                    mstore(0x00, diff)
                    diff := mload(0x0440)
                    diff := mulmod(diff, mload(0x04a0), R)
                    mstore(0x0500, diff)
                    diff := mload(0x0440)
                    mstore(0x0520, diff)
                    diff := mload(0x0460)
                    mstore(0x0540, diff)
                    diff := mload(0x0440)
                    diff := mulmod(diff, mload(0x0460), R)
                    mstore(0x0560, diff)
                }
                {
                    let point_2 := mload(0x0400)
                    let coeff
                    coeff := 1
                    coeff := mulmod(coeff, mload(0x0480), R)
                    mstore(0x20, coeff)
                }
                {
                    let point_1 := mload(0x03e0)
                    let point_2 := mload(0x0400)
                    let coeff
                    coeff := addmod(point_1, sub(R, point_2), R)
                    coeff := mulmod(coeff, mload(0x0460), R)
                    mstore(0x40, coeff)
                    coeff := addmod(point_2, sub(R, point_1), R)
                    coeff := mulmod(coeff, mload(0x0480), R)
                    mstore(0x60, coeff)
                }
                {
                    let point_1 := mload(0x03e0)
                    let point_2 := mload(0x0400)
                    let point_3 := mload(0x0420)
                    let coeff
                    coeff := addmod(point_1, sub(R, point_2), R)
                    coeff := mulmod(coeff, addmod(point_1, sub(R, point_3), R), R)
                    coeff := mulmod(coeff, mload(0x0460), R)
                    mstore(0x80, coeff)
                    coeff := addmod(point_2, sub(R, point_1), R)
                    coeff := mulmod(coeff, addmod(point_2, sub(R, point_3), R), R)
                    coeff := mulmod(coeff, mload(0x0480), R)
                    mstore(0xa0, coeff)
                    coeff := addmod(point_3, sub(R, point_1), R)
                    coeff := mulmod(coeff, addmod(point_3, sub(R, point_2), R), R)
                    coeff := mulmod(coeff, mload(0x04a0), R)
                    mstore(0xc0, coeff)
                }
                {
                    let point_0 := mload(0x03c0)
                    let point_2 := mload(0x0400)
                    let point_3 := mload(0x0420)
                    let coeff
                    coeff := addmod(point_0, sub(R, point_2), R)
                    coeff := mulmod(coeff, addmod(point_0, sub(R, point_3), R), R)
                    coeff := mulmod(coeff, mload(0x0440), R)
                    mstore(0xe0, coeff)
                    coeff := addmod(point_2, sub(R, point_0), R)
                    coeff := mulmod(coeff, addmod(point_2, sub(R, point_3), R), R)
                    coeff := mulmod(coeff, mload(0x0480), R)
                    mstore(0x0100, coeff)
                    coeff := addmod(point_3, sub(R, point_0), R)
                    coeff := mulmod(coeff, addmod(point_3, sub(R, point_2), R), R)
                    coeff := mulmod(coeff, mload(0x04a0), R)
                    mstore(0x0120, coeff)
                }
                {
                    let point_2 := mload(0x0400)
                    let point_3 := mload(0x0420)
                    let coeff
                    coeff := addmod(point_2, sub(R, point_3), R)
                    coeff := mulmod(coeff, mload(0x0480), R)
                    mstore(0x0140, coeff)
                    coeff := addmod(point_3, sub(R, point_2), R)
                    coeff := mulmod(coeff, mload(0x04a0), R)
                    mstore(0x0160, coeff)
                }
                {
                    success := batch_invert(success, 0, 0x0180)
                    let diff_0_inv := mload(0x00)
                    mstore(0x04e0, diff_0_inv)
                    for
                        {
                            let mptr := 0x0500
                            let mptr_end := 0x0580
                        }
                        lt(mptr, mptr_end)
                        { mptr := add(mptr, 0x20) }
                    {
                        mstore(mptr, mulmod(mload(mptr), diff_0_inv, R))
                    }
                }
                {
                    let coeff := mload(0x20)
                    let zeta := mload(ZETA_MPTR)
                    let r_eval := 0
                    r_eval := addmod(r_eval, mulmod(coeff, calldataload(0x0ac4), R), R)
                    r_eval := mulmod(r_eval, zeta, R)
                    r_eval := addmod(r_eval, mulmod(coeff, mload(QUOTIENT_EVAL_MPTR), R), R)
                    for
                        {
                            let mptr := 0x0c44
                            let mptr_end := 0x0ac4
                        }
                        lt(mptr_end, mptr)
                        { mptr := sub(mptr, 0x20) }
                    {
                        r_eval := addmod(mulmod(r_eval, zeta, R), mulmod(coeff, calldataload(mptr), R), R)
                    }
                    for
                        {
                            let mptr := 0x0aa4
                            let mptr_end := 0x0884
                        }
                        lt(mptr_end, mptr)
                        { mptr := sub(mptr, 0x20) }
                    {
                        r_eval := addmod(mulmod(r_eval, zeta, R), mulmod(coeff, calldataload(mptr), R), R)
                    }
                    r_eval := mulmod(r_eval, zeta, R)
                    r_eval := addmod(r_eval, mulmod(coeff, calldataload(0x0ec4), R), R)
                    r_eval := mulmod(r_eval, zeta, R)
                    r_eval := addmod(r_eval, mulmod(coeff, calldataload(0x0e64), R), R)
                    r_eval := mulmod(r_eval, zeta, R)
                    r_eval := addmod(r_eval, mulmod(coeff, calldataload(0x0e04), R), R)
                    r_eval := mulmod(r_eval, zeta, R)
                    r_eval := addmod(r_eval, mulmod(coeff, calldataload(0x0da4), R), R)
                    r_eval := mulmod(r_eval, zeta, R)
                    r_eval := addmod(r_eval, mulmod(coeff, calldataload(0x0824), R), R)
                    r_eval := mulmod(r_eval, zeta, R)
                    r_eval := addmod(r_eval, mulmod(coeff, calldataload(0x0784), R), R)
                    for
                        {
                            let mptr := 0x0744
                            let mptr_end := 0x06c4
                        }
                        lt(mptr_end, mptr)
                        { mptr := sub(mptr, 0x20) }
                    {
                        r_eval := addmod(mulmod(r_eval, zeta, R), mulmod(coeff, calldataload(mptr), R), R)
                    }
                    mstore(0x0580, r_eval)
                }
                {
                    let zeta := mload(ZETA_MPTR)
                    let r_eval := 0
                    r_eval := addmod(r_eval, mulmod(mload(0x40), calldataload(0x0884), R), R)
                    r_eval := addmod(r_eval, mulmod(mload(0x60), calldataload(0x0764), R), R)
                    r_eval := mulmod(r_eval, mload(0x0500), R)
                    mstore(0x05a0, r_eval)
                }
                {
                    let zeta := mload(ZETA_MPTR)
                    let r_eval := 0
                    r_eval := addmod(r_eval, mulmod(mload(0x80), calldataload(0x0844), R), R)
                    r_eval := addmod(r_eval, mulmod(mload(0xa0), calldataload(0x07c4), R), R)
                    r_eval := addmod(r_eval, mulmod(mload(0xc0), calldataload(0x0804), R), R)
                    r_eval := mulmod(r_eval, zeta, R)
                    r_eval := addmod(r_eval, mulmod(mload(0x80), calldataload(0x0864), R), R)
                    r_eval := addmod(r_eval, mulmod(mload(0xa0), calldataload(0x07a4), R), R)
                    r_eval := addmod(r_eval, mulmod(mload(0xc0), calldataload(0x07e4), R), R)
                    r_eval := mulmod(r_eval, mload(0x0520), R)
                    mstore(0x05c0, r_eval)
                }
                {
                    let zeta := mload(ZETA_MPTR)
                    let r_eval := 0
                    r_eval := addmod(r_eval, mulmod(mload(0xe0), calldataload(0x0d04), R), R)
                    r_eval := addmod(r_eval, mulmod(mload(0x0100), calldataload(0x0cc4), R), R)
                    r_eval := addmod(r_eval, mulmod(mload(0x0120), calldataload(0x0ce4), R), R)
                    r_eval := mulmod(r_eval, zeta, R)
                    r_eval := addmod(r_eval, mulmod(mload(0xe0), calldataload(0x0ca4), R), R)
                    r_eval := addmod(r_eval, mulmod(mload(0x0100), calldataload(0x0c64), R), R)
                    r_eval := addmod(r_eval, mulmod(mload(0x0120), calldataload(0x0c84), R), R)
                    r_eval := mulmod(r_eval, mload(0x0540), R)
                    mstore(0x05e0, r_eval)
                }
                {
                    let zeta := mload(ZETA_MPTR)
                    let r_eval := 0
                    r_eval := addmod(r_eval, mulmod(mload(0x0140), calldataload(0x0e84), R), R)
                    r_eval := addmod(r_eval, mulmod(mload(0x0160), calldataload(0x0ea4), R), R)
                    r_eval := mulmod(r_eval, zeta, R)
                    r_eval := addmod(r_eval, mulmod(mload(0x0140), calldataload(0x0e24), R), R)
                    r_eval := addmod(r_eval, mulmod(mload(0x0160), calldataload(0x0e44), R), R)
                    r_eval := mulmod(r_eval, zeta, R)
                    r_eval := addmod(r_eval, mulmod(mload(0x0140), calldataload(0x0dc4), R), R)
                    r_eval := addmod(r_eval, mulmod(mload(0x0160), calldataload(0x0de4), R), R)
                    r_eval := mulmod(r_eval, zeta, R)
                    r_eval := addmod(r_eval, mulmod(mload(0x0140), calldataload(0x0d64), R), R)
                    r_eval := addmod(r_eval, mulmod(mload(0x0160), calldataload(0x0d84), R), R)
                    r_eval := mulmod(r_eval, zeta, R)
                    r_eval := addmod(r_eval, mulmod(mload(0x0140), calldataload(0x0d24), R), R)
                    r_eval := addmod(r_eval, mulmod(mload(0x0160), calldataload(0x0d44), R), R)
                    r_eval := mulmod(r_eval, mload(0x0560), R)
                    mstore(0x0600, r_eval)
                }
                {
                    let sum := mload(0x20)
                    mstore(0x0620, sum)
                }
                {
                    let sum := mload(0x40)
                    sum := addmod(sum, mload(0x60), R)
                    mstore(0x0640, sum)
                }
                {
                    let sum := mload(0x80)
                    sum := addmod(sum, mload(0xa0), R)
                    sum := addmod(sum, mload(0xc0), R)
                    mstore(0x0660, sum)
                }
                {
                    let sum := mload(0xe0)
                    sum := addmod(sum, mload(0x0100), R)
                    sum := addmod(sum, mload(0x0120), R)
                    mstore(0x0680, sum)
                }
                {
                    let sum := mload(0x0140)
                    sum := addmod(sum, mload(0x0160), R)
                    mstore(0x06a0, sum)
                }
                {
                    for
                        {
                            let mptr := 0x00
                            let mptr_end := 0xa0
                            let sum_mptr := 0x0620
                        }
                        lt(mptr, mptr_end)
                        {
                            mptr := add(mptr, 0x20)
                            sum_mptr := add(sum_mptr, 0x20)
                        }
                    {
                        mstore(mptr, mload(sum_mptr))
                    }
                    success := batch_invert(success, 0, 0xa0)
                    let r_eval := mulmod(mload(0x80), mload(0x0600), R)
                    for
                        {
                            let sum_inv_mptr := 0x60
                            let sum_inv_mptr_end := 0xa0
                            let r_eval_mptr := 0x05e0
                        }
                        lt(sum_inv_mptr, sum_inv_mptr_end)
                        {
                            sum_inv_mptr := sub(sum_inv_mptr, 0x20)
                            r_eval_mptr := sub(r_eval_mptr, 0x20)
                        }
                    {
                        r_eval := mulmod(r_eval, mload(NU_MPTR), R)
                        r_eval := addmod(r_eval, mulmod(mload(sum_inv_mptr), mload(r_eval_mptr), R), R)
                    }
                    mstore(R_EVAL_MPTR, r_eval)
                }
                {
                    let nu := mload(NU_MPTR)
                    mstore(0x00, calldataload(0x0564))
                    mstore(0x20, calldataload(0x0584))
                    success := ec_mul_acc(success, mload(ZETA_MPTR))
                    success := ec_add_acc(success, mload(QUOTIENT_X_MPTR), mload(QUOTIENT_Y_MPTR))
                    for
                        {
                            let mptr := 0x11c0
                            let mptr_end := 0x0bc0
                        }
                        lt(mptr_end, mptr)
                        { mptr := sub(mptr, 0x40) }
                    {
                        success := ec_mul_acc(success, mload(ZETA_MPTR))
                        success := ec_add_acc(success, mload(mptr), mload(add(mptr, 0x20)))
                    }
                    success := ec_mul_acc(success, mload(ZETA_MPTR))
                    success := ec_add_acc(success, mload(0x0b40), mload(0x0b60))
                    success := ec_mul_acc(success, mload(ZETA_MPTR))
                    success := ec_add_acc(success, mload(0x0b00), mload(0x0b20))
                    success := ec_mul_acc(success, mload(ZETA_MPTR))
                    success := ec_add_acc(success, mload(0x0bc0), mload(0x0be0))
                    success := ec_mul_acc(success, mload(ZETA_MPTR))
                    success := ec_add_acc(success, mload(0x0b80), mload(0x0ba0))
                    success := ec_mul_acc(success, mload(ZETA_MPTR))
                    success := ec_add_acc(success, mload(0x0ac0), mload(0x0ae0))
                    for
                        {
                            let mptr := 0x0364
                            let mptr_end := 0x0224
                        }
                        lt(mptr_end, mptr)
                        { mptr := sub(mptr, 0x40) }
                    {
                        success := ec_mul_acc(success, mload(ZETA_MPTR))
                        success := ec_add_acc(success, calldataload(mptr), calldataload(add(mptr, 0x20)))
                    }
                    success := ec_mul_acc(success, mload(ZETA_MPTR))
                    success := ec_add_acc(success, calldataload(0x01a4), calldataload(0x01c4))
                    for
                        {
                            let mptr := 0x0124
                            let mptr_end := 0x24
                        }
                        lt(mptr_end, mptr)
                        { mptr := sub(mptr, 0x40) }
                    {
                        success := ec_mul_acc(success, mload(ZETA_MPTR))
                        success := ec_add_acc(success, calldataload(mptr), calldataload(add(mptr, 0x20)))
                    }
                    mstore(0x80, calldataload(0x0164))
                    mstore(0xa0, calldataload(0x0184))
                    success := ec_mul_tmp(success, mulmod(nu, mload(0x0500), R))
                    success := ec_add_acc(success, mload(0x80), mload(0xa0))
                    nu := mulmod(nu, mload(NU_MPTR), R)
                    mstore(0x80, calldataload(0x0224))
                    mstore(0xa0, calldataload(0x0244))
                    success := ec_mul_tmp(success, mload(ZETA_MPTR))
                    success := ec_add_tmp(success, calldataload(0x01e4), calldataload(0x0204))
                    success := ec_mul_tmp(success, mulmod(nu, mload(0x0520), R))
                    success := ec_add_acc(success, mload(0x80), mload(0xa0))
                    nu := mulmod(nu, mload(NU_MPTR), R)
                    mstore(0x80, calldataload(0x03e4))
                    mstore(0xa0, calldataload(0x0404))
                    success := ec_mul_tmp(success, mload(ZETA_MPTR))
                    success := ec_add_tmp(success, calldataload(0x03a4), calldataload(0x03c4))
                    success := ec_mul_tmp(success, mulmod(nu, mload(0x0540), R))
                    success := ec_add_acc(success, mload(0x80), mload(0xa0))
                    nu := mulmod(nu, mload(NU_MPTR), R)
                    mstore(0x80, calldataload(0x0524))
                    mstore(0xa0, calldataload(0x0544))
                    for
                        {
                            let mptr := 0x04e4
                            let mptr_end := 0x03e4
                        }
                        lt(mptr_end, mptr)
                        { mptr := sub(mptr, 0x40) }
                    {
                        success := ec_mul_tmp(success, mload(ZETA_MPTR))
                        success := ec_add_tmp(success, calldataload(mptr), calldataload(add(mptr, 0x20)))
                    }
                    success := ec_mul_tmp(success, mulmod(nu, mload(0x0560), R))
                    success := ec_add_acc(success, mload(0x80), mload(0xa0))
                    mstore(0x80, mload(G1_X_MPTR))
                    mstore(0xa0, mload(G1_Y_MPTR))
                    success := ec_mul_tmp(success, sub(R, mload(R_EVAL_MPTR)))
                    success := ec_add_acc(success, mload(0x80), mload(0xa0))
                    mstore(0x80, calldataload(0x0ee4))
                    mstore(0xa0, calldataload(0x0f04))
                    success := ec_mul_tmp(success, sub(R, mload(0x04c0)))
                    success := ec_add_acc(success, mload(0x80), mload(0xa0))
                    mstore(0x80, calldataload(0x0f24))
                    mstore(0xa0, calldataload(0x0f44))
                    success := ec_mul_tmp(success, mload(MU_MPTR))
                    success := ec_add_acc(success, mload(0x80), mload(0xa0))
                    mstore(PAIRING_LHS_X_MPTR, mload(0x00))
                    mstore(PAIRING_LHS_Y_MPTR, mload(0x20))
                    mstore(PAIRING_RHS_X_MPTR, calldataload(0x0f24))
                    mstore(PAIRING_RHS_Y_MPTR, calldataload(0x0f44))
                }
            }

            // Random linear combine with accumulator
            if mload(HAS_ACCUMULATOR_MPTR) {
                mstore(0x00, mload(ACC_LHS_X_MPTR))
                mstore(0x20, mload(ACC_LHS_Y_MPTR))
                mstore(0x40, mload(ACC_RHS_X_MPTR))
                mstore(0x60, mload(ACC_RHS_Y_MPTR))
                mstore(0x80, mload(PAIRING_LHS_X_MPTR))
                mstore(0xa0, mload(PAIRING_LHS_Y_MPTR))
                mstore(0xc0, mload(PAIRING_RHS_X_MPTR))
                mstore(0xe0, mload(PAIRING_RHS_Y_MPTR))
                let challenge := mod(keccak256(0x00, 0x100), r)

                // [pairing_lhs] += challenge * [acc_lhs]
                success := ec_mul_acc(success, challenge)
                success := ec_add_acc(success, mload(PAIRING_LHS_X_MPTR), mload(PAIRING_LHS_Y_MPTR))
                mstore(PAIRING_LHS_X_MPTR, mload(0x00))
                mstore(PAIRING_LHS_Y_MPTR, mload(0x20))

                // [pairing_rhs] += challenge * [acc_rhs]
                mstore(0x00, mload(ACC_RHS_X_MPTR))
                mstore(0x20, mload(ACC_RHS_Y_MPTR))
                success := ec_mul_acc(success, challenge)
                success := ec_add_acc(success, mload(PAIRING_RHS_X_MPTR), mload(PAIRING_RHS_Y_MPTR))
                mstore(PAIRING_RHS_X_MPTR, mload(0x00))
                mstore(PAIRING_RHS_Y_MPTR, mload(0x20))
            }

            // Perform pairing
            success := ec_pairing(
                success,
                mload(PAIRING_LHS_X_MPTR),
                mload(PAIRING_LHS_Y_MPTR),
                mload(PAIRING_RHS_X_MPTR),
                mload(PAIRING_RHS_Y_MPTR)
            )

            // Revert if anything fails
            if iszero(success) {
                revert(0x00, 0x00)
            }

            // Return 1 as result if everything succeeds
            mstore(0x00, 1)
            return(0x00, 0x20)
        }
    }
}