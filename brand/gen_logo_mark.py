#!/usr/bin/env python3
"""Square mark for the site header + favicon: the V2 attestation circle alone
(18 dots + spokes + gold center + enclosing cream circle) on navy, 500x500.
Same geometry/colors as brand/logo-project-v2.svg, no wordmark.
"""
import math

NAVY = "#0f172a"
GREEN = "#22c55e"
CREAM = "#d6c08a"
GOLD = "#f0b429"
SPOKE = "#cbd5e1"

CX, CY = 250, 250
R = 180
DOT_R = 10
CENTER_R = 26
N = 18

parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="500" height="500" viewBox="0 0 500 500">']
parts.append('<rect width="500" height="500" rx="100" fill="#0f172a"/>')
parts.append(f'<circle cx="{CX}" cy="{CY}" r="{R + 30}" fill="none" stroke="{CREAM}" stroke-width="4.5" opacity="0.9"/>')
for i in range(N):
    a = 2 * math.pi * i / N - math.pi / 2
    x = CX + R * math.cos(a)
    y = CY + R * math.sin(a)
    parts.append(f'<line x1="{x:.1f}" y1="{y:.1f}" x2="{CX}" y2="{CY}" stroke="{SPOKE}" stroke-width="3" opacity="0.35"/>')
for i in range(N):
    a = 2 * math.pi * i / N - math.pi / 2
    x = CX + R * math.cos(a)
    y = CY + R * math.sin(a)
    color = GREEN if i % 2 == 0 else CREAM
    parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{DOT_R}" fill="{color}"/>')
parts.append(f'<circle cx="{CX}" cy="{CY}" r="37" fill="none" stroke="{GOLD}" stroke-width="3" opacity="0.45"/>')
parts.append(f'<circle cx="{CX}" cy="{CY}" r="{CENTER_R}" fill="{GOLD}"/>')
parts.append('</svg>')
open("/home/hatch/workspace/vouch/site/assets/logo-mark.svg", "w").write("\n".join(parts))
print("wrote site/assets/logo-mark.svg")
