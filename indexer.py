#!/usr/bin/env python3
"""AgentVouch indexer — DESIGN.md §4.3.

Reads Attested / AttestationRevoked events from the AgentVouch contract and
emits the static snapshot the site consumes:

  activity.json — all events, NEWEST FIRST, with block + generation time
                  (graph.html's latest-per-triple logic assumes newest-first)
  evidence.json — evidenceHash -> URL, but ONLY for URLs whose keccak256
                  matches the on-chain hash (hash-gated, §3.3)

The indexer also reconstructs the contract counters from events ALONE
(totalActiveAttestations, uniqueInteractors, per-category received counts,
per-handle given/received) and prints them as JSON on stdout, so the daily
run can cross-check them against the contract's own view calls (§5.7).

Properties:
  - chunked eth_getLogs (default 10,000-block chunks), RPC rotation on
    error/timeout (same fallback list as site/config.js);
  - idempotent + resumable: a state file records the last scanned block and
    a block->timestamp cache; a re-run scans only new blocks and merges into
    the existing activity.json (dedupe by txHash+logIndex);
  - no writes to the chain, no secrets, no proxy/credential handling.

Usage:
  python3 indexer.py --contract 0x... --from-block 123456 \
      --out-dir ~/workspace/vouch/site \
      --evidence-map evidence-map.json \
      [--rpc https://bsc-dataseed.binance.org ...] [--chunk 10000]
  python3 indexer.py --contract 0x... --rescan   # rebuild from --from-block
"""
import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone

from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware  # web3 8.x PoA middleware (was geth_poa_middleware)

# keccak256 of the two event signatures (DESIGN.md §2.6).
# NOTE: Web3.keccak(...).hex() returns BARE hex (no 0x) — the RPC rejects
# bare-hex topics with -32602, so prefix explicitly (bug found on first
# mainnet run, 26/11: D7 anvil tests never caught it).
ATTESTED_TOPIC = "0x" + Web3.keccak(
    text="Attested(bytes32,bytes32,uint8,address,address,string,string,bytes32,bool)"
).hex()
REVOKED_TOPIC = "0x" + Web3.keccak(
    text="AttestationRevoked(bytes32,bytes32,uint8,address,address,string,string)"
).hex()

DEFAULT_RPCS = [
    "https://bsc-dataseed.binance.org",
    "https://bsc-dataseed1.binance.org",
    "https://bsc-dataseed2.binance.org",
    "https://bsc.publicnode.com",
    "https://rpc-bsc.48.club",
]

# eth_abi is a web3 dependency; decode the non-indexed event data with it.
from eth_abi import decode as abi_decode  # noqa: E402


def keccak256_hex(text: str) -> str:
    """keccak256 of the exact UTF-8 string — same rule as the site (§3.1).

    NOTE: hashlib.sha3_256 is NIST SHA-3, NOT keccak256 — never use it here.
    """
    return "0x" + Web3.keccak(text=text).hex()


def _hexstr(value) -> str:
    """Hex string with 0x prefix, whether the input is HexBytes or str."""
    if isinstance(value, (bytes, bytearray)):
        return "0x" + bytes(value).hex()
    s = str(value)
    return s if s.startswith("0x") else "0x" + s


def decode_event(log: dict) -> dict | None:
    """Decode one raw log into the activity.json event shape (or None)."""
    topics = log["topics"]
    if len(topics) < 4:
        return None
    topic0 = _hexstr(topics[0])
    category = int(_hexstr(topics[3]), 16)  # uint8 stored as a 32-byte topic
    data = log["data"]
    raw = bytes(data) if isinstance(data, (bytes, bytearray)) \
        else bytes.fromhex(data[2:] if data.startswith("0x") else data)
    tx_hash = _hexstr(log["transactionHash"])
    try:
        if topic0 == ATTESTED_TOPIC:
            issuer, subject, issuer_h, subject_h, ev_hash, is_update = abi_decode(
                ["address", "address", "string", "string", "bytes32", "bool"], raw
            )
            return {
                "type": "attested",
                "issuerHandle": issuer_h,
                "subjectHandle": subject_h,
                "issuer": issuer,
                "subject": subject,
                "category": category,
                "evidenceHash": "0x" + ev_hash.hex(),
                "isUpdate": bool(is_update),
                "txHash": tx_hash,
                "block": log["blockNumber"],
                "logIndex": log["logIndex"],
            }
        if topic0 == REVOKED_TOPIC:
            issuer, subject, issuer_h, subject_h = abi_decode(
                ["address", "address", "string", "string"], raw
            )
            return {
                "type": "revoked",
                "issuerHandle": issuer_h,
                "subjectHandle": subject_h,
                "issuer": issuer,
                "subject": subject,
                "category": category,
                "evidenceHash": "0x" + "00" * 32,
                "isUpdate": False,
                "txHash": tx_hash,
                "block": log["blockNumber"],
                "logIndex": log["logIndex"],
            }
    except Exception as exc:  # corrupt/unknown log shape: skip, never crash
        print(f"WARN: undecodable log {log.get('transactionHash')}: {exc}",
              file=sys.stderr)
        return None
    return None


