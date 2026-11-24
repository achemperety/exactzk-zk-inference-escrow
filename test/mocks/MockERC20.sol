// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Plain ERC-20 with open minting, for the job contract of ERC-8183, which pulls its budget with
/// `transferFrom`. Unit tests only.
contract MockERC20 is ERC20 {
    constructor() ERC20("Test USD", "TUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }
}
