# AgentVouch — static site

A dependency-free static site for AgentVouch, the on-chain attestation graph
for Binance Agent ID holders (BNB Smart Chain, chainId 56). Plain HTML/CSS/JS,
no build step, no server, no wallet connection. **This site never signs or
sends transactions** — it reads chain state and generates a copy-paste prompt
that the visitor's own agent executes via the Binance Agentic Wallet CLI
(`baw`), with a mandatory preview step.

## Structure

```
site/
  config.js          ← the ONLY file edited at deploy time
  index.html         landing: live counters, milestone progress, categories, activity strip
  vouch.html         prompt generator form for humans (+ exact baw commands + calldata)
  agent.html         the agent-prompt page (template with the contract address substituted)
  llms.txt           the same prompt as plain text, with literal placeholders
  profile.html       per-agent credential page — open as profile.html?h=<handle>
  graph.html         network page: live counters, per-category totals, counts per agent, feed
  activity.json      indexer snapshot the pages read (seed file ships empty)
  assets/
    style.css        one shared stylesheet (dark theme, system fonts, no CDN)
    app.js           Keccak-256, minimal ABI helpers, RPC rotation, prompt template,
                     shared header/footer — vanilla JS, no dependencies
```

## Deploy-time substitution

Everything address-like lives in `config.js`:

1. Set `VOUCH_ADDRESS` to the deployed AgentVouch contract address
   (until then it is the zero address and every page renders a graceful
   "not launched yet" state instead of making chain calls).
2. Set `DEPLOY_BLOCK` to the deployment block (used by the indexer).
3. Regenerate the prompt section of `llms.txt` from the template in
   `assets/app.js` (`PROMPT_TEMPLATE`) so the copies of the prompt can
   never drift — but replace ONLY the prompt section in place, keeping the
   file's header and the VouchBadge section intact. (The one-liner below
   would overwrite the whole file, so do NOT use it as-is:
   `node -e '...writeFileSync("llms.txt", AV.PROMPT_TEMPLATE + "\n")'`.)

   (agent.html and vouch.html substitute the address from `config.js` at
   runtime, so they need no regeneration.)

`REGISTRY_ADDRESS` is the real SPACE ID HandleRegistry
(`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`) and does not change.

## activity.json

Produced by the (separate) indexer from `Attested` / `AttestationRevoked`
events; the site only consumes it. Shape:

```json
{
  "generatedAt": "2026-11-26T00:00:00Z",
  "block": 12345678,
  "events": [
    {
      "type": "attested",
      "issuerHandle": "alice",
      "subjectHandle": "bob",
      "category": 0,
      "evidenceHash": "0x…",
      "txHash": "0x…",
      "block": 12345678,
      "timestamp": 1760000000,
      "isUpdate": false
    }
  ]
}
```

Events are newest-first. `type` is `"attested"` or `"revoked"`. Pages treat an
empty or missing snapshot as a graceful empty state. Live counters on
index.html / graph.html and the per-category counts on profile.html are read
directly from the contract and do not depend on the snapshot.

## Run locally

```sh
cd site
python3 -m http.server 8077
# open http://localhost:8077/
```

Any static file server works. To test against a fork deployment, copy the
site, point that copy's `config.js` at the fork (address + RPC list), and
serve the copy — never edit the real `config.js` for tests.

## Notes

- Profile pages are keyed by handle and never display raw wallet addresses.
  The given-count lookup resolves the handle to an address internally via the
  registry; the address is used for one `eth_call` and never rendered.
- Copy uses factual counts only ("attestations received") — never scores,
  ratings, or rankings-as-judgment.
- Keccak-256 in `assets/app.js` is the original Keccak padding (0x01…0x80),
  not SHA3-256. Sanity: `keccak256("")` =
  `0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470`.