def reconstruct_counters(events: list[dict]) -> dict:
    """Counters derived from events alone (§5.7 cross-check source).

    Latest event per (issuer, subject, category) decides active — the same
    rule graph.html applies. uniqueInteractors = distinct issuer ADDRESSES
    that ever attested or revoked (every such caller is a registry holder
    by construction, §2.5).
    """
    latest: dict[tuple, dict] = {}
    for ev in sorted(events, key=lambda e: (e["block"], e["logIndex"])):
        latest[(ev["issuerHandle"], ev["subjectHandle"], ev["category"])] = ev
    active = [ev for ev in latest.values() if ev["type"] == "attested"]
    received_by_category = [0] * 5
    received_by_handle: dict[str, int] = {}
    given_by_handle: dict[str, int] = {}
    for ev in active:
        received_by_category[ev["category"]] += 1
        received_by_handle[ev["subjectHandle"]] = \
            received_by_handle.get(ev["subjectHandle"], 0) + 1
        given_by_handle[ev["issuerHandle"]] = \
            given_by_handle.get(ev["issuerHandle"], 0) + 1
    interactors = sorted({(ev.get("issuer") or ev["issuerHandle"]).lower()
                          for ev in events})
    return {
        "totalActiveAttestations": len(active),
        "uniqueInteractors": len(interactors),
        "interactorAddresses": interactors,
        "receivedByCategory": received_by_category,
        "receivedByHandle": received_by_handle,
        "givenByHandle": given_by_handle,
        "totalEvents": len(events),
    }


class RpcPool:
    """Rotating JSON-RPC pool: try each endpoint in order, move on on error."""

    def __init__(self, urls: list[str], timeout: int = 15):
        self.urls = urls
        self.timeout = timeout
        self._w3: Web3 | None = None
        self._idx = 0

    def _connect(self, idx: int) -> Web3:
        w3 = Web3(Web3.HTTPProvider(self.urls[idx],
                                    request_kwargs={"timeout": self.timeout}))
        # BSC is a PoA chain (280-byte extraData) — without this middleware
        # web3.py rejects every get_block with ExtraDataLengthError.
        w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
        return w3

    def call(self, fn_name: str, *args, **kwargs):
        """Call a Web3 method, rotating RPCs on failure. Returns (result, url)."""
        last_exc: Exception | None = None
        for attempt in range(len(self.urls)):
            idx = (self._idx + attempt) % len(self.urls)
            w3 = self._connect(idx)
            try:
                attr = getattr(w3.eth, fn_name)
                # block_number is a property; get_logs/get_block are methods.
                result = attr(*args, **kwargs) if callable(attr) else attr
                self._idx = idx  # stick with the working endpoint
                return result, self.urls[idx]
            except Exception as exc:  # noqa: BLE001 - rotation must catch all
                last_exc = exc
                print(f"WARN: RPC {self.urls[idx]} failed on {fn_name}: "
                      f"{exc!r} — rotating", file=sys.stderr)
        raise RuntimeError(f"all RPCs failed on {fn_name}: {last_exc!r}")


