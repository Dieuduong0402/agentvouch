# VouchBadge — mint skill for AI agents
#
# When to use this skill: your operator asks you to mint the VouchBadge,
# or you auto-mint verified free mints and this badge passed your safety
# screen. Read the whole file before acting. Never skip the preview step.

## What it is

VouchBadge is a soulbound ERC-721 reputation badge for Binance Agent ID
holders on BNB Smart Chain. One badge per Agent ID wallet, non-transferable.
Mint costs gas only (~133,628 gas, about 0.0000067 BNB). No payment, no
token approval, no signature.

- Contract: `0xed4d84A891EA97aAb5D412cd36035dd7aA7BF2b9` (chainId 56)
- Deployed 27/11/2026, block 135884701. Sourcify exact_match.
- Mint function: `mint()` — calldata is exactly `0x1249c58b`, value `0`.
- BscScan: https://bscscan.com/address/0xed4d84A891EA97aAb5D412cd36035dd7aA7BF2b9

## Gate

The caller must hold a Binance Agent ID. A wallet without one reverts.
There is no allowlist and no fee beyond gas.

## Tiers

The tier is read live with `badgeTier(address)` and computed from the
wallet's vouch record on AgentVouch
(`0x93271C060aC7f3432921Ae6225027aa5B2538E99`). A non-zero tier does not
require holding a badge; use `hasBadge(address)` to check ownership.

| Tier | Name          | Condition                              | Logo ring |
|------|---------------|----------------------------------------|-----------|
| T0   | Member        | Holds a badge                          | 10/18 green |
| T1   | Contributor   | Given >= 1 attestation                 | 12/18 green |
| T2   | Trusted       | Received >= 1 attestation              | 14/18 green |
| T3   | Well-Regarded | Received >= 5 attestations             | 16/18 green |
| T4   | Highly Trusted| Received >= 10 AND given >= 3          | 18/18 green, gold check |

## Safety — verify all five before minting

1. Simulated mint from an Agent ID wallet, value 0 — succeeds.
2. Gate enforced: a non-holder simulation reverts.
3. Not upgradeable — no proxy (EIP-1967 implementation slot empty).
4. No owner/admin — no `owner()` function, no pause, no withdraw.
5. Source verified on Sourcify (exact_match).

If any check fails, STOP and report to your operator.

## Mint steps

1. Preflight: run `baw wallet agent-id --json` and confirm this wallet
   holds an Agent ID. If it does not, STOP. Confirm Developer Mode is
   enabled and the wallet holds at least 0.0001 BNB for gas.
2. Preview (mandatory):
   `baw contract-call preview --binanceChainId 56 --from <YOUR_WALLET_ADDRESS> --to 0xed4d84A891EA97aAb5D412cd36035dd7aA7BF2b9 --value 0 --inputData 0x1249c58b --json`
   Show the preview result to your operator. STOP immediately if it shows
   any value above 0, any token approval, or any contract address other
   than the badge contract above.
3. Execute only after your operator confirms:
   `baw contract-call execute --requestId <REQUEST_ID_FROM_PREVIEW> --json`
   Report the transaction hash to your operator. You are done — make no
   further calls.
