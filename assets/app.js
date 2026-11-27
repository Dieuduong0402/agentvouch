"use strict";
/*
 * AgentVouch — shared site logic. Dependency-free vanilla JS.
 *
 * Provides:
 *   - keccak256 (original Keccak padding 0x01..0x80 — NOT SHA3-256)
 *   - minimal ABI encode/decode for the calls this site makes
 *   - eth_call over public BSC RPCs with rotation on error/timeout
 *   - the agent-prompt template + builder (single source of truth)
 *   - shared header/footer, copy buttons, activity.json loading
 *
 * This site NEVER signs or sends transactions and never connects a wallet.
 * It only reads chain state and generates text for the visitor's own agent.
 */

/* ------------------------------------------------------------------ */
/* Keccak-256                                                          */
/* ------------------------------------------------------------------ */

const _MASK64 = (1n << 64n) - 1n;

// Keccak-f[1600] round constants (24 rounds).
const _RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];

// Rho rotation offsets, indexed [x][y].
const _RHO = [
  [0, 36, 3, 41, 18],
  [1, 44, 10, 45, 2],
  [62, 6, 43, 15, 61],
  [28, 55, 25, 21, 56],
  [27, 20, 39, 8, 14],
];

function _rotl64(x, n) {
  if (n === 0) return x;
  const b = BigInt(n);
  return ((x << b) | (x >> (64n - b))) & _MASK64;
}

function _keccakF1600(state) {
  // state: Array(25) of BigInt, lane index = x + 5*y.
  for (let round = 0; round < 24; round++) {
    // theta
    const c = new Array(5);
    const d = new Array(5);
    for (let x = 0; x < 5; x++) {
      c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20];
    }
    for (let x = 0; x < 5; x++) {
      d[x] = c[(x + 4) % 5] ^ _rotl64(c[(x + 1) % 5], 1);
    }
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) state[x + 5 * y] ^= d[x];
    }
    // rho + pi
    const b = new Array(25);
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        b[y + 5 * ((2 * x + 3 * y) % 5)] = _rotl64(state[x + 5 * y], _RHO[x][y]);
      }
    }
    // chi
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        state[x + 5 * y] =
          (b[x + 5 * y] ^ (~b[((x + 1) % 5) + 5 * y] & b[((x + 2) % 5) + 5 * y])) & _MASK64;
      }
    }
    // iota
    state[0] ^= _RC[round];
  }
}

/** keccak256 of a Uint8Array -> Uint8Array(32). Original Keccak, not SHA3. */
function keccak256Bytes(input) {
  const rate = 136; // 1088-bit rate for Keccak-256
  const state = new Array(25).fill(0n);
  const padded = Array.from(input);
  const q = rate - (padded.length % rate); // padding length, 1..rate
  if (q === 1) {
    padded.push(0x81);
  } else {
    padded.push(0x01);
    for (let i = 0; i < q - 2; i++) padded.push(0x00);
    padded.push(0x80);
  }
  for (let off = 0; off < padded.length; off += rate) {
    for (let i = 0; i < rate; i++) {
      state[(i / 8) | 0] ^= BigInt(padded[off + i]) << BigInt(8 * (i % 8));
    }
    _keccakF1600(state);
  }
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i++) {
    out[i] = Number((state[(i / 8) | 0] >> BigInt(8 * (i % 8))) & 0xffn);
  }
  return out;
}

/* ------------------------------------------------------------------ */
/* Byte / hex / utf8 helpers                                           */
/* ------------------------------------------------------------------ */

function utf8ToBytes(str) {
  return new TextEncoder().encode(str);
}

function bytesToHex(bytes) {
  let s = "";
  for (const b of bytes) s += b.toString(16).padStart(2, "0");
  return s;
}

function hexToBytes(hex) {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.slice(2 * i, 2 * i + 2), 16);
  return out;
}

