// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import "forge-std/Script.sol";
import "../src/AgentVouch.sol";
import "../test/mocks/MockHandleRegistry.sol";

/// @notice D7 test deploy: MockHandleRegistry + AgentVouch on a plain anvil.
/// Registers all 6 founding handles to anvil accounts 0-5, mirroring the
/// real seeding matrix (DESIGN.md §5.1/§5.3).
contract DeployMock7 is Script {
    function run() external returns (MockHandleRegistry reg, AgentVouch v) {
        vm.startBroadcast();
        reg = new MockHandleRegistry();
        reg.registerHandle(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, "tungquan42");
        reg.registerHandle(0x70997970C51812dc3A010C7d01b50e0d17dc79C8, "dieuduong369");
        reg.registerHandle(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC, "duyenvu75");
        reg.registerHandle(0x90F79bf6EB2c4f870365E785982E1f101E93b906, "dieuxuan50");
        reg.registerHandle(0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65, "nice969");
        reg.registerHandle(0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc, "tetternice");
        v = new AgentVouch(address(reg));
        vm.stopBroadcast();
    }
}
