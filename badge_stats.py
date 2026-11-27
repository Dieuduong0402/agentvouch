#!/usr/bin/env python3
"""VouchBadge stats — daily Space snapshot (user order 00:20 27/11).

Reads the VouchBadge contract on BSC and emits the numbers the Space shows
every day:
  - total wallets that minted the badge (totalMinted + Transfer events)
  - tier distribution 0..4 (badgeTier is computed live from the AgentVouch
    graph, so tiers are re-read for EVERY known holder on every run)
  - newest minters (handle + tier)

Sources (public on-chain data only — wallet address + handle + tier):
  badge    0xed4d84A891EA97aAb5D412cd36035dd7aA7BF2b9 (deploy block 135884701)
  registry 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F (handleOf)
  vouch    0x93271C060aC7f3432921Ae6225027aa5B2538E99 (read via badgeTier)

RPC notes (measured 26/11): Binance dataseeds throttle eth_getLogs with
-32005, so publicnode is FIRST for logs; dataseeds are fallback only, with
a smaller chunk. publicnode rejects eth_getLogs ranges > 10,000 blocks —
chunks are 9,500 by default, halved on failure. Every RPC call (logs AND
reads) rotates the whole pool on failure — a single hiccup must never kill
a run (lesson 27/11: ChunkedEncodingError on publicnode mid-run).

State (resumable): badge_stats_state.json keeps lastScannedBlock + the
holder map {address: {tokenId, firstSeenBlock, firstSeenTx, handle}}.
Handles are immutable — fetched once, cached forever. Tiers are NOT cached.
totalMinted is read AT to_block, not "latest": the chain keeps minting
while this script runs, and a later read would false-alarm a mismatch.

Outputs (rewritten every run):
  badge_stats.json         — full snapshot (machine-readable)
  badge_stats_summary.txt  — 3-line compact block for the Space (user rule
                             00:25 27/11: own section "Badge mint — người
                             dùng", NEVER inside progress cards; one idea
                             per line, no long paragraphs)

Usage:
  python3 badge_stats.py [--rescan] [--to-block N] [--chunk N]
"""
import argparse
import json
import os
import sys
from datetime import datetime, timezone

from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware  # web3 8.x PoA middleware

BADGE = Web3.to_checksum_address("0xed4d84A891EA97aAb5D412cd36035dd7aA7BF2b9")
REGISTRY = Web3.to_checksum_address("0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F")
DEPLOY_BLOCK = 135884701

TRANSFER_TOPIC = "0x" + Web3.keccak(
    text="Transfer(address,address,uint256)").hex()
ZERO_TOPIC = "0x" + "00" * 32  # from == address(0) => mint

DEFAULT_RPCS = [
    "https://bsc.publicnode.com",          # first: logs work here
    "https://bsc-dataseed2.binance.org",
    "https://bsc-dataseed1.binance.org",
    "https://bsc-dataseed.binance.org",
    "https://rpc-bsc.48.club",
]

TIER_NAMES = {
    0: "Member",
    1: "Contributor",
    2: "Trusted",
    3: "Well-Regarded",
    4: "Highly Trusted",
}

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_PATH = os.path.join(HERE, "badge_stats_state.json")
OUT_PATH = os.path.join(HERE, "badge_stats.json")
SUMMARY_PATH = os.path.join(HERE, "badge_stats_summary.txt")


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def connect(url, timeout=15):
    w3 = Web3(Web3.HTTPProvider(url, request_kwargs={"timeout": timeout}))
    w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
    return w3


class RpcPool:
    """Rotating pool: every call tries endpoints in order, sticks to the
    one that works. A single endpoint hiccup never kills a run."""

    def __init__(self, urls):
        self.urls = urls
        self.idx = 0

    def _try(self, label, fn):
        last_exc = None
        for attempt in range(len(self.urls)):
            idx = (self.idx + attempt) % len(self.urls)
            try:
                result = fn(connect(self.urls[idx]))
                self.idx = idx  # stick with the working endpoint
                return result
            except Exception as exc:  # noqa: BLE001 - rotation must catch all
                last_exc = exc
                print(f"WARN: {self.urls[idx]} {label} failed: {exc!r} — "
                      f"rotating", file=sys.stderr)
        raise RuntimeError(f"all RPCs failed on {label}: {last_exc!r}")

    def block_number(self):
        return self._try("block_number", lambda w3: w3.eth.block_number)

    def get_logs(self, params):
        return self._try("get_logs", lambda w3: w3.eth.get_logs(params))

    def eth_call(self, to, data, block="latest"):
        return bytes(self._try(
            "eth_call", lambda w3: w3.eth.call({"to": to, "data": data}, block)))


def _uint256_from_call(pool, to, selector_text, arg_addr=None, block="latest"):
    data = Web3.keccak(text=selector_text)[:4]
    if arg_addr is not None:
        data += bytes.fromhex(arg_addr[2:].rjust(64, "0"))
    return int.from_bytes(pool.eth_call(to, data, block), "big")