def load_json(path: str, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def main() -> int:
    ap = argparse.ArgumentParser(description="AgentVouch event indexer (§4.3)")
    ap.add_argument("--contract", required=True, help="AgentVouch address")
    ap.add_argument("--from-block", type=int, required=True,
                    help="deployment block (scan start on --rescan / first run)")
    ap.add_argument("--to-block", type=int, default=None,
                    help="stop block (default: latest)")
    ap.add_argument("--rpc", action="append", default=[],
                    help="RPC endpoint (repeatable; default: config.js list)")
    ap.add_argument("--chunk", type=int, default=10000,
                    help="blocks per eth_getLogs call (default 10000)")
    ap.add_argument("--out-dir", required=True,
                    help="directory receiving activity.json + evidence.json")
    ap.add_argument("--state", default=None,
                    help="state file (default: <out-dir>/indexer-state.json)")
    ap.add_argument("--evidence-map", default=None,
                    help="JSON {evidenceHash: url} of known evidence URLs")
    ap.add_argument("--rescan", action="store_true",
                    help="ignore state, rebuild from --from-block")
    args = ap.parse_args()

    contract = Web3.to_checksum_address(args.contract)
    rpcs = args.rpc or DEFAULT_RPCS
    pool = RpcPool(rpcs)
    state_path = args.state or os.path.join(args.out_dir, "indexer-state.json")
    os.makedirs(args.out_dir, exist_ok=True)

    state = {} if args.rescan else load_json(state_path, {})
    events_by_key: dict[str, dict] = {}
    if not args.rescan:
        # Internal store first: state["events"] keeps the FULL decoded event
        # (incl. issuer/subject addresses + logIndex), which activity.json
        # deliberately omits — the public snapshot must never carry raw
        # addresses (red-line hygiene, DESIGN §8.2).
        stored = state.get("events") or []
        if stored:
            for ev in stored:
                events_by_key[f"{ev['txHash']}:{ev.get('logIndex', 0)}"] = ev
        else:  # legacy fallback: events merged from a previous activity.json
            existing = load_json(os.path.join(args.out_dir, "activity.json"), {})
            for ev in existing.get("events", []):
                events_by_key[f"{ev['txHash']}:{ev.get('logIndex', 0)}"] = ev
    block_ts: dict[str, int] = state.get("blockTimestamps", {})

    from_block = args.from_block if args.rescan or not state.get("lastScannedBlock") \
        else state["lastScannedBlock"] + 1
    latest, _ = pool.call("block_number")
    to_block = args.to_block if args.to_block is not None else latest
    if from_block > to_block:
        print(f"nothing new: from_block {from_block} > latest {to_block}",
              file=sys.stderr)
        from_block = to_block + 1  # skip the loop, still rewrite outputs

    scanned = 0
    start = time.time()
    lo = from_block
    while lo <= to_block:
        hi = min(lo + args.chunk - 1, to_block)
        logs, url = pool.call(
            "get_logs",
            {
                "address": contract,
                "fromBlock": Web3.to_hex(lo),
                "toBlock": Web3.to_hex(hi),
                "topics": [[ATTESTED_TOPIC, REVOKED_TOPIC]],
            },
        )
        for log in logs:
            ev = decode_event(log)
            if ev is None:
                continue
            key = f"{ev['txHash']}:{ev['logIndex']}"
            events_by_key[key] = ev
            scanned += 1
        lo = hi + 1
    print(f"scanned blocks {from_block}..{to_block} via "
          f"{pool.urls[pool._idx]}: {scanned} new event(s) in {time.time()-start:.1f}s",
          file=sys.stderr)

    # Fill timestamps (cached per block in the state file).
    events = list(events_by_key.values())
    for ev in events:
        bkey = str(ev["block"])
        if bkey not in block_ts:
            blk, _ = pool.call("get_block", ev["block"])
            block_ts[bkey] = int(blk["timestamp"])
        ev["timestamp"] = block_ts[bkey]
    events.sort(key=lambda e: (e["block"], e["logIndex"]), reverse=True)

    # evidence.json — hash-gated: only URLs whose keccak256 == the on-chain hash.
    evidence_map = load_json(args.evidence_map, {}) if args.evidence_map else {}
    known_hashes = {ev["evidenceHash"] for ev in events
                    if ev["type"] == "attested"
                    and ev["evidenceHash"] != "0x" + "00" * 32}
    evidence: dict[str, str] = {}
    for h, url in evidence_map.items():
        h = h.lower()
        if h not in known_hashes:
            continue
        if keccak256_hex(url).lower() != h:
            print(f"WARN: evidence map entry {h} does not hash to its URL "
                  f"({url}) — excluded", file=sys.stderr)
            continue
        evidence[h] = url

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    activity = {
        "generatedAt": generated_at,
        "block": to_block,
        "contract": contract,
        "events": [
            {k: ev[k] for k in
             ("type", "issuerHandle", "subjectHandle", "category",
              "evidenceHash", "txHash", "block", "timestamp", "isUpdate",
              "logIndex")}
            for ev in events
        ],
    }
    with open(os.path.join(args.out_dir, "activity.json"), "w") as f:
        json.dump(activity, f, indent=2)
    with open(os.path.join(args.out_dir, "evidence.json"), "w") as f:
        json.dump(evidence, f, indent=2, sort_keys=True)
    state["lastScannedBlock"] = to_block
    state["blockTimestamps"] = block_ts
    state["contract"] = contract
    # Full internal event store (addresses + logIndex included) — the merge
    # source for the next run. activity.json stays address-free (§8.2).
    state["events"] = events
    with open(state_path, "w") as f:
        json.dump(state, f, indent=2)

    counters = reconstruct_counters(events)
    counters["generatedAt"] = generated_at
    counters["scannedToBlock"] = to_block
    counters["evidenceEntries"] = len(evidence)
    print(json.dumps(counters, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