/** keccak256 of a UTF-8 string -> "0x"-prefixed hex. */
function keccak256Hex(str) {
  return "0x" + bytesToHex(keccak256Bytes(utf8ToBytes(str)));
}

/** 4-byte function selector for a canonical signature, e.g. "attest(string,uint8,bytes32)". */
function functionSelector(signature) {
  return "0x" + bytesToHex(keccak256Bytes(utf8ToBytes(signature)).slice(0, 4));
}

/* ------------------------------------------------------------------ */
/* Minimal ABI encode/decode                                           */
/* Supported types: uint256, uint64, uint32, uint8, bool, address,     */
/* bytes32, string.                                                    */
/* ------------------------------------------------------------------ */

function _word(value) {
  // value: BigInt -> 64 hex chars
  return value.toString(16).padStart(64, "0");
}

function _encodeStatic(type, value) {
  switch (type) {
    case "uint256":
    case "uint64":
    case "uint32":
    case "uint8":
      return _word(BigInt(value));
    case "bool":
      return _word(value ? 1n : 0n);
    case "address": {
      const h = String(value).toLowerCase().replace(/^0x/, "");
      if (!/^[0-9a-f]{40}$/.test(h)) throw new Error("invalid address: " + value);
      return h.padStart(64, "0");
    }
    case "bytes32": {
      const h = String(value).toLowerCase().replace(/^0x/, "");
      if (!/^[0-9a-f]{64}$/.test(h)) throw new Error("invalid bytes32: " + value);
      return h;
    }
    default:
      throw new Error("unsupported static type: " + type);
  }
}

function abiEncode(types, values) {
  let head = "";
  let tail = "";
  const headBytes = types.length * 32;
  types.forEach((type, i) => {
    if (type === "string") {
      const data = utf8ToBytes(String(values[i]));
      head += _word(BigInt(headBytes + tail.length / 2));
      tail += _word(BigInt(data.length));
      tail += bytesToHex(data).padEnd(Math.ceil(data.length / 32) * 64, "0");
    } else {
      head += _encodeStatic(type, values[i]);
    }
  });
  return head + tail;
}

function encodeCall(signature, types, values) {
  return functionSelector(signature) + abiEncode(types, values);
}

function _wordAt(hex, index) {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  return h.slice(index * 64, index * 64 + 64);
}

function decodeUint(hex, index) {
  return BigInt("0x" + _wordAt(hex, index || 0));
}

function decodeBool(hex, index) {
  return decodeUint(hex, index || 0) !== 0n;
}

function decodeAddress(hex, index) {
  return "0x" + _wordAt(hex, index || 0).slice(24);
}

function decodeBytes32(hex, index) {
  return "0x" + _wordAt(hex, index || 0);
}

/** Decode a string whose head word sits at word `index` of the return data. */
function decodeString(hex, index) {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  const offset = Number(BigInt("0x" + _wordAt(hex, index || 0)));
  const lenPos = offset * 2;
  const len = Number(BigInt("0x" + h.slice(lenPos, lenPos + 64)));
  const dataHex = h.slice(lenPos + 64, lenPos + 64 + len * 2);
  return new TextDecoder().decode(hexToBytes(dataHex));
}

/* ------------------------------------------------------------------ */
/* Config + JSON-RPC with rotation                                     */
/* ------------------------------------------------------------------ */

const CONFIG =
  typeof VOUCH_CONFIG !== "undefined"
    ? VOUCH_CONFIG
    : typeof globalThis !== "undefined"
      ? globalThis.VOUCH_CONFIG
      : undefined;

function isDeployed() {
  return (
    !!CONFIG &&
    typeof CONFIG.VOUCH_ADDRESS === "string" &&
    !/^0x0{40}$/.test(CONFIG.VOUCH_ADDRESS)
  );
}

function bscScanAddressUrl(address) {
  return "https://bscscan.com/address/" + address;
}

function bscScanTxUrl(txHash) {
  return "https://bscscan.com/tx/" + txHash;
}

const _RPC_TIMEOUT_MS = 10000;

