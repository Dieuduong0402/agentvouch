#!/usr/bin/env python3
"""Project logo: attestation circle — many attestors (dots on a ring) connected
by spokes to one central person (gold dot). Outer ring = round dots (not dashes),
echoing the badge logo's 2-colour green/cream ring on navy.
V1: 12 dots. V2: 18 dots. Wide lockup 1200x630, mark left + AGENTVOUCH wordmark.
"""
import math

NAVY = "#0f172a"
GREEN = "#22c55e"
CREAM = "#d6c08a"
GOLD = "#f0b429"
SPOKE = "#cbd5e1"
TEXT = "#e2e8f0"
SUB = "#94a3b8"

CX, CY = 250, 315
R = 180
DOT_R = 10
CENTER_R = 26


def build(n_dots, path, outer_circle=False):
    parts = []
    parts.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">')
    parts.append(f'<rect width="1200" height="630" rx="48" fill="{NAVY}"/>')
    # enclosing outer circle (V2, user 27/11 11:28): thin cream ring outside the dots
    # bumped bolder 11:29 (user could not see it — faint + cached old file)
    if outer_circle:
        parts.append(f'<circle cx="{CX}" cy="{CY}" r="{R + 30}" fill="none" '
                     f'stroke="{CREAM}" stroke-width="4.5" opacity="0.9"/>')
    # spokes first (under the dots)
    for i in range(n_dots):
        a = 2 * math.pi * i / n_dots - math.pi / 2
        x = CX + R * math.cos(a)
        y = CY + R * math.sin(a)
        parts.append(
            f'<line x1="{x:.1f}" y1="{y:.1f}" x2="{CX}" y2="{CY}" '
            f'stroke="{SPOKE}" stroke-width="3" opacity="0.35"/>')
    # outer dotted ring: alternate green / cream
    for i in range(n_dots):
        a = 2 * math.pi * i / n_dots - math.pi / 2
        x = CX + R * math.cos(a)
        y = CY + R * math.sin(a)
        color = GREEN if i % 2 == 0 else CREAM
        parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{DOT_R}" fill="{color}"/>')
    # central person dot + halo ring
    parts.append(f'<circle cx="{CX}" cy="{CY}" r="37" fill="none" stroke="{GOLD}" '
                 f'stroke-width="3" opacity="0.45"/>')
    parts.append(f'<circle cx="{CX}" cy="{CY}" r="{CENTER_R}" fill="{GOLD}"/>')
    # wordmark
    parts.append(
        f'<text x="490" y="330" font-family="Arial, Helvetica, sans-serif" '
        f'font-size="72" font-weight="700" letter-spacing="5" fill="{TEXT}">AGENTVOUCH</text>')
    parts.append(
        f'<text x="494" y="392" font-family="Arial, Helvetica, sans-serif" '
        f'font-size="21" font-weight="400" letter-spacing="4" fill="{SUB}">ON-CHAIN REPUTATION FOR AGENT ID</text>')
    parts.append('</svg>')
    open(path, "w").write("\n".join(parts))
    print("wrote", path)


if __name__ == "__main__":
    import os
    base = os.path.expanduser("~/workspace/vouch/brand")
    build(12, os.path.join(base, "logo-project-v1.svg"))
    build(18, os.path.join(base, "logo-project-v2.svg"), outer_circle=True)
