// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import "forge-std/Script.sol";
import "../src/AgentVouch.sol";

contract Deploy is Script {
    function run() external returns (AgentVouch v) {
        vm.broadcast();
        v = new AgentVouch(0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F);
    }
}