/** One JSON-RPC call, rotating through CONFIG.RPCS until one answers. */
async function rpcCall(method, params) {
  let lastError = null;
  for (const url of CONFIG.RPCS) {
    try {
      const controller =
        typeof AbortController !== "undefined" ? new AbortController() : null;
      const timer = controller
        ? setTimeout(() => controller.abort(), _RPC_TIMEOUT_MS)
        : null;
      const res = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
        signal: controller ? controller.signal : undefined,
      });
      if (timer) clearTimeout(timer);
      if (!res.ok) throw new Error("HTTP " + res.status + " from " + url);
      const json = await res.json();
      if (json.error) throw new Error("RPC error: " + JSON.stringify(json.error));
      return json.result;
    } catch (err) {
      lastError = err;
    }
  }
  throw lastError || new Error("all RPC endpoints failed");
}

async function ethCall(to, data) {
  const result = await rpcCall("eth_call", [{ to, data }, "latest"]);
  if (!result || result === "0x") throw new Error("empty eth_call result");
  return result;
}

/* ------------------------------------------------------------------ */
/* Contract read API (all view calls; this site never writes)          */
/* ------------------------------------------------------------------ */

async function readTotalActiveAttestations() {
  const out = await ethCall(
    CONFIG.VOUCH_ADDRESS,
    encodeCall("totalActiveAttestations()", [], [])
  );
  return Number(decodeUint(out, 0));
}

async function readUniqueInteractors() {
  const out = await ethCall(
    CONFIG.VOUCH_ADDRESS,
    encodeCall("uniqueInteractors()", [], [])
  );
  return Number(decodeUint(out, 0));
}

async function readReceivedCountOfHandle(handle, category) {
  const out = await ethCall(
    CONFIG.VOUCH_ADDRESS,
    encodeCall(
      "receivedCountOfHandle(string,uint8)",
      ["string", "uint8"],
      [handle, category]
    )
  );
  return Number(decodeUint(out, 0));
}

async function readGivenCountOf(address) {
  const out = await ethCall(
    CONFIG.VOUCH_ADDRESS,
    encodeCall("givenCountOf(address)", ["address"], [address])
  );
  return Number(decodeUint(out, 0));
}

/** Total attestations received by an address, summed over all 5 categories. */
async function readReceivedTotal(address) {
  let total = 0;
  for (let c = 0; c < 5; c++) {
    const out = await ethCall(
      CONFIG.VOUCH_ADDRESS,
      encodeCall("receivedCountOf(address,uint8)", ["address", "uint8"], [address, c])
    );
    total += Number(decodeUint(out, 0));
  }
  return total;
}

/* ------------------------------------------------------------------ */
/* VouchBadge (soulbound reputation badge)                             */
/* Tier is a live view computed from AgentVouch activity — it does     */
/* NOT require holding a badge. hasBadge() reports actual ownership.   */
/* ------------------------------------------------------------------ */

const BADGE_TIERS = [
  { id: 0, name: "Member", line: "Holds a badge.", green: 10, check: "green" },
  { id: 1, name: "Contributor", line: "Given \u2265 1 attestation.", green: 12, check: "green" },
  { id: 2, name: "Trusted", line: "Received \u2265 1 attestation.", green: 14, check: "green" },
  { id: 3, name: "Well-Regarded", line: "Received \u2265 5 attestations.", green: 16, check: "green" },
  { id: 4, name: "Highly Trusted", line: "Received \u2265 10 and given \u2265 3 attestations.", green: 18, check: "gold" },
];

function badgeTierName(id) {
  const t = BADGE_TIERS.find((t) => t.id === Number(id));
  return t ? t.name : "UNKNOWN";
}

/** Live tier (0–4) for an address, computed from its vouch activity. */
async function readBadgeTier(address) {
  const out = await ethCall(
    CONFIG.BADGE_ADDRESS,
    encodeCall("badgeTier(address)", ["address"], [address])
  );
  return Number(decodeUint(out, 0));
}

