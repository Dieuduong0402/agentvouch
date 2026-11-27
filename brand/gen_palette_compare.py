#!/usr/bin/env python3
"""Palette comparison strip: current site palette vs proposed unified palette.
Row 1 = current (site CSS). Row 2 = proposed (brand navy + gold + badge green/cream).
"""
import cairosvg

NAVY = "#0f172a"
GREEN = "#22c55e"
CREAM = "#d6c08a"
GOLD = "#f0b429"
BNB = "#f0b90b"

current = [
    ("Nền #0b0e13", "#0b0e13"),
    ("Thẻ #151a23", "#151a23"),
    ("Chữ #e8ecf1", "#e8ecf1"),
    ("Chữ mờ #9aa7b5", "#9aa7b5"),
    ("Vàng BNB #f0b90b", BNB),
    ("Xanh ok #3fb96f", "#3fb96f"),
    ("Đỏ #e5534b", "#e5534b"),
]
proposed = [
    ("Nền navy #0f172a", NAVY),
    ("Thẻ #1a2540", "#1a2540"),
    ("Chữ #e8ecf1", "#e8ecf1"),
    ("Chữ mờ #9aa7b5", "#9aa7b5"),
    ("Vàng BNB #f0b90b", BNB),
    ("Xanh trust #22c55e", GREEN),
    ("Kem #d6c08a", CREAM),
]


def swatch_row(y, label, items):
    s = [f'<text x="40" y="{y + 34}" font-family="Arial" font-size="24" '
         f'font-weight="700" fill="#e8ecf1">{label}</text>']
    x = 40
    for name, hexv in items:
        s.append(f'<rect x="{x}" y="{y + 52}" width="150" height="90" rx="10" fill="{hexv}" '
                 f'stroke="#334155" stroke-width="1"/>')
        s.append(f'<text x="{x}" y="{y + 164}" font-family="Arial" font-size="15" '
                 f'fill="#cbd5e1">{name}</text>')
        x += 166
    return "\n".join(s)


svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1240" height="480" viewBox="0 0 1240 480">
<rect width="1240" height="480" fill="#0b0e13"/>
{swatch_row(20, "HIỆN TẠI — web (vàng BNB trên nền gần đen)", current)}
{swatch_row(250, "ĐỀ XUẤT — thống nhất với logo + badge (navy + vàng + xanh trust + kem)", proposed)}
</svg>'''
open("/home/hatch/workspace/vouch/brand/palette-compare.svg", "w").write(svg)
cairosvg.svg2png(url="/home/hatch/workspace/vouch/brand/palette-compare.svg",
                 write_to="/home/hatch/workspace/vouch/brand/palette-compare.png",
                 output_width=1240)
print("rendered palette-compare.png")