def main() -> int:
    ap = argparse.ArgumentParser(description="VouchBadge daily stats")
    ap.add_argument("--rescan", action="store_true",
                    help="ignore state, rebuild holder list from deploy block")
    ap.add_argument("--to-block", type=int, default=None)
    ap.add_argument("--chunk", type=int, default=9500,
                    help="blocks per eth_getLogs call (max 10000 on publicnode)")
    args = ap.parse_args()

    pool = RpcPool(DEFAULT_RPCS)
    state = {} if args.rescan else load_json(STATE_PATH, {})
    holders = state.get("holders", {})  # addr -> {tokenId, firstSeenBlock, firstSeenTx, handle}
    from_block = DEPLOY_BLOCK if args.rescan or not state.get("lastScannedBlock") \
        else state["lastScannedBlock"] + 1

    latest = pool.block_number()
    to_block = args.to_block if args.to_block is not None else latest

    # --- Scan Transfer mints (from == 0x0) in chunks; shrink chunk on error.
    new_mints = 0
    chunk = args.chunk
    lo = from_block
    while lo <= to_block:
        hi = min(lo + chunk - 1, to_block)
        try:
            logs = pool.get_logs({
                "address": BADGE,
                "fromBlock": Web3.to_hex(lo),
                "toBlock": Web3.to_hex(hi),
                "topics": [TRANSFER_TOPIC, ZERO_TOPIC, None],
            })
        except RuntimeError as exc:
            if chunk <= 1000:
                print(f"ERROR: logs {lo}..{hi} failed on all RPCs: {exc!r}; "
                      f"state NOT advanced past {lo - 1}", file=sys.stderr)
                return 1
            chunk = max(1000, chunk // 2)
            print(f"WARN: halving log chunk to {chunk} and retrying",
                  file=sys.stderr)
            continue
        for log in logs:
            topics = log["topics"]
            if len(topics) < 4:
                continue
            to_addr = Web3.to_checksum_address("0x" + topics[2].hex()[-40:])
            token_id = int(topics[3].hex(), 16)
            key = to_addr.lower()
            if key not in holders:
                holders[key] = {
                    "address": to_addr,
                    "tokenId": token_id,
                    "firstSeenBlock": log["blockNumber"],
                    "firstSeenTx": "0x" + log["transactionHash"].hex(),
                    "handle": None,
                }
                new_mints += 1
        lo = hi + 1
    print(f"scanned blocks {from_block}..{to_block} via "
          f"{pool.urls[pool.idx]}: {new_mints} new mint(s)", file=sys.stderr)

    # --- Cross-check totalMinted() AT to_block, then re-read tiers + handles.
    total_minted = _uint256_from_call(pool, BADGE, "totalMinted()",
                                      block=to_block)
    tier_dist = {0: 0, 1: 0, 2: 0, 3: 0, 4: 0}
    for key, h in holders.items():
        addr = h["address"]
        tier = _uint256_from_call(pool, BADGE, "badgeTier(address)", addr) & 0xFF
        h["tier"] = tier
        h["tierName"] = TIER_NAMES.get(tier, "?")
        tier_dist[tier] = tier_dist.get(tier, 0) + 1
        # handle: cached forever (registry handles are immutable)
        if not h.get("handle"):
            raw = pool.eth_call(
                REGISTRY,
                Web3.keccak(text="handleOf(address)")[:4]
                + bytes.fromhex(addr[2:].rjust(64, "0")))
            from eth_abi import decode as abi_decode
            try:
                handle = abi_decode(["string"], raw)[0]
            except Exception:  # noqa: BLE001
                handle = ""
            h["handle"] = handle or None

    holders_sorted = sorted(holders.values(),
                            key=lambda h: (h["firstSeenBlock"], h["tokenId"]))
    newest = list(reversed(holders_sorted))[:5]
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    snapshot = {
        "generatedAt": generated_at,
        "contract": BADGE,
        "scannedToBlock": to_block,
        "totalMinted": total_minted,
        "totalHolders": len(holders),
        "eventHoldersMismatch": total_minted != len(holders),
        "tierDistribution": {str(k): v for k, v in sorted(tier_dist.items())},
        "holders": holders_sorted,
        "newestMinters": newest,
    }
    save_json(OUT_PATH, snapshot)
    state["lastScannedBlock"] = to_block
    state["holders"] = holders
    save_json(STATE_PATH, state)

    # Compact 3-line block (user rule 00:25 27/11): shown in the Space's OWN
    # section "Badge mint — người dùng", never inside progress cards.
    # One idea per line, no long paragraphs.
    dist_str = " · ".join(f"{TIER_NAMES[t]} {tier_dist[t]}" for t in range(5))
    if newest:
        newest_str = " · ".join(
            f"{h['handle'] or h['address'][:10]} (#{h['tokenId']})"
            for h in newest)
    else:
        newest_str = "chưa có"
    summary = (
        f"Tổng minters: {len(holders)} ví\n"
        f"Tier: {dist_str}\n"
        f"Mới nhất: {newest_str}"
    )
    if snapshot["eventHoldersMismatch"]:
        summary += (f"\nCẢNH BÁO: totalMinted ({total_minted}) khác số holder "
                    f"quét được ({len(holders)}) — kiểm tra lại log scan.")
    with open(SUMMARY_PATH, "w") as f:
        f.write(summary + "\n")

    print(json.dumps({
        "totalMinted": total_minted,
        "totalHolders": len(holders),
        "tierDistribution": tier_dist,
        "newMintsThisRun": new_mints,
        "scannedToBlock": to_block,
    }, indent=2, sort_keys=True))
    print(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