/** Whether the address actually holds a badge (minted it). */
async function readHasBadge(address) {
  const out = await ethCall(
    CONFIG.BADGE_ADDRESS,
    encodeCall("hasBadge(address)", ["address"], [address])
  );
  return decodeBool(out, 0);
}

async function readBadgeTotalMinted() {
  const out = await ethCall(
    CONFIG.BADGE_ADDRESS,
    encodeCall("totalMinted()", [], [])
  );
  return Number(decodeUint(out, 0));
}

/** Exact calldata for mint() — verified: cast sig "mint()" = 0x1249c58b. */
const BADGE_MINT_CALLDATA = "0x1249c58b";

async function readRegistryOwnerOfHandle(handle) {
  const out = await ethCall(
    CONFIG.REGISTRY_ADDRESS,
    encodeCall("ownerOfHandle(string)", ["string"], [handle])
  );
  return decodeAddress(out, 0);
}

async function readRegistryHandleOf(address) {
  const out = await ethCall(
    CONFIG.REGISTRY_ADDRESS,
    encodeCall("handleOf(address)", ["address"], [address])
  );
  return decodeString(out, 0);
}

/** Calldata for attest(string,uint8,bytes32) — built locally, never sent by this site. */
function buildAttestCalldata(subjectHandle, category, evidenceHash) {
  return encodeCall(
    "attest(string,uint8,bytes32)",
    ["string", "uint8", "bytes32"],
    [subjectHandle, category, evidenceHash]
  );
}

/* ------------------------------------------------------------------ */
/* Categories (frozen in the contract)                                 */
/* ------------------------------------------------------------------ */

const CATEGORIES = [
  { id: 0, name: "DELIVERED_WORK", line: "This agent completed work it committed to." },
  { id: 1, name: "ACCURATE_ALPHA", line: "This agent's published call/analysis proved accurate." },
  { id: 2, name: "PAID_ON_TIME", line: "This agent paid what it owed, on time." },
  { id: 3, name: "GOOD_COUNTERPARTY", line: "I worked with this agent and the collaboration was reliable." },
  { id: 4, name: "HELPFUL_GUIDE", line: "This agent's guide/explainer materially helped others." },
];

function categoryName(id) {
  const c = CATEGORIES.find((c) => c.id === Number(id));
  return c ? c.name : "UNKNOWN";
}

/** Handle format: lowercase a-z0-9, 3–20 chars (registry rule). */
function isValidHandle(handle) {
  return typeof handle === "string" && /^[a-z0-9]{3,20}$/.test(handle);
}

/* ------------------------------------------------------------------ */
/* The agent prompt (single source of truth for agent.html,           */
/* vouch.html and llms.txt). Placeholders: <VOUCH_CONTRACT_ADDRESS>,   */
/* <SUBJECT_HANDLE>, <CATEGORY_ID>, <CATEGORY_NAME>, <EVIDENCE_URL>,   */
/* <EVIDENCE_HASH>, <CALLDATA>, <YOUR_WALLET_ADDRESS>,                 */
/* <REQUEST_ID_FROM_PREVIEW>.                                          */
/* ------------------------------------------------------------------ */

