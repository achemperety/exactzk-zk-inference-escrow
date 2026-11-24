// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Deploys the third-party reference contracts the way their own sources do (README.md in this
// folder). This file sits under test/external/, so its OpenZeppelin imports resolve to v5.4.0,
// like the reference code's.
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgenticCommerce} from "./erc8183/AgenticCommerce.sol";
import {HardhatMinimalUUPS} from "lib/erc-8004-contracts/contracts/HardhatMinimalUUPS.sol";
import {IdentityRegistryUpgradeable} from "lib/erc-8004-contracts/contracts/IdentityRegistryUpgradeable.sol";
import {ValidationRegistryUpgradeable} from "lib/erc-8004-contracts/contracts/ValidationRegistryUpgradeable.sol";

library ReferenceDeploy {
    /// The ERC-8183 reference job contract behind a UUPS proxy, initialised with `token` as its
    /// payment token. The calling contract holds both admin roles.
    function agenticCommerce(address token, address treasury) internal returns (AgenticCommerce) {
        AgenticCommerce impl = new AgenticCommerce();
        return AgenticCommerce(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(AgenticCommerce.initialize, (token, treasury))))
        );
    }

    /// The ERC-8004 Identity and Validation registries, deployed as the repository's own tests do
    /// (test/core.ts at the pinned commit): a proxy to `HardhatMinimalUUPS`, which makes the caller
    /// the owner, then an upgrade to the real implementation with its initialiser.
    function erc8004()
        internal
        returns (IdentityRegistryUpgradeable identity, ValidationRegistryUpgradeable validation)
    {
        identity = IdentityRegistryUpgradeable(_minimalProxy(address(0)));
        HardhatMinimalUUPS(address(identity))
            .upgradeToAndCall(
                address(new IdentityRegistryUpgradeable()), abi.encodeCall(IdentityRegistryUpgradeable.initialize, ())
            );

        validation = ValidationRegistryUpgradeable(_minimalProxy(address(identity)));
        HardhatMinimalUUPS(address(validation))
            .upgradeToAndCall(
                address(new ValidationRegistryUpgradeable()),
                abi.encodeCall(ValidationRegistryUpgradeable.initialize, (address(identity)))
            );
    }

    function _minimalProxy(address identityRegistry) private returns (address) {
        HardhatMinimalUUPS minimal = new HardhatMinimalUUPS();
        return
            address(
                new ERC1967Proxy(address(minimal), abi.encodeCall(HardhatMinimalUUPS.initialize, (identityRegistry)))
            );
    }
}
