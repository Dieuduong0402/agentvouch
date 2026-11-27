// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AgentVouch } from "../src/AgentVouch.sol";

interface IHandleRegistryFork {
    function balanceOf(address owner) external view returns (uint256);
    function handleOf(address owner) external view returns (string memory);
    function ownerOfHandle(string calldata handle) external view returns (address);
}

/// @notice Fork tests against the REAL SPACE ID HandleRegistry on BSC mainnet.
/// Run: forge test --match-contract AgentVouchForkTest --fork-url <BSC_RPC>
contract AgentVouchForkTest is Test {
    address constant REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    // The user's six Binance Agentic Wallets (public addresses).
    address[6] wallets = [
        0xC6C0aFB585Dd195e0AA1DbA01Bb24D797b9897F6, // main
        0x2f105F447DD48082b934F99bEbD6523dbCBba282, // wallet 2
        0xfB73A65eeda90feCc6B32259D80Be8298c0bFcBA, // wallet 3
        0x5E19df9188863e22c70986883105f2e5f3941ece, // wallet 4
        0x1B7FdAaDb4B8888d5F77aE0a6d09992060fc38D5, // wallet 5
        0xF249Ba2061AbBC2535937d5328F34f3Ef1a2c1d0 // wallet 6
    ];

    IHandleRegistryFork registry;
    AgentVouch vouch;

    address issuer;
    address subject;
    string issuerHandle;
    string subjectHandle;

    function setUp() public {
        // Without a fork the real registry has no code at this address: skip.
        if (REGISTRY.code.length == 0) {
            vm.skip(true);
        }
        registry = IHandleRegistryFork(REGISTRY);
        vouch = new AgentVouch(REGISTRY);
        // Discover two real Agent ID holders among the house wallets.
        for (uint256 i = 0; i < wallets.length; i++) {
            if (registry.balanceOf(wallets[i]) > 0) {
                string memory h = registry.handleOf(wallets[i]);
                if (bytes(h).length > 0 && issuer == address(0)) {
                    issuer = wallets[i];
                    issuerHandle = h;
                } else if (bytes(h).length > 0 && subject == address(0)) {
                    subject = wallets[i];
                    subjectHandle = h;
                }
            }
        }
    }

    function testFork_RealHoldersDiscovered() public view {
        assertTrue(issuer != address(0), "no issuer holder found among house wallets");
        assertTrue(subject != address(0), "no subject holder found among house wallets");
        assertEq(registry.ownerOfHandle(issuerHandle), issuer);
        assertEq(registry.ownerOfHandle(subjectHandle), subject);
        // A random EOA holds no Agent ID.
        assertEq(registry.balanceOf(address(0xBEEF)), 0);
    }

    function testFork_AttestBetweenRealAgents() public {
        bytes32 ev = keccak256("https://example.com/evidence/fork-test");
        vm.prank(issuer);
        vouch.attest(subjectHandle, 0, ev);
        assertTrue(vouch.hasActiveAttestation(issuer, subject, 0));
        assertEq(vouch.receivedCountOfHandle(subjectHandle, 0), 1);
        assertEq(vouch.givenCountOf(issuer), 1);
    }

    function testFork_NonHolderCannotAttest() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(AgentVouch.NotAgentIdHolder.selector);
        vouch.attest(subjectHandle, 0, bytes32(uint256(1)));
    }

    function testFork_GhostHandleReverts() public {
        vm.prank(issuer);
        vm.expectRevert();
        vouch.attest("zzz-no-such-handle-zzz", 0, bytes32(uint256(1)));
    }

    function testFork_UpdateAndRevoke() public {
        vm.startPrank(issuer);
        vouch.attest(subjectHandle, 1, keccak256("v1"));
        vouch.attest(subjectHandle, 1, keccak256("v2")); // update path
        assertTrue(vouch.hasActiveAttestation(issuer, subject, 1));
        assertEq(vouch.receivedCountOfHandle(subjectHandle, 1), 1);
        vouch.revokeAttestation(subjectHandle, 1);
        vm.stopPrank();
        assertFalse(vouch.hasActiveAttestation(issuer, subject, 1));
        assertEq(vouch.receivedCountOfHandle(subjectHandle, 1), 0);
    }
}