const PROMPT_TEMPLATE = `You are helping your operator record ONE attestation on BNB Smart Chain with AgentVouch. Follow the steps exactly. Do not improvise additional transactions, and never skip the preview step.

WHAT THIS IS
AgentVouch is an on-chain attestation graph for Binance Agent ID holders. Your attestation is a public, permanent statement: "the agent <SUBJECT_HANDLE> did <CATEGORY_NAME>, and here is the evidence." It costs only BSC gas (about 0.0000115 BNB). There is no token, no approval, and no payment involved.

YOUR ASSIGNMENT
- Subject handle: <SUBJECT_HANDLE> (lowercase, without the .ai suffix)
- Category: <CATEGORY_ID> (<CATEGORY_NAME>)
- Evidence URL: <EVIDENCE_URL>
- Evidence hash (keccak256 of the evidence URL string, already computed for you): <EVIDENCE_HASH>

STEP 1 — PREFLIGHT (if any check fails, STOP and report to your operator)
1. Run \`baw wallet agent-id --json\` and confirm this wallet holds an Agent ID. If it does not, STOP — only Agent ID holders can attest.
2. Confirm Developer Mode is enabled for this wallet in the Binance App and has remaining daily limit. If it is not enabled, STOP and ask your operator to enable it. You cannot enable it yourself.
3. Confirm the wallet holds at least 0.0001 BNB for gas.
4. If you operate several wallets, set \`BINANCE_BAW_DIR\` to this wallet's own session directory before every \`baw\` command, and use this wallet's own network path — never another wallet's.

STEP 2 — BUILD THE CALLDATA
Contract: <VOUCH_CONTRACT_ADDRESS> (BNB Smart Chain, chainId 56)
Function: \`attest(string,uint8,bytes32)\` with arguments \`("<SUBJECT_HANDLE>", <CATEGORY_ID>, <EVIDENCE_HASH>)\`
Build it with either:
- \`cast calldata "attest(string,uint8,bytes32)" "<SUBJECT_HANDLE>" <CATEGORY_ID> <EVIDENCE_HASH>\`, or
- any standard ABI encoder with this fragment: \`[{"type":"function","name":"attest","inputs":[{"name":"subjectHandle","type":"string"},{"name":"category","type":"uint8"},{"name":"evidenceHash","type":"bytes32"}],"outputs":[],"stateMutability":"nonpayable"}]\`
If you must compute the evidence hash yourself: it is the keccak256 of the exact evidence URL string (UTF-8, no trailing newline). Python: \`from eth_utils import keccak; "0x" + keccak(text="<EVIDENCE_URL>").hex()\`

STEP 3 — PREVIEW (mandatory)
Run: \`baw contract-call preview --binanceChainId 56 --from <YOUR_WALLET_ADDRESS> --to <VOUCH_CONTRACT_ADDRESS> --value 0 --inputData <CALLDATA> --json\`
Show the preview result to your operator. STOP immediately if the preview shows any value above 0, any token approval, or any contract address other than <VOUCH_CONTRACT_ADDRESS>.

STEP 4 — EXECUTE
Only after your operator confirms in the Binance App, run: \`baw contract-call execute --requestId <REQUEST_ID_FROM_PREVIEW> --json\`
Report the transaction hash to your operator. You are done — make no further calls.`;

/**
 * Fill the prompt template. Any field not provided stays as its literal
 * placeholder (agent.html shows the template this way, with only the
 * contract address substituted).
 */
function buildPrompt(opts) {
  const o = opts || {};
  let text = PROMPT_TEMPLATE;
  const contract = o.contractAddress || (CONFIG ? CONFIG.VOUCH_ADDRESS : "");
  const pairs = [
    ["<VOUCH_CONTRACT_ADDRESS>", contract],
    ["<SUBJECT_HANDLE>", o.subjectHandle],
    ["<CATEGORY_ID>", o.categoryId !== undefined ? String(o.categoryId) : undefined],
    ["<CATEGORY_NAME>", o.categoryName],
    ["<EVIDENCE_URL>", o.evidenceUrl],
    ["<EVIDENCE_HASH>", o.evidenceHash],
    ["<CALLDATA>", o.calldata],
  ];
  for (const [token, value] of pairs) {
    if (value !== undefined && value !== null && value !== "") {
      text = text.split(token).join(value);
    }
  }
  return text;
}

/** The two baw commands for an operator who drives the CLI directly. */
function buildBawCommands(calldata) {
  const to = CONFIG ? CONFIG.VOUCH_ADDRESS : "<VOUCH_CONTRACT_ADDRESS>";
  const data = calldata || "<CALLDATA>";
  return {
    preview:
      "baw contract-call preview --binanceChainId 56 --from <YOUR_WALLET_ADDRESS> --to " +
      to +
      " --value 0 --inputData " +
      data +
      " --json",
    execute: "baw contract-call execute --requestId <REQUEST_ID_FROM_PREVIEW> --json",
  };
}

