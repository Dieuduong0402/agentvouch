// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { AgentVouch } from "../src/AgentVouch.sol";
import { VouchBadge } from "../src/VouchBadge.sol";
import { MockHandleRegistry } from "./mocks/MockHandleRegistry.sol";

/// @notice Unit tests for VouchBadge against MockHandleRegistry + the real
///      AgentVouch contract (spec vouchbadge-spec-2026-11-26).
contract VouchBadgeTest is Test {
    uint8 internal constant DELIVERED_WORK = 0;
    uint8 internal constant ACCURATE_ALPHA = 1;
    uint8 internal constant PAID_ON_TIME = 2;
    uint8 internal constant GOOD_COUNTERPARTY = 3;
    uint8 internal constant HELPFUL_GUIDE = 4;

    event BadgeMinted(address indexed minter, uint256 indexed tokenId, string handle);

    MockHandleRegistry internal registry;
    AgentVouch internal vouch;
    VouchBadge internal badge;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");
    address internal frank = makeAddr("frank");
    address internal stranger = makeAddr("stranger"); // never a holder

    function setUp() public {
        registry = new MockHandleRegistry();
        vouch = new AgentVouch(address(registry));
        badge = new VouchBadge(address(registry), address(vouch));
        registry.registerHandle(alice, "aliceagent");
        registry.registerHandle(bob, "bobagent");
        registry.registerHandle(carol, "carolagent");
        registry.registerHandle(dave, "daveagent");
        registry.registerHandle(erin, "erinagent");
        registry.registerHandle(frank, "frankagent");
    }

    // ---------------------------------------------------------------
    // Mint
    // ---------------------------------------------------------------

    function test_Mint_Holder_Succeeds() public {
        vm.expectEmit(true, true, false, true, address(badge));
        emit BadgeMinted(alice, 1, "aliceagent");
        vm.prank(alice);
        badge.mint();
        assertEq(badge.ownerOf(1), alice);
        assertEq(badge.balanceOf(alice), 1);
        assertTrue(badge.hasBadge(alice));
        assertEq(badge.totalMinted(), 1);
    }

    function test_Mint_NonHolder_Reverts() public {
        vm.prank(stranger);
        vm.expectRevert(VouchBadge.NotAgentIdHolder.selector);
        badge.mint();
    }

    function test_Mint_Twice_Reverts() public {
        vm.prank(alice);
        badge.mint();
        vm.prank(alice);
        vm.expectRevert(VouchBadge.AlreadyMinted.selector);
        badge.mint();
    }

    function test_Mint_GasIsLow() public {
        vm.prank(alice);
        uint256 before = gasleft();
        badge.mint();
        uint256 used = before - gasleft();
        emit log_named_uint("mint gas used", used);
        assertLt(used, 200_000); // cold mint must stay well under any heavy threshold
    }

    // ---------------------------------------------------------------
    // Soulbound
    // ---------------------------------------------------------------

    function test_Transfer_Reverts() public {
        vm.prank(alice);
        badge.mint();
        vm.prank(alice);
        vm.expectRevert(VouchBadge.Soulbound.selector);
        badge.transferFrom(alice, bob, 1);
    }

    function test_SafeTransfer_Reverts() public {
        vm.prank(alice);
        badge.mint();
        vm.prank(alice);
        vm.expectRevert(VouchBadge.Soulbound.selector);
        badge.safeTransferFrom(alice, bob, 1);
    }

    function test_Approve_Reverts() public {
        vm.prank(alice);
        badge.mint();
        vm.prank(alice);
        vm.expectRevert(VouchBadge.Soulbound.selector);
        badge.approve(bob, 1);
    }

    function test_SetApprovalForAll_Reverts() public {
        vm.prank(alice);
        badge.mint();
        vm.prank(alice);
        vm.expectRevert(VouchBadge.Soulbound.selector);
        badge.setApprovalForAll(bob, true);
    }

    // ---------------------------------------------------------------
    // Tiers
    // ---------------------------------------------------------------

    function test_Tier_FreshHolder_IsZero() public view {
        assertEq(badge.badgeTier(alice), 0);
        assertEq(badge.badgeTier(stranger), 0);
    }

    function test_Tier_One_GivenAttestation() public {
        vm.prank(alice);
        vouch.attest("bobagent", DELIVERED_WORK, bytes32(0));
        assertEq(badge.badgeTier(alice), 1); // given >= 1
        assertEq(badge.badgeTier(bob), 2); // received >= 1
    }

    function test_Tier_Three_ReceivedFive() public {
        // carol receives 5 attestations, one per issuer, same category.
        address[5] memory issuers = [alice, bob, dave, erin, frank];
        for (uint256 i = 0; i < issuers.length; i++) {
            vm.prank(issuers[i]);
            vouch.attest("carolagent", DELIVERED_WORK, bytes32(0));
        }
        assertEq(badge.badgeTier(carol), 3);
    }

    function test_Tier_Four_ReceivedTen_AndGivenThree() public {
        // dave receives 10: alice x5 categories + bob x5 categories.
        for (uint8 c = 0; c < 5; c++) {
            vm.prank(alice);
            vouch.attest("daveagent", c, bytes32(0));
            vm.prank(bob);
            vouch.attest("daveagent", c, bytes32(0));
        }
        // dave gives 3: to alice, bob, carol.
        vm.prank(dave);
        vouch.attest("aliceagent", DELIVERED_WORK, bytes32(0));
        vm.prank(dave);
        vouch.attest("bobagent", DELIVERED_WORK, bytes32(0));
        vm.prank(dave);
        vouch.attest("carolagent", DELIVERED_WORK, bytes32(0));
        assertEq(badge.badgeTier(dave), 4);
    }

    function test_Tier_Four_NeedsGivenThree() public {
        // dave receives 10 but gives only 2 -> tier 3, not 4.
        for (uint8 c = 0; c < 5; c++) {
            vm.prank(alice);
            vouch.attest("daveagent", c, bytes32(0));
            vm.prank(bob);
            vouch.attest("daveagent", c, bytes32(0));
        }
        vm.prank(dave);
        vouch.attest("aliceagent", DELIVERED_WORK, bytes32(0));
        vm.prank(dave);
        vouch.attest("bobagent", DELIVERED_WORK, bytes32(0));
        assertEq(badge.badgeTier(dave), 3);
    }

    function test_Tier_Drops_OnRevoke() public {
        vm.prank(alice);
        vouch.attest("bobagent", DELIVERED_WORK, bytes32(0));
        assertEq(badge.badgeTier(bob), 2);
        vm.prank(alice);
        vouch.revokeAttestation("bobagent", DELIVERED_WORK);
        assertEq(badge.badgeTier(bob), 0);
    }

    // ---------------------------------------------------------------
    // tokenURI
    // ---------------------------------------------------------------

    function test_TokenURI_Prefix_AndTierName() public {
        vm.prank(alice);
        badge.mint();
        vm.prank(alice);
        vouch.attest("bobagent", ACCURATE_ALPHA, bytes32(0));
        string memory uri = badge.tokenURI(1);
        // Must be a base64 JSON data URI.
        bytes memory prefix = bytes("data:application/json;base64,");
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(bytes(uri)[i], prefix[i]);
        }
        assertGt(bytes(uri).length, 200);
    }

    function test_TokenURI_Nonexistent_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(VouchBadge.TokenDoesNotExist.selector, 999));
        badge.tokenURI(999);
    }

    function test_TierName_Mapping() public view {
        assertEq(badge.tierName(0), "Member");
        assertEq(badge.tierName(1), "Contributor");
        assertEq(badge.tierName(2), "Trusted");
        assertEq(badge.tierName(3), "Well-Regarded");
        assertEq(badge.tierName(4), "Highly Trusted");
    }
}
