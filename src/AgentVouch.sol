// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal read surface of the SPACE ID HandleRegistry (Agent ID).
/// @dev The registry is a soulbound ERC-721: `balanceOf(a)` is 0 or 1,
///      `handleOf(a)` returns "" for non-holders, and `ownerOfHandle(h)`
///      returns address(0) for unclaimed handles. A handle exists only if it
///      was minted, so a non-zero resolution also proves holder status.
interface IHandleRegistry {
    function balanceOf(address owner) external view returns (uint256);
    function handleOf(address owner) external view returns (string memory);
    function ownerOfHandle(string calldata handle) external view returns (address);
}

/// @title AgentVouch — an on-chain attestation graph between Agent ID holders.
/// @notice One Agent ID holder attests, about another Agent ID holder, in one
///         fixed factual category, with a hash of public evidence attached.
///         Attestations are non-stackable (one record per issuer/subject/
///         category), attributable to the issuer's permanent handle, and
///         revocable only by the issuer.
///
///         Categories (frozen at deploy — changing them needs a new contract):
///           0 DELIVERED_WORK    "This agent completed work it committed to."
///           1 ACCURATE_ALPHA    "This agent's published call/analysis proved accurate."
///           2 PAID_ON_TIME      "This agent paid what it owed, on time."
///           3 GOOD_COUNTERPARTY "I worked with this agent and the collaboration was reliable."
///           4 HELPFUL_GUIDE     "This agent's guide/explainer materially helped others."
///
/// @dev Posture: this contract holds no funds, accepts no value, and has no
///      owner or admin functions of any kind — there is nothing to renounce
///      because nothing exists. The registry address is immutable. Any BNB
///      force-sent to this contract (e.g. via selfdestruct) is permanently
///      locked by design: there is no withdrawal path.
///
///      Identity keys: every record is keyed by label hash,
///      `keccak256(bytes(handle))` — byte-identical to the registry's own
///      tokenId derivation, so a Vouch record and the registry NFT for the
///      same handle share one canonical key across both contracts. The
///      issuer label is always derived from the registry-returned handle
///      (canonical casing), never from user input.
///
///      No ReentrancyGuard is used, deliberately: the only external calls are
///      `view` calls into the known, verified, non-callback HandleRegistry,
///      and in `attest` they all happen before any state write
///      (checks-effects pattern).
contract AgentVouch {
    /// @notice Number of attestation categories. Frozen at deploy.
    uint8 public constant CATEGORY_COUNT = 5;
    /// @notice Max active attestations a single issuer handle may hold.
    /// @dev Spam guard: bounds state growth per identity while staying far
    ///      above any plausible legitimate use.
    uint32 public constant MAX_GIVEN = 500;

    /// @notice The Agent ID HandleRegistry this contract reads identity from.
    /// @dev Immutable — set once in the constructor, changeable by no one.
    IHandleRegistry public immutable registry;

    struct Attestation {
        bytes32 evidenceHash; // keccak256 of the evidence URL string; 0x0 = "no evidence attached"
        uint64 createdAt; // first creation (or re-activation after revoke)
        uint64 updatedAt; // last evidence update
        bool active; // false after revoke
    }

    /// @notice The graph itself: one record per (issuer, subject, category).
    mapping(
        bytes32 issuerLabel => mapping(bytes32 subjectLabel => mapping(uint8 category => Attestation))
    ) public attestations;
    /// @notice Active attestations issued by a handle (spam cap + profile reads).
    mapping(bytes32 issuerLabel => uint32) public givenCount;
    /// @notice Active attestations received by a handle, per category.
    mapping(bytes32 subjectLabel => mapping(uint8 category => uint32)) public receivedCount;
    /// @notice First-touch flag per caller address.
    mapping(address => bool) public hasInteracted;
    /// @notice Last successful `attest`/`revokeAttestation` timestamp per address.
    mapping(address => uint64) public lastActivityAt;

    /// @notice Live graph size: number of currently active attestations.
    uint256 public totalActiveAttestations;
    /// @notice Distinct addresses that have ever successfully called
    ///         `attest`/`revokeAttestation`. Every such caller is a registry
    ///         holder by construction (see `attest` checks).
    uint256 public uniqueInteractors;

    /// @dev Handle strings are carried in the events (read from the registry
    ///      inside the transaction) so indexers and frontends never need a
    ///      lookup table; labels are indexed topics so per-agent history is a
    ///      cheap topic-filtered log scan.
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

    error InvalidCategory();
    error NotAgentIdHolder();
    error SubjectNotFound();
    error SelfAttestation();
    error NoActiveAttestation();
    error GivenCapReached();

    constructor(address registry_) {
        registry = IHandleRegistry(registry_);
    }

    /// @notice Attest about another Agent ID holder, or update the evidence
    ///         hash of your existing active attestation for the same
    ///         (subject, category) pair.
    /// @param subjectHandle The subject's handle, exactly as registered
    ///        (lowercase). Resolved on-chain via the registry in this call.
    /// @param category One of the 5 frozen categories (0–4).
    /// @param evidenceHash keccak256 of the public evidence URL string;
    ///        bytes32(0) is allowed and means "no evidence attached".
    /// @dev Check order is part of the spec: category → issuer holder status
    ///      → subject resolution → self-attestation. Re-attesting while a
    ///      record is active only updates the evidence hash and `updatedAt`
    ///      (never stacks, never double-counts); re-attesting after a revoke
    ///      re-activates the record as a fresh attestation (`createdAt`
    ///      resets, counters increment again).
    function attest(string calldata subjectHandle, uint8 category, bytes32 evidenceHash) external {
        if (category >= CATEGORY_COUNT) revert InvalidCategory();
        if (registry.balanceOf(msg.sender) == 0) revert NotAgentIdHolder();
        address subject = registry.ownerOfHandle(subjectHandle);
        if (subject == address(0)) revert SubjectNotFound();
        if (subject == msg.sender) revert SelfAttestation();

        string memory issuerHandle = registry.handleOf(msg.sender);
        bytes32 issuerLabel = keccak256(bytes(issuerHandle));
        bytes32 subjectLabel = keccak256(bytes(subjectHandle));
        bool isUpdate = _createOrUpdate(issuerLabel, subjectLabel, category, evidenceHash);
        _touch(msg.sender);
        emit Attested(
            issuerLabel,
            subjectLabel,
            category,
            msg.sender,
            subject,
            issuerHandle,
            subjectHandle,
            evidenceHash,
            isUpdate
        );
    }

    /// @dev Writes the record for (issuerLabel, subjectLabel, category) and
    ///      maintains the counters. Returns true when an already-active
    ///      record was updated, false when a fresh attestation was created
    ///      (first attestation, or re-activation after a revoke — in which
    ///      case `createdAt` resets and the counters increment again).
    ///      The per-issuer cap applies to the create path only; updates of
    ///      an active record are uncapped.
    /// @dev Extracted from `attest` purely to keep the caller's stack frame
    ///      within the legacy codegen's limits (the §2.8 skeleton inlined
    ///      this block and hit "stack too deep" under the design's pinned
    ///      compiler settings); behavior is identical.
    function _createOrUpdate(bytes32 issuerLabel, bytes32 subjectLabel, uint8 category, bytes32 evidenceHash)
        internal
        returns (bool isUpdate)
    {
        Attestation storage rec = attestations[issuerLabel][subjectLabel][category];
        isUpdate = rec.active;
        if (!isUpdate) {
            if (givenCount[issuerLabel] >= MAX_GIVEN) revert GivenCapReached();
            rec.createdAt = uint64(block.timestamp);
            givenCount[issuerLabel]++;
            receivedCount[subjectLabel][category]++;
            totalActiveAttestations++;
        }
        rec.evidenceHash = evidenceHash;
        rec.updatedAt = uint64(block.timestamp);
        rec.active = true;
    }

    /// @notice Revoke your own active attestation for (subject, category).
    /// @dev Keyed by the caller's own issuer label, so there is no "revoke
    ///      someone else's" path. No holder check is performed on purpose:
    ///      a caller without a handle derives the label of the empty string,
    ///      which can never match a record they created, so the lookup below
    ///      fails cleanly with `NoActiveAttestation` — revoking your own
    ///      attestation stays possible unconditionally. The record (with its
    ///      history timestamps) remains in storage; only `active` flips and
    ///      the counters decrement.
    function revokeAttestation(string calldata subjectHandle, uint8 category) external {
        if (category >= CATEGORY_COUNT) revert InvalidCategory();
        string memory issuerHandle = registry.handleOf(msg.sender);
        bytes32 issuerLabel = keccak256(bytes(issuerHandle));
        bytes32 subjectLabel = keccak256(bytes(subjectHandle));
        Attestation storage rec = attestations[issuerLabel][subjectLabel][category];
        if (!rec.active) revert NoActiveAttestation();
        rec.active = false;
        givenCount[issuerLabel]--;
        receivedCount[subjectLabel][category]--;
        totalActiveAttestations--;
        _touch(msg.sender);
        // This final registry read exists only to fill the event's `subject`
        // address field; the labels already identify the subject.
        address subject = registry.ownerOfHandle(subjectHandle);
        emit AttestationRevoked(
            issuerLabel, subjectLabel, category, msg.sender, subject, issuerHandle, subjectHandle
        );
    }

    /// @dev First-touch bookkeeping shared by both write functions.
    function _touch(address who) internal {
        if (!hasInteracted[who]) {
            hasInteracted[who] = true;
            uniqueInteractors++;
        }
        lastActivityAt[who] = uint64(block.timestamp);
    }

    // ------------------------------------------------------------------
    // Read API — all `view`, free, permissionless (DESIGN §2.7).
    // Address-keyed reads are for contract composers; handle-keyed reads are
    // for off-chain consumers and deliberately return attestation data only —
    // never a resolved address.
    // ------------------------------------------------------------------

    /// @dev Label of an address, derived from the registry-returned handle
    ///      (canonical casing). bytes32(0) sentinel when the address holds no
    ///      handle — a real handle's keccak256 is never 0 in practice.
    function _labelOf(address a) internal view returns (bytes32) {
        string memory h = registry.handleOf(a);
        return bytes(h).length == 0 ? bytes32(0) : keccak256(bytes(h));
    }

    /// @notice Full attestation record between two addresses.
    /// @return active False if either party holds no handle, or no active
    ///         attestation exists for the triple.
    function getAttestation(address issuer, address subject, uint8 category)
        external
        view
        returns (bool active, bytes32 evidenceHash, uint64 createdAt, uint64 updatedAt)
    {
        bytes32 il = _labelOf(issuer);
        bytes32 sl = _labelOf(subject);
        if (il == bytes32(0) || sl == bytes32(0)) return (false, bytes32(0), 0, 0);
        Attestation storage rec = attestations[il][sl][category];
        return (rec.active, rec.evidenceHash, rec.createdAt, rec.updatedAt);
    }

    /// @notice The one-call composability check: does an active attestation
    ///         exist from `issuer` about `subject` in `category`?
    function hasActiveAttestation(address issuer, address subject, uint8 category)
        external
        view
        returns (bool)
    {
        bytes32 il = _labelOf(issuer);
        bytes32 sl = _labelOf(subject);
        if (il == bytes32(0) || sl == bytes32(0) || category >= CATEGORY_COUNT) return false;
        return attestations[il][sl][category].active;
    }

    /// @notice Active attestations received by an address in a category.
    function receivedCountOf(address subject, uint8 category) external view returns (uint32) {
        bytes32 sl = _labelOf(subject);
        if (sl == bytes32(0)) return 0;
        return receivedCount[sl][category];
    }

    /// @notice Active attestations issued by an address, across all categories.
    function givenCountOf(address issuer) external view returns (uint32) {
        bytes32 il = _labelOf(issuer);
        if (il == bytes32(0)) return 0;
        return givenCount[il];
    }

    /// @notice Is this address a registry holder that has interacted with
    ///         AgentVouch within the last `windowDays` days?
    function isActiveAgent(address agent, uint256 windowDays) external view returns (bool) {
        return registry.balanceOf(agent) > 0 && lastActivityAt[agent] + windowDays * 1 days >= block.timestamp;
    }

    /// @notice Full attestation record between two handles.
    /// @dev Pure label lookup — the handles are never resolved to addresses,
    ///      and no address is returned. A record can only exist if both
    ///      handles were registered when it was written, so unknown handles
    ///      naturally read as inactive.
    function getAttestationByHandles(
        string calldata issuerHandle,
        string calldata subjectHandle,
        uint8 category
    ) external view returns (bool active, bytes32 evidenceHash, uint64 createdAt, uint64 updatedAt) {
        Attestation storage rec =
            attestations[keccak256(bytes(issuerHandle))][keccak256(bytes(subjectHandle))][category];
        return (rec.active, rec.evidenceHash, rec.createdAt, rec.updatedAt);
    }

    /// @notice Active attestations received by a handle in a category.
    /// @dev Pure label lookup; 0 for unclaimed handles (no attestation can
    ///      ever have been written under an unclaimed handle's label).
    function receivedCountOfHandle(string calldata subjectHandle, uint8 category)
        external
        view
        returns (uint32)
    {
        return receivedCount[keccak256(bytes(subjectHandle))][category];
    }
}