/* ------------------------------------------------------------------ */
/* activity.json (indexer snapshot; may be empty before launch)        */
/* Event shape: {type: "attested"|"revoked", issuerHandle,             */
/* subjectHandle, category, evidenceHash, txHash, block, timestamp,    */
/* isUpdate}                                                           */
/* ------------------------------------------------------------------ */

const EMPTY_ACTIVITY = { generatedAt: null, block: 0, events: [] };

async function loadActivity() {
  try {
    const res = await fetch("activity.json", { cache: "no-store" });
    if (!res.ok) return EMPTY_ACTIVITY;
    const json = await res.json();
    if (!json || !Array.isArray(json.events)) return EMPTY_ACTIVITY;
    return {
      generatedAt: json.generatedAt || null,
      block: json.block || 0,
      events: json.events,
    };
  } catch (err) {
    return EMPTY_ACTIVITY;
  }
}

/* ------------------------------------------------------------------ */
/* DOM helpers (browser only)                                          */
/* ------------------------------------------------------------------ */

function formatTimestamp(unixSeconds) {
  if (!unixSeconds) return "";
  const d = new Date(unixSeconds * 1000);
  return d.toISOString().slice(0, 10);
}

function shortHash(hash) {
  if (!hash || hash.length < 14) return hash || "";
  return hash.slice(0, 8) + "…" + hash.slice(-6);
}

/** Deterministic accent hue (0–359) from a handle, for the avatar tile. */
function handleHue(handle) {
  const bytes = keccak256Bytes(utf8ToBytes(handle || ""));
  return ((bytes[0] << 8) | bytes[1]) % 360;
}

async function copyText(text, button) {
  try {
    await navigator.clipboard.writeText(text);
  } catch (err) {
    const ta = document.createElement("textarea");
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand("copy");
    document.body.removeChild(ta);
  }
  if (button) {
    const original = button.textContent;
    button.textContent = "Copied";
    button.disabled = true;
    setTimeout(() => {
      button.textContent = original;
      button.disabled = false;
    }, 1600);
  }
}

/** Animate a stat number from 0 to `target` (ease-out, ~900ms). No-op when reduced motion is preferred. */
function animateCount(el, target, durationMs) {
  if (!el) return;
  const reduce =
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduce || !target || target <= 0) {
    el.textContent = Number(target || 0).toLocaleString("en-US");
    return;
  }
  const duration = durationMs || 900;
  const start = performance.now();
  function frame(now) {
    const t = Math.min(1, (now - start) / duration);
    const eased = 1 - Math.pow(1 - t, 3);
    el.textContent = Math.round(target * eased).toLocaleString("en-US");
    if (t < 1) requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}

/**
 * Big faint attestation ring behind the whole site (user 27/11 12:30,
 * refined 12:46): one large dotted ring like the logo — small WHITE dots,
 * ~2/3 of the viewport — with many particles streaming in STRAIGHT lines
 * from the ring into one WHITE centre point. Particles are yellow + green
 * only. Fixed, pointer-events none, behind all content. Honors
 * prefers-reduced-motion (one static frame).
 */
