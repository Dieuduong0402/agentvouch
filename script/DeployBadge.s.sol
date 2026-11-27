// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import "forge-std/Script.sol";
import "../src/VouchBadge.sol";

contract DeployBadge is Script {
    function run() external returns (VouchBadge b) {
        vm.broadcast();
        b = new VouchBadge(
            0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F, // SPACE ID HandleRegistry
            0x93271C060aC7f3432921Ae6225027aa5B2538E99 // AgentVouch (deployed 26/11)
        );
    }
}
