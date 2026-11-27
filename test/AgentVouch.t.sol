// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { AgentVouch } from "../src/AgentVouch.sol";
import { MockHandleRegistry } from "./mocks/MockHandleRegistry.sol";

/// @notice Unit tests for AgentVouch against MockHandleRegistry (DESIGN §6.2.1).
/// @dev Covers: happy path + event fields, every specified revert, the
///      duplicate/update/revoke/reactivate semantics of §2.5, the MAX_GIVEN
///      cap, the full read API, case handling (§2.2), and gas measurements
///      for the create/update/revoke paths.
contract AgentVouchTest is Test {
    // Category ids (DESIGN §2.3, frozen).
    uint8 internal constant DELIVERED_WORK = 0;
    uint8 internal constant ACCURATE_ALPHA = 1;
    uint8 internal constant PAID_ON_TIME = 2;
    uint8 internal constant GOOD_COUNTERPARTY = 3;
    uint8 internal constant HELPFUL_GUIDE = 4;

    uint64 internal constant T1 = 1_700_000_000;

    // Same event signatures as AgentVouch, redeclared for vm.expectEmit.
    event Attested(
        bytes32 indexed issuerLabel,
        bytes32 indexed subjectLabel,
        uint8 indexed category,
        address issuer,
        address subject,
        string issuerHandle,
        string subjectHandle,
        bytes32 evidenceHash,
        bool isUpdate
    );
    event AttestationRevoked(
        bytes32 indexed issuerLabel,
        bytes32 indexed subjectLabel,
        uint8 indexed category,
        address issuer,
        address subject,
        string issuerHandle,
        string subjectHandle
    );

    MockHandleRegistry internal registry;
    AgentVouch internal vouch;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave"); // never a holder (unless a test registers him)

    string internal constant ALICE_H = "aliceagent";
    string internal constant BOB_H = "bobagent";
    string internal constant CAROL_H = "carolagent";

    bytes32 internal ev1 = keccak256(bytes("https://boltbook.fun/posts/1001"));
    bytes32 internal ev2 = keccak256(bytes("https://boltbook.fun/posts/2002"));

    function setUp() public {
        registry = new MockHandleRegistry();
        vouch = new AgentVouch(address(registry));
        registry.registerHandle(alice, ALICE_H);
        registry.registerHandle(bob, BOB_H);
        registry.registerHandle(carol, CAROL_H);
        vm.warp(T1);
    }

    function _label(string memory h) internal pure returns (bytes32) {
        return keccak256(bytes(h));
    }

    // ---------------------------------------------------------------
    // Happy path
    // ---------------------------------------------------------------

    function test_Attest_Create_StorageAndCounters() public {
        vm.prank(alice);
        vouch.attest(BOB_H, DELIVERED_WORK, ev1);

        (bool active, bytes32 evidence, uint64 createdAt, uint64 updatedAt) =
            vouch.getAttestation(alice, bob, DELIVERED_WORK);
        assertTrue(active);
        assertEq(evidence, ev1);
        assertEq(createdAt, T1);
        assertEq(updatedAt, T1);

        assertTrue(vouch.hasActiveAttestation(alice, bob, DELIVERED_WORK));
        assertEq(vouch.givenCountOf(alice), 1);
        assertEq(vouch.receivedCountOf(bob, DELIVERED_WORK), 1);
        assertEq(vouch.receivedCountOfHandle(BOB_H, DELIVERED_WORK), 1);
        assertEq(vouch.totalActiveAttestations(), 1);
        assertEq(vouch.uniqueInteractors(), 1);
        assertTrue(vouch.hasInteracted(alice));
        assertEq(vouch.lastActivityAt(alice), T1);
    }

    function test_Attest_Create_EmitsEventWithAllFields() public {
        vm.expectEmit(true, true, true, true, address(vouch));
        emit Attested(_label(ALICE_H), _label(BOB_H), DELIVERED_WORK, alice, bob, ALICE_H, BOB_H, ev1, false);
        vm.prank(alice);
        vouch.attest(BOB_H, DELIVERED_WORK, ev1);
    }

    function test_LabelMatchesRegistryTokenId() public view {
        // DESIGN §2.2: Vouch label keys and registry tokenIds are one key space.
        assertEq(uint256(_label(ALICE_H)), registry.tokenIdOf(ALICE_H));
        assertEq(uint256(_label(BOB_H)), registry.tokenIdOf(BOB_H));
    }

    function test_Attest_ZeroEvidence_Allowed() public {
        vm.prank(alice);
        vouch.attest(BOB_H, HELPFUL_GUIDE, bytes32(0));
        (bool active, bytes32 evidence,,) = vouch.getAttestation(alice, bob, HELPFUL_GUIDE);
        assertTrue(active);
        assertEq(evidence, bytes32(0));
    }

    // ---------------------------------------------------------------
    // Reverts, in the spec's check order (§2.5)
    // ---------------------------------------------------------------

    function test_Attest_IssuerNotHolder_Reverts() public {
        vm.prank(dave);
        vm.expectRevert(AgentVouch.NotAgentIdHolder.selector);
        vouch.attest(BOB_H, DELIVERED_WORK, ev1);
    }

    function test_Attest_CheckOrder_CategoryCheckedBeforeHolder() public {
        // Non-holder AND bad category: the category error must win (§2.5 order).
        vm.prank(dave);
        vm.expectRevert(AgentVouch.InvalidCategory.selector);
        vouch.attest(BOB_H, 5, ev1);
    }

    function test_Attest_InvalidCategory_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentVouch.InvalidCategory.selector);
        vouch.attest(BOB_H, 5, ev1);
    }

    function test_Attest_UnknownSubjectHandle_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentVouch.SubjectNotFound.selector);
        vouch.attest("ghostagent", DELIVERED_WORK, ev1);
    }

    function test_Attest_SelfAttestation_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentVouch.SelfAttestation.selector);
        vouch.attest(ALICE_H, DELIVERED_WORK, ev1);
    }

    // ---------------------------------------------------------------
    // Duplicate / update semantics (§2.5)
    // ---------------------------------------------------------------

    function test_Attest_UpdatePath_OnlyEvidenceAndUpdatedAtChange() public {
        vm.prank(alice);
        vouch.attest(BOB_H, ACCURATE_ALPHA, ev1);

        vm.warp(T1 + 3600);
        vm.expectEmit(true, true, true, true, address(vouch));
        emit Attested(_label(ALICE_H), _label(BOB_H), ACCURATE_ALPHA, alice, bob, ALICE_H, BOB_H, ev2, true);
        vm.prank(alice);
        vouch.attest(BOB_H, ACCURATE_ALPHA, ev2);

        (bool active, bytes32 evidence, uint64 createdAt, uint64 updatedAt) =
            vouch.getAttestation(alice, bob, ACCURATE_ALPHA);
        assertTrue(active);
        assertEq(evidence, ev2);
        assertEq(createdAt, T1, "createdAt must not move on update");
        assertEq(updatedAt, T1 + 3600);
        // Counters never double-count an update.
        assertEq(vouch.givenCountOf(alice), 1);
        assertEq(vouch.receivedCountOf(bob, ACCURATE_ALPHA), 1);
        assertEq(vouch.totalActiveAttestations(), 1);
        assertEq(vouch.uniqueInteractors(), 1);
    }

    // ---------------------------------------------------------------
    // Revoke + reactivate (§2.5)
    // ---------------------------------------------------------------

    function test_Revoke_HappyPath() public {
        vm.prank(alice);
        vouch.attest(BOB_H, PAID_ON_TIME, ev1);

        vm.warp(T1 + 7200);
        vm.expectEmit(true, true, true, true, address(vouch));
        emit AttestationRevoked(_label(ALICE_H), _label(BOB_H), PAID_ON_TIME, alice, bob, ALICE_H, BOB_H);
        vm.prank(alice);
        vouch.revokeAttestation(BOB_H, PAID_ON_TIME);

        (bool active, bytes32 evidence, uint64 createdAt, uint64 updatedAt) =
            vouch.getAttestation(alice, bob, PAID_ON_TIME);
        assertFalse(active);
        // History is preserved in storage after revoke (§2.5 summary table).
        assertEq(evidence, ev1);
        assertEq(createdAt, T1);
        assertEq(updatedAt, T1);
        assertEq(vouch.givenCountOf(alice), 0);
        assertEq(vouch.receivedCountOf(bob, PAID_ON_TIME), 0);
        assertEq(vouch.totalActiveAttestations(), 0);
        assertEq(vouch.uniqueInteractors(), 1, "revoke must not un-touch the issuer");
        assertEq(vouch.lastActivityAt(alice), T1 + 7200);
    }

    function test_Revoke_NothingActive_Reverts() public {
        vm.prank(bob);
        vm.expectRevert(AgentVouch.NoActiveAttestation.selector);
        vouch.revokeAttestation(ALICE_H, DELIVERED_WORK);
    }

    function test_Revoke_ByNonHolder_RevertsNoActiveAttestation() public {
        // §2.5: revoke performs no holder check — a non-holder derives the
        // empty-string label, matches nothing, and gets NoActiveAttestation.
        vm.prank(dave);
        vm.expectRevert(AgentVouch.NoActiveAttestation.selector);
        vouch.revokeAttestation(BOB_H, DELIVERED_WORK);
    }

    function test_Revoke_InvalidCategory_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentVouch.InvalidCategory.selector);
        vouch.revokeAttestation(BOB_H, 5);
    }

    function test_Revoke_SomeoneElsesAttestation_NotPossible() public {
        vm.prank(alice);
        vouch.attest(BOB_H, GOOD_COUNTERPARTY, ev1);
        // Bob cannot revoke Alice's attestation: the record is keyed by the
        // caller's own label, so Bob's lookup finds nothing.
        vm.prank(bob);
        vm.expectRevert(AgentVouch.NoActiveAttestation.selector);
        vouch.revokeAttestation(ALICE_H, GOOD_COUNTERPARTY);
        assertTrue(vouch.hasActiveAttestation(alice, bob, GOOD_COUNTERPARTY));
    }

    function test_ReactivateAfterRevoke_IsFreshAttestation() public {
        vm.prank(alice);
        vouch.attest(BOB_H, DELIVERED_WORK, ev1);
        vm.prank(alice);
        vouch.revokeAttestation(BOB_H, DELIVERED_WORK);

        vm.warp(T1 + 86_400);
        vm.expectEmit(true, true, true, true, address(vouch));
        emit Attested(_label(ALICE_H), _label(BOB_H), DELIVERED_WORK, alice, bob, ALICE_H, BOB_H, ev2, false);
        vm.prank(alice);
        vouch.attest(BOB_H, DELIVERED_WORK, ev2);

        (bool active, bytes32 evidence, uint64 createdAt, uint64 updatedAt) =
            vouch.getAttestation(alice, bob, DELIVERED_WORK);
        assertTrue(active);
        assertEq(evidence, ev2);
        assertEq(createdAt, T1 + 86_400, "createdAt resets on re-activation");
        assertEq(updatedAt, T1 + 86_400);
        assertEq(vouch.givenCountOf(alice), 1);
        assertEq(vouch.receivedCountOf(bob, DELIVERED_WORK), 1);
        assertEq(vouch.totalActiveAttestations(), 1);
    }

    // ---------------------------------------------------------------
    // MAX_GIVEN cap (§2.5 step 6, §2.9)
    // ---------------------------------------------------------------

    function test_MaxGiven_Enforced() public {
        // 100 subjects × 5 categories = exactly MAX_GIVEN (500) active given.
        for (uint256 i = 0; i < 100; i++) {
            address subj = address(uint160(0x10000 + i));
            string memory h = string.concat("agent", vm.toString(i));
            registry.registerHandle(subj, h);
            for (uint8 c = 0; c < vouch.CATEGORY_COUNT(); c++) {
                vm.prank(alice);
                vouch.attest(h, c, ev1);
            }
        }
        assertEq(vouch.givenCountOf(alice), 500);
        assertEq(vouch.totalActiveAttestations(), 500);

        // The 501st CREATE reverts.
        address extra = address(uint160(0x20000));
        registry.registerHandle(extra, "agentextra");
        vm.prank(alice);
        vm.expectRevert(AgentVouch.GivenCapReached.selector);
        vouch.attest("agentextra", DELIVERED_WORK, ev1);

        // But an UPDATE of an existing active record still works at the cap.
        vm.prank(alice);
        vouch.attest("agent0", DELIVERED_WORK, ev2);
        assertEq(vouch.givenCountOf(alice), 500);

        // And after one revoke there is room to create again.
        vm.prank(alice);
        vouch.revokeAttestation("agent0", DELIVERED_WORK);
        assertEq(vouch.givenCountOf(alice), 499);
        vm.prank(alice);
        vouch.attest("agentextra", DELIVERED_WORK, ev1);
        assertEq(vouch.givenCountOf(alice), 500);
    }

    // ---------------------------------------------------------------
    // Read API (§2.7)
    // ---------------------------------------------------------------

    function test_Reads_ForNonHolders_ReturnInactive() public {
        (bool active, bytes32 evidence, uint64 createdAt, uint64 updatedAt) =
            vouch.getAttestation(dave, bob, DELIVERED_WORK);
        assertFalse(active);
        assertEq(evidence, bytes32(0));
        assertEq(createdAt, 0);
        assertEq(updatedAt, 0);

        (bool activeAsSubject,,,) = vouch.getAttestation(alice, dave, DELIVERED_WORK);
        assertFalse(activeAsSubject);
        assertFalse(vouch.hasActiveAttestation(dave, bob, DELIVERED_WORK));
        assertFalse(
            vouch.hasActiveAttestation(alice, bob, 5), "invalid category reads as false, not a revert"
        );
        assertEq(vouch.receivedCountOf(dave, DELIVERED_WORK), 0);
        assertEq(vouch.givenCountOf(dave), 0);
        assertEq(vouch.receivedCountOfHandle("neverclaimed", DELIVERED_WORK), 0);
    }

    function test_GetAttestationByHandles_MatchesAddressVariant() public {
        vm.prank(alice);
        vouch.attest(BOB_H, GOOD_COUNTERPARTY, ev1);
        (bool a1, bytes32 e1, uint64 c1, uint64 u1) = vouch.getAttestation(alice, bob, GOOD_COUNTERPARTY);
        (bool a2, bytes32 e2, uint64 c2, uint64 u2) =
            vouch.getAttestationByHandles(ALICE_H, BOB_H, GOOD_COUNTERPARTY);
        assertEq(a1, a2);
        assertEq(e1, e2);
        assertEq(c1, c2);
        assertEq(u1, u2);
        assertTrue(a2);
    }

    function test_UniqueInteractors_CountsDistinctCallersOnce() public {
        vm.prank(alice);
        vouch.attest(BOB_H, DELIVERED_WORK, ev1);
        vm.prank(alice);
        vouch.attest(CAROL_H, DELIVERED_WORK, ev1);
        assertEq(vouch.uniqueInteractors(), 1);

        vm.prank(bob);
        vouch.attest(ALICE_H, HELPFUL_GUIDE, ev1);
        assertEq(vouch.uniqueInteractors(), 2);

        vm.prank(bob);
        vouch.revokeAttestation(ALICE_H, HELPFUL_GUIDE);
        assertEq(vouch.uniqueInteractors(), 2, "revoke by an existing interactor must not double-count");
    }

    function test_IsActiveAgent_Windows() public {
        // Holder who never interacted: not active under any realistic window.
        assertFalse(vouch.isActiveAgent(carol, 30));
        // Non-holder: never active.
        assertFalse(vouch.isActiveAgent(dave, 30));

        vm.prank(alice);
        vouch.attest(BOB_H, DELIVERED_WORK, ev1); // at T1

        assertTrue(vouch.isActiveAgent(alice, 1));
        assertTrue(vouch.isActiveAgent(alice, 0), "same-block activity counts at window 0");

        vm.warp(T1 + 1 days); // exactly at the 1-day edge: still active (>=)
        assertTrue(vouch.isActiveAgent(alice, 1));
        vm.warp(T1 + 1 days + 1); // one second past the edge
        assertFalse(vouch.isActiveAgent(alice, 1));
        assertTrue(vouch.isActiveAgent(alice, 7));
    }

    // ---------------------------------------------------------------
    // Case handling (§2.2)
    // ---------------------------------------------------------------

    function test_Case_SubjectHandleMustMatchRegisteredCasing() public {
        // Handles exist only in their registered (lowercase) form; a
        // differently-cased string is a different, unclaimed handle, so
        // resolution fails. The issuer side needs no normalization at all:
        // the issuer label is derived from the registry-returned handle.
        vm.prank(alice);
        vm.expectRevert(AgentVouch.SubjectNotFound.selector);
        vouch.attest("BOBAGENT", DELIVERED_WORK, ev1);

        vm.prank(alice);
        vouch.attest(BOB_H, DELIVERED_WORK, ev1);
        assertEq(vouch.receivedCountOfHandle(BOB_H, DELIVERED_WORK), 1);
        assertEq(vouch.receivedCountOfHandle("BOBAGENT", DELIVERED_WORK), 0);
    }

    // ---------------------------------------------------------------
    // Registry-invariant reliance (DESIGN §2.5, check 3)
    // ---------------------------------------------------------------

    /// @dev DESIGN §2.5 deliberately performs NO separate subject `balanceOf`
    ///      check: "a handle exists only if minted, [so resolution] also
    ///      proves the subject is a holder". This test pins the consequence
    ///      using a registry state the real registry can never be in (handle
    ///      resolving to an address with balanceOf == 0, via the mock's
    ///      forceResolve backdoor): AgentVouch trusts the resolution. If the
    ///      design ever adds a subject holder check, this test must change.
    function test_Attest_SubjectResolution_TrustsRegistryInvariant() public {
        registry.forceResolve("ghostagent", dave);
        assertEq(registry.ownerOfHandle("ghostagent"), dave);
        assertEq(registry.balanceOf(dave), 0);

        vm.prank(alice);
        vouch.attest("ghostagent", DELIVERED_WORK, ev1); // succeeds by design

        assertEq(vouch.receivedCountOfHandle("ghostagent", DELIVERED_WORK), 1);
    }

    // ---------------------------------------------------------------
    // No value, no admin surface
    // ---------------------------------------------------------------

    function test_Contract_RejectsPlainBnbTransfer() public {
        (bool ok,) = address(vouch).call{ value: 1 ether }("");
        assertFalse(ok, "no receive/fallback: plain transfers must revert");
        assertEq(address(vouch).balance, 0);
    }

    // ---------------------------------------------------------------
    // Gas measurements (DESIGN §2.10 — replace estimates with fork numbers
    // in build task 4; these are the local/mock counterparts)
    // ---------------------------------------------------------------

    function testGas_Attest_CreatePath() public {
        vm.prank(alice);
        uint256 g0 = gasleft();
        vouch.attest(BOB_H, DELIVERED_WORK, ev1);
        uint256 used = g0 - gasleft();
        console.log("GAS attest (create, first touch):", used);
    }

    function testGas_Attest_CreatePath_RepeatInteractor() public {
        vm.prank(alice);
        vouch.attest(BOB_H, DELIVERED_WORK, ev1);
        vm.prank(alice);
        uint256 g0 = gasleft();
        vouch.attest(CAROL_H, DELIVERED_WORK, ev1);
        uint256 used = g0 - gasleft();
        console.log("GAS attest (create, repeat interactor):", used);
    }

    function testGas_Attest_UpdatePath() public {
        vm.prank(alice);
        vouch.attest(BOB_H, DELIVERED_WORK, ev1);
        vm.warp(T1 + 60);
        vm.prank(alice);
        uint256 g0 = gasleft();
        vouch.attest(BOB_H, DELIVERED_WORK, ev2);
        uint256 used = g0 - gasleft();
        console.log("GAS attest (update):", used);
    }

    function testGas_RevokePath() public {
        vm.prank(alice);
        vouch.attest(BOB_H, DELIVERED_WORK, ev1);
        vm.prank(alice);
        uint256 g0 = gasleft();
        vouch.revokeAttestation(BOB_H, DELIVERED_WORK);
        uint256 used = g0 - gasleft();
        console.log("GAS revoke:", used);
    }
}