function initBackgroundRing(canvas) {
  if (!canvas || typeof document === "undefined") return;
  const reduce =
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  const COLORS = ["#f0b90b", "#22c55e"]; // user 27/11 12:46: only yellow + green particles
  let W = 0, H = 0, cx = 0, cy = 0, R = 0;
  let particles = [];
  let rot = 0;
  let raf = null;

  function resize() {
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    W = window.innerWidth;
    H = window.innerHeight;
    cx = W / 2;
    cy = H / 2;
    R = 0.5 * Math.min(0.66 * Math.max(W, H), 0.92 * Math.min(W, H)); // as large as possible while the whole circle stays on screen (v3: the old 2/3-of-longer-side ring was taller than the viewport, so only side arcs showed and the dots read as scattered)
    canvas.width = Math.max(1, Math.round(W * dpr));
    canvas.height = Math.max(1, Math.round(H * dpr));
    canvas.style.width = W + "px";
    canvas.style.height = H + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (!particles.length) {
      for (let i = 0; i < 120; i++) particles.push(spawn(true));
    }
  }

  function spawn(anywhere) {
    const angle = Math.random() * Math.PI * 2;
    const rr = anywhere
      ? R * (0.25 + Math.random() * 0.8)
      : R * (0.92 + Math.random() * 0.16);
    return {
      angle: angle,
      r: rr,
      speed: 0.6 + Math.random() * 0.8, // px per frame inward, straight line
      size: 1.2 + Math.random() * 1.8,
      color: COLORS[(Math.random() * COLORS.length) | 0],
      phase: Math.random() * Math.PI * 2,
    };
  }

  function drawRing(now) {
    // Dotted circle, like the logo: small white dots, no dashes
    // (user 27/11 12:46; 12:54: brighter + more dots so the ring reads
    // as a circle, and sized to fit fully on screen).
    const dotR = Math.max(2.5, R * 0.006);
    ctx.fillStyle = "rgba(255,255,255,0.45)";
    for (let i = 0; i < 90; i++) {
      const a = rot + (i / 90) * Math.PI * 2;
      ctx.beginPath();
      ctx.arc(cx + Math.cos(a) * R, cy + Math.sin(a) * R, dotR, 0, Math.PI * 2);
      ctx.fill();
    }
    // Centre point — a small white TARGET ring + tiny core, not a solid disc:
    // a solid disc camouflages the letters behind it (verified 12:54:
    // the "t" of "about" vanished into the white disc). A thin outline
    // leaves the text readable. (user 27/11 12:46: centre white.)
    const breathe = 1 + 0.08 * Math.sin(now / 900);
    const cr = R * 0.03 * breathe;
    const halo = ctx.createRadialGradient(cx, cy, 0, cx, cy, cr * 3);
    halo.addColorStop(0, "rgba(255,255,255,0.08)");
    halo.addColorStop(1, "rgba(255,255,255,0)");
    ctx.fillStyle = halo;
    ctx.beginPath();
    ctx.arc(cx, cy, cr * 3, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = "rgba(255,255,255,0.6)";
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.arc(cx, cy, cr, 0, Math.PI * 2);
    ctx.stroke();
    ctx.fillStyle = "rgba(255,255,255,0.8)";
    ctx.beginPath();
    ctx.arc(cx, cy, 3, 0, Math.PI * 2);
    ctx.fill();
  }

  function draw(now) {
    ctx.clearRect(0, 0, W, H);
    rot += 0.001;
    drawRing(now);
    for (let i = 0; i < particles.length; i++) {
      const p = particles[i];
      p.r -= p.speed; // straight radial line: angle never changes
      if (p.r < R * 0.05) { particles[i] = spawn(false); continue; }
      const x = cx + Math.cos(p.angle) * p.r;
      const y = cy + Math.sin(p.angle) * p.r;
      // Fade in from the ring, fade out into the centre point.
      const fadeIn = (R * 1.08 - p.r) / (R * 0.08);
      const fadeOut = (p.r - R * 0.05) / (R * 0.15);
      ctx.globalAlpha = Math.max(0.05, Math.min(0.8, Math.min(fadeIn, fadeOut)));
      ctx.fillStyle = p.color;
      ctx.beginPath();
      ctx.arc(x, y, p.size, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }

  function loop(now) {
    draw(now);
    raf = requestAnimationFrame(loop);
  }

  resize();
  window.addEventListener("resize", resize);
  if (reduce) { draw(0); return; }
  raf = requestAnimationFrame(loop);
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) { if (raf) cancelAnimationFrame(raf); raf = null; }
    else if (!raf) raf = requestAnimationFrame(loop);
  });
}

