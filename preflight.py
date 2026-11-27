#!/usr/bin/env python3
"""AgentVouch egress pre-flight — DESIGN.md §5.2.

Before interaction #1 (and at the start of each seeding day), verify that
the 6 wallets reach the chain through 6 DIFFERENT public IPs, each measured
through the exact egress path that wallet's `baw` process will use:

  - VM wallets: curl from this VM, via the wallet's assigned proxy
    (or direct when the wallet is assigned no proxy);
  - PC wallets: the same curl executed ON the PC via ssh (host `pc-makefun`),
    because the PC wallets' baw sessions live on the PC.

Pass rule: all 6 measured public IPs are pairwise distinct. Any collision
= FAIL: re-route the colliding wallet and re-run — NO campaign interaction
happens until the check passes 6/6.

Proxy reporting rule (user law 22/11): a failed run is reported only as
"chập chờn / trượt lượt này" — NEVER as "proxy chết / hết hạn / dead".
An IP that cannot be measured (ssh down, echo service unreachable) is
reported as UNMEASURED, not as a failure of the proxy.

Config file (JSON, no credentials — proxy host:port only):
  {"wallets": [{"handle": "tungquan42", "layer": "pc", "proxy": "direct"},
               {"handle": "duyenvu75", "layer": "vm",
                "proxy": "113.160.241.74:37132", "proxy_scheme": "socks5h"}]}
Proxy scheme MUST match the real endpoint: the fleet endpoints are
SOCKS5 (type=socks5 in the GPM proxy map) and REQUIRE auth. Two bugs
found 25/11 (fixed same night): (1) the config listed scheme "http"
for SOCKS endpoints — curl to a SOCKS listener with http:// fails
rc=56, which D7 misread as "3 proxy chập chờn"; with the correct
socks5h scheme the same 3 proxies answer at once. (2) curl was sent
with no credentials — SOCKS without auth fails rc=97. Credentials are
NEVER stored in this script or in the config: they are resolved at
runtime from ~/workspace/boltbook/proxies.json (the mirror source named
in the config note; all fleet endpoints share one provider account).
The report/log still record host:port only, never credentials.

Exit codes: 0 = 6/6 distinct IPs (PASS); 1 = collision (FAIL — fix routing);
2 = at least one wallet unmeasured (INCOMPLETE — re-run / check on its layer).
"""
import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

IP_ECHO_URLS = ["https://api.ipify.org", "https://ifconfig.me/ip"]
SSH_HOST = "pc-makefun"
SSH_BASE = ["ssh", "-F", "/home/hatch/.ssh/config",
            "-o", "ConnectTimeout=15",
            "-o", "UserKnownHostsFile=/home/hatch/.ssh/known_hosts",
            SSH_HOST]


def run(cmd, timeout=30, env=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, env=env)
        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"
    except Exception as exc:  # noqa: BLE001 - a failed spawn is an unmeasured route
        return -1, "", repr(exc)


def clean_env_for_proxy() -> dict:
    """Environment without any proxy vars, so curl uses ONLY the explicit -x."""
    env = dict(os.environ)
    for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
              "ALL_PROXY", "all_proxy"):
        env.pop(k, None)
    return env


BOLTBOOK_PROXIES = "/home/hatch/workspace/boltbook/proxies.json"


def _load_boltbook_proxies() -> dict:
    try:
        with open(BOLTBOOK_PROXIES) as f:
            return json.load(f)
    except Exception:
        return {}


def _shared_proxy_creds(bb: dict):
    """user:pass of the fleet proxy account, from any credentialed entry.

    All fleet endpoints share one provider account — never hardcode the
    credentials in this script; read them from the mirror source.
    """
    for v in bb.values():
        if isinstance(v, str) and "://" in v and "@" in v:
            return v.split("://", 1)[1].split("@", 1)[0]
    return None


def proxy_url_for(wallet: dict, bb: dict):
    """Full proxy URL (scheme://[creds@]host:port) for one wallet, or None.

    Precedence: the Boltbook entry for the handle (mirror source of truth,
    already carries scheme + creds) wins when it is a proxy; otherwise the
    config's host:port + scheme, with the shared fleet creds attached.
    Returns None for direct wallets. The caller must never log this value
    (it carries credentials); the report records host:port only.
    """
    handle = wallet["handle"]
    bb_val = bb.get(handle)
    if isinstance(bb_val, str) and bb_val.lower() != "direct" \
            and "://" in bb_val:
        return bb_val
    cfg_proxy = (wallet.get("proxy") or "direct").strip()
    if cfg_proxy.lower() in ("direct", "none"):
        return None
    scheme = wallet.get("proxy_scheme", "http")
    creds = _shared_proxy_creds(bb)
    if creds:
        return f"{scheme}://{creds}@{cfg_proxy}"
    return f"{scheme}://{cfg_proxy}"


