// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import "forge-std/Script.sol";
import "../src/AgentVouch.sol";
import "../test/mocks/MockHandleRegistry.sol";

/// @notice D6 test deploy: MockHandleRegistry + AgentVouch on a plain anvil.
/// Registers tungquan42 -> anvil account 0, dieuduong369 -> anvil account 1,
/// mirroring the real seeding-matrix row 1 (tungquan42 -> dieuduong369, cat 1).
contract DeployMock is Script {
    function run() external returns (MockHandleRegistry reg, AgentVouch v) {
        // NOTE: vm.broadcast() alone broadcasts ONLY the next call — use
        // start/stopBroadcast so all 4 calls below land on-chain.
        vm.startBroadcast();
        reg = new MockHandleRegistry();
        reg.registerHandle(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, "tungquan42");
        reg.registerHandle(0x70997970C51812dc3A010C7d01b50e0d17dc79C8, "dieuduong369");
        v = new AgentVouch(address(reg));
        vm.stopBroadcast();
    }
}