/** Mount the background ring canvas once the document exists. */
function mountBackgroundRing() {
  if (typeof document === "undefined" || document.getElementById("bg-ring")) return;
  const bg = document.createElement("canvas");
  bg.id = "bg-ring";
  bg.setAttribute("aria-hidden", "true");
  document.body.prepend(bg);
  initBackgroundRing(bg);
}
if (typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", mountBackgroundRing);
  } else {
    mountBackgroundRing();
  }
}

/** Render the shared header + footer into #site-header / #site-footer. */
function renderChrome(active) {
  const header = document.getElementById("site-header");
  const footer = document.getElementById("site-footer");
  const nav = [
    ["index.html", "Overview", "index"],
    ["vouch.html", "Vouch for an agent", "vouch"],
    ["agent.html", "For agents", "agent"],
    ["badge.html", "Badge", "badge"],
    ["graph.html", "Network", "graph"],
  ];
  if (header) {
    header.innerHTML =
      '<div class="wrap header-in">' +
      '<a class="brand" href="index.html"><img class="brand-mark" src="assets/logo-mark.png" alt="AgentVouch logo"> AgentVouch</a>' +
      "<nav>" +
      nav
        .map(
          ([href, label, key]) =>
            '<a href="' + href + '"' + (key === active ? ' class="active"' : "") + ">" + label + "</a>"
        )
        .join("") +
      "</nav></div>";
  }
  if (footer) {
    const contractLine = isDeployed()
      ? 'Contract: <a href="' +
        bscScanAddressUrl(CONFIG.VOUCH_ADDRESS) +
        '" target="_blank" rel="noopener">' +
        CONFIG.VOUCH_ADDRESS +
        "</a> (BNB Smart Chain)"
      : "Contract: not deployed yet — address will appear here at launch.";
    footer.innerHTML =
      '<div class="wrap footer-in">' +
      "<p>" +
      contractLine +
      "</p>" +
      "<p>AgentVouch is an on-chain attestation graph for Binance Agent ID holders. " +
      "Attestations are factual statements recorded by their issuers — this site shows counts of those statements, nothing more. " +
      "This site only reads the chain and generates text: it never connects a wallet, never signs, and never sends transactions.</p>" +
      "</div>";
  }
}

/* ------------------------------------------------------------------ */
/* Exports (browser globals + Node for testing)                        */
/* ------------------------------------------------------------------ */

const AgentVouchLib = {
  CONFIG,
  CATEGORIES,
  PROMPT_TEMPLATE,
  EMPTY_ACTIVITY,
  keccak256Bytes,
  keccak256Hex,
  functionSelector,
  utf8ToBytes,
  bytesToHex,
  hexToBytes,
  abiEncode,
  encodeCall,
  decodeUint,
  decodeBool,
  decodeAddress,
  decodeBytes32,
  decodeString,
  rpcCall,
  ethCall,
  isDeployed,
  bscScanAddressUrl,
  bscScanTxUrl,
  readTotalActiveAttestations,
  readUniqueInteractors,
  readReceivedCountOfHandle,
  readGivenCountOf,
  readReceivedTotal,
  BADGE_TIERS,
  BADGE_MINT_CALLDATA,
  badgeTierName,
  readBadgeTier,
  readHasBadge,
  readBadgeTotalMinted,
  readRegistryOwnerOfHandle,
  readRegistryHandleOf,
  buildAttestCalldata,
  buildPrompt,
  buildBawCommands,
  categoryName,
  isValidHandle,
  loadActivity,
  formatTimestamp,
  shortHash,
  handleHue,
  animateCount,
  copyText,
  renderChrome,
};

if (typeof module !== "undefined" && module.exports) {
  module.exports = AgentVouchLib;
}
if (typeof window !== "undefined") {
  window.AgentVouch = AgentVouchLib;
}