def curl_cmd(proxy_url):
    """curl for the IP echo, through the wallet's own route (or direct).

    NOTE (bug found 25/11, fixed same night): `--noproxy "*"` must NEVER be
    used here — in curl, noproxy=* matches EVERY host, so it silently
    disables the explicit `-x` proxy too. All "via proxy" readings taken
    with that flag were in fact direct-route readings. The correct way to
    keep the environment's egress proxy out of a wallet-proxy measurement
    is to unset the proxy env vars (clean_env_for_proxy()).
    """
    cmd = ["curl", "-s", "-m", "15"]
    if proxy_url:
        cmd += ["-x", proxy_url]
    cmd += [IP_ECHO_URLS[0]]
    return cmd


def measure_ip(wallet: dict, bb: dict) -> dict:
    """Measure one wallet's public IP through its own egress path."""
    handle = wallet["handle"]
    layer = wallet.get("layer", "vm")
    proxy = (wallet.get("proxy") or "direct").strip()
    proxy_url = proxy_url_for(wallet, bb)
    result = {
        "handle": handle, "layer": layer,
        "proxy": "direct" if proxy.lower() in ("direct", "none")
                 else proxy.split("@")[-1],  # host:port only, never credentials
        "ip": None, "status": "unmeasured", "detail": "",
        "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    cmd = curl_cmd(proxy_url)
    is_proxied = proxy_url is not None
    if layer == "pc":
        # Same curl, executed on the PC where this wallet's baw session lives.
        remote = " ".join(cmd)
        rc, out, err = run(SSH_BASE + [remote], timeout=60)
    elif layer == "vm":
        # Proxied: strip the VM's own egress-proxy env vars so curl uses ONLY
        # the wallet's proxy. Direct: inherit env (baw on the VM runs through
        # the same env egress proxy, so that IS the wallet's direct route).
        rc, out, err = run(cmd, timeout=30,
                           env=clean_env_for_proxy() if is_proxied else None)
    else:
        result["detail"] = f"unknown layer {layer!r}"
        return result
    if rc == 0 and out and out.count(".") == 3 and all(
            part.isdigit() and 0 <= int(part) <= 255 for part in out.split(".")):
        result["ip"] = out
        result["status"] = "ok"
    else:
        # One failed echo attempt = flaky run, NOT a dead proxy (user law).
        result["detail"] = (f"echo attempt failed (rc={rc}): "
                            f"{(err or out)[:120]} — chập chờn, trượt lượt này")
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description="AgentVouch egress pre-flight (§5.2)")
    ap.add_argument("--config", required=True, help="wallets JSON config")
    ap.add_argument("--log", default=None,
                    help="append JSON-lines log (default: no log file)")
    ap.add_argument("--only", default=None,
                    help="comma list of handles to check (default: all)")
    args = ap.parse_args()

    with open(args.config) as f:
        cfg = json.load(f)
    wallets = cfg["wallets"]
    if args.only:
        wanted = {h.strip() for h in args.only.split(",")}
        wallets = [w for w in wallets if w["handle"] in wanted]

    bb = _load_boltbook_proxies()
    results = [measure_ip(w, bb) for w in wallets]
    measured = [r for r in results if r["status"] == "ok"]
    ips = [r["ip"] for r in measured]
    distinct = len(set(ips)) == len(ips)
    collisions = sorted({ip for ip in ips if ips.count(ip) > 1})

    verdict = ("PASS" if len(measured) == len(results) and distinct
               else "FAIL" if collisions
               else "INCOMPLETE")
    report = {
        "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "verdict": verdict,
        "measured": f"{len(measured)}/{len(results)}",
        "distinct": distinct,
        "collisions": collisions,
        "results": results,
    }
    print(json.dumps(report, indent=2))
    if args.log:
        with open(args.log, "a") as f:
            f.write(json.dumps(report) + "\n")

    print(f"\nPre-flight {verdict}: {len(measured)}/{len(results)} measured, "
          f"{len(set(ips))} distinct IP(s).", file=sys.stderr)
    for r in results:
        print(f"  {r['handle']:14s} [{r['layer']}] via {r['proxy']:22s} -> "
              f"{r['ip'] or r['status']}"
              + (f" ({r['detail']})" if r["detail"] else ""), file=sys.stderr)
    if collisions:
        print(f"  COLLISION on {collisions} — re-route before any interaction.",
              file=sys.stderr)
    if verdict == "PASS":
        return 0
    return 1 if collisions else 2


if __name__ == "__main__":
    raise SystemExit(main())
