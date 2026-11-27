// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title MockHandleRegistry — test double for the SPACE ID HandleRegistry.
/// @notice Mirrors the exact read surface AgentVouch uses, with the real
///         registry's semantics (DESIGN.md §0):
///           - soulbound, one handle per address: `balanceOf(a)` ∈ {0, 1}
///           - `handleOf(a)` returns "" for non-holders
///           - `ownerOfHandle(h)` returns address(0) for unclaimed handles,
///             and matches handle strings exactly (handles are registered
///             lowercase a–z0–9 only, so a differently-cased string is simply
///             a different, unclaimed handle)
///           - tokenId of a handle is `uint256(keccak256(bytes(handle)))` —
///             the same derivation AgentVouch uses for its label keys
/// @dev Registration on the real registry is backend-signature-gated; here
///      `registerHandle` is permissionless because this contract exists only
///      to set up test state. It is never deployed.
contract MockHandleRegistry {
    mapping(address => string) private _handleOf;
    mapping(string => address) private _ownerOfHandle;

    error AlreadyHasHandle(address owner);
    error HandleTaken(string handle);
    error EmptyHandle();

    /// @notice Test setup: bind `handle` to `owner` in both directions.
    /// @dev Enforces the real registry's invariants: one handle per address,
    ///      one owner per handle, non-empty handle.
    function registerHandle(address owner, string calldata handle) external {
        if (bytes(handle).length == 0) revert EmptyHandle();
        if (bytes(_handleOf[owner]).length != 0) revert AlreadyHasHandle(owner);
        if (_ownerOfHandle[handle] != address(0)) revert HandleTaken(handle);
        _handleOf[owner] = handle;
        _ownerOfHandle[handle] = owner;
    }

    /// @notice TEST-ONLY BACKDOOR: point a handle at an address WITHOUT
    ///         giving that address a handle or a balance — a state the real
    ///         registry can never be in (a handle exists only if minted to a
    ///         holder). Exists solely to document/test how AgentVouch behaves
    ///         if the registry's resolution⇒holder invariant were ever broken.
    function forceResolve(string calldata handle, address owner) external {
        _ownerOfHandle[handle] = owner;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return bytes(_handleOf[owner]).length == 0 ? 0 : 1;
    }

    function handleOf(address owner) external view returns (string memory) {
        return _handleOf[owner];
    }

    function ownerOfHandle(string calldata handle) external view returns (address) {
        return _ownerOfHandle[handle];
    }

    /// @notice The registry's tokenId derivation, exposed so tests can assert
    ///         it matches AgentVouch's label keys one-to-one.
    function tokenIdOf(string calldata handle) external pure returns (uint256) {
        return uint256(keccak256(bytes(handle)));
    }
}
