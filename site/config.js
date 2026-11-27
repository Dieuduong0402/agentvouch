// AgentVouch — site configuration (the ONLY file edited at deploy time).
//
// Deploy-time substitution:
//   1. Set VOUCH_ADDRESS to the deployed AgentVouch contract address.
//   2. Set DEPLOY_BLOCK to the block the contract was deployed in
//      (used by the indexer; the site itself only displays it).
//   3. Regenerate llms.txt with the same address (see README.md).
// Everything else in this site reads from this object.
const VOUCH_CONFIG = {
  // AgentVouch contract on BNB Smart Chain (chainId 56).
  // Deployed 26/11/2026, tx 0xc3c7c38f1372d1a41b0918b0781b88c4389d42d907672ff42e02b7a62c949070, block 135864850.
  VOUCH_ADDRESS: "0x93271C060aC7f3432921Ae6225027aa5B2538E99",

  // SPACE ID HandleRegistry (Agent ID) — real, already deployed.
  REGISTRY_ADDRESS: "0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F",

  // Block number AgentVouch was deployed at (26/11/2026).
  DEPLOY_BLOCK: 135864850,

  // VouchBadge contract (soulbound reputation badge, Option A).
  // Deployed 27/11/2026 ~00:13 VN, tx 0xf695571db1dd4749917a0c40a71561f7942d9c662091bc91e7c618a3adb134fe, block 135884701.
  BADGE_ADDRESS: "0xed4d84A891EA97aAb5D412cd36035dd7aA7BF2b9",
  BADGE_DEPLOY_BLOCK: 135884701,

  CHAIN_ID: 56,
  CHAIN_NAME: "BNB Smart Chain",

  // Public BSC RPC endpoints, tried in order with rotation on error/timeout.
  RPCS: [
    "https://bsc-dataseed.binance.org",
    "https://bsc-dataseed1.binance.org",
    "https://bsc-dataseed2.binance.org",
    "https://bsc.publicnode.com",
    "https://rpc-bsc.48.club",
  ],

  // Campaign milestone shown on the landing page: distinct Agent ID
  // addresses that have interacted with the contract.
  MILESTONE_INTERACTORS: 30,
};

if (typeof module !== "undefined" && module.exports) {
  module.exports = VOUCH_CONFIG;
}
