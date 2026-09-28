#!/usr/bin/env python3
"""Generates Resources/Icon/AppIcon.svg: a white brain outline on an indigo-violet squircle (macOS icon grid).

The brain is procedural so it stays crisp and symmetric: a superellipse silhouette whose edge is modulated into
even gyri, notched at the top and bottom where the hemispheres meet, a central fissure, and mirrored folds."""
import math

W = 1024
BODY = 824
OFF = (W - BODY) / 2
R = 185.4
CX, CY = 512, 500

def squircle(x, y, w, h, r, k=0.64):
    return (f"M{x+r},{y} H{x+w-r} C{x+w-r*(1-k)},{y} {x+w},{y+r*(1-k)} {x+w},{y+r} "
            f"V{y+h-r} C{x+w},{y+h-r*(1-k)} {x+w-r*(1-k)},{y+h} {x+w-r},{y+h} "
            f"H{x+r} C{x+r*(1-k)},{y+h} {x},{y+h-r*(1-k)} {x},{y+h-r} "
            f"V{y+r} C{x},{y+r*(1-k)} {x+r*(1-k)},{y} {x+r},{y} Z")

def superellipse_r(th, rx, ry, n):
    c, s = abs(math.cos(th)), abs(math.sin(th))
    return 1.0 / ((c / rx) ** n + (s / ry) ** n) ** (1.0 / n)

def brain_r(deg):
    th = math.radians(deg)
    # Slightly fuller at the bottom-back like a real brain seen from above.
    ry = 262 if math.sin(th) > 0 else 250
    base = superellipse_r(th, 300, ry, 2.35)
    # Distance from the top notch, 0..180, the same on both sides → symmetric.
    phi = abs(((deg - 90) + 180) % 360 - 180)
    # Even gyri: rounded lobes with crisp notches between them; calmer along the bottom.
    count = 7.0
    lobe = abs(math.sin(phi / 180 * count * math.pi)) ** 0.75
    amp = 0.062 if phi < 150 else 0.062 * max(0.0, (180 - phi) / 30)
    notch_top = 0.085 * math.exp(-((phi - 0) / 7.5) ** 2)
    notch_bottom = 0.10 * math.exp(-((phi - 180) / 9) ** 2)
    return base * (1 + amp * lobe - amp * 0.35 - notch_top - notch_bottom)

pts = []
N = 1440
for i in range(N):
    deg = 360 * i / N
    r = brain_r(deg)
    pts.append((CX + r * math.cos(math.radians(deg)), CY - r * math.sin(math.radians(deg))))
outline = "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in pts) + " Z"

top_y = CY - brain_r(90)
bottom_y = CY + brain_r(270)
fissure = (f"M{CX},{top_y + 22:.1f} C{CX - 16},{CY - 150} {CX + 16},{CY - 60} {CX},{CY + 10} "
           f"C{CX - 16},{CY + 80} {CX + 16},{CY + 160} {CX},{bottom_y - 26:.1f}")

def mirror(d):
    """Mirror an absolute-coordinate path around the vertical center line."""
    import re
    return re.sub(r"(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)", lambda m: f"{2 * CX - float(m.group(1)):.1f},{m.group(2)}", d)

# Folds: each sulcus grows inward from a notch in the outline, curling gently, then mirrored.
def notch_point(phi):
    deg = 90 + phi                      # left side
    r = brain_r(deg)
    return (CX + r * math.cos(math.radians(deg)), CY - r * math.sin(math.radians(deg)))

def fold_from(phi, length, curl, bend=1):
    x, y = notch_point(phi)
    vx, vy = CX - x, (CY + 10) - y
    L = math.hypot(vx, vy); vx, vy = vx / L, vy / L
    wx, wy = -vy * bend, vx * bend
    pts = [(x + vx * 4, y + vy * 4),
           (x + vx * length * 0.42 + wx * curl, y + vy * length * 0.42 + wy * curl),
           (x + vx * length * 0.70 - wx * curl * 1.2, y + vy * length * 0.70 - wy * curl * 1.2),
           (x + vx * length + wx * curl * 0.4, y + vy * length + wy * curl * 0.4)]
    return "M" + " C".join(["{:.1f},{:.1f}".format(*pts[0]), " ".join("{:.1f},{:.1f}".format(*q) for q in pts[1:])])

step = 180 / 7
left_folds = [
    fold_from(step * 2, 150, 34, 1),     # upper
    fold_from(step * 4, 170, 30, -1),    # middle
    fold_from(step * 5, 118, 24, 1),     # lower
    # a short hook beside the fissure
    "M{:.1f},{:.1f} C{:.1f},{:.1f} {:.1f},{:.1f} {:.1f},{:.1f}".format(CX - 66, CY + 40, CX - 104, CY + 66, CX - 100, CY + 120, CX - 64, CY + 144),
]
folds = left_folds + [mirror(d) for d in left_folds]

stroke = 34
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">
  <defs>
    <linearGradient id="bg" gradientUnits="userSpaceOnUse" x1="{OFF}" y1="{OFF}" x2="{OFF+BODY}" y2="{OFF+BODY}">
      <stop offset="0" stop-color="#7A74FF"/><stop offset="0.5" stop-color="#4C38E4"/><stop offset="1" stop-color="#25108A"/>
    </linearGradient>
    <radialGradient id="shine" gradientUnits="userSpaceOnUse" cx="{OFF + BODY*0.30}" cy="{OFF + BODY*0.10}" r="{BODY*0.80}">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.32"/><stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.05"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="glow" gradientUnits="userSpaceOnUse" cx="{CX}" cy="{CY}" r="{BODY*0.42}">
      <stop offset="0" stop-color="#B9B2FF" stop-opacity="0.28"/><stop offset="1" stop-color="#B9B2FF" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="ink" gradientUnits="userSpaceOnUse" x1="0" y1="{top_y}" x2="0" y2="{bottom_y}">
      <stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E6E2FF"/>
    </linearGradient>
    <filter id="drop" x="-10%" y="-10%" width="120%" height="125%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="14"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.30"/></feComponentTransfer>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <filter id="lift" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="10" result="b"/>
      <feFlood flood-color="#140959" flood-opacity="0.45"/><feComposite in2="b" operator="in"/><feOffset dy="10"/>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <clipPath id="body"><path d="{squircle(OFF, OFF, BODY, BODY, R)}"/></clipPath>
  </defs>
  <g filter="url(#drop)"><path d="{squircle(OFF, OFF, BODY, BODY, R)}" fill="url(#bg)"/></g>
  <g clip-path="url(#body)">
    <rect x="0" y="0" width="{W}" height="{W}" fill="url(#glow)"/>
    <g transform="translate({CX} {CY + 12}) scale(0.9) translate({-CX} {-CY})" filter="url(#lift)" fill="none" stroke="url(#ink)" stroke-linecap="round" stroke-linejoin="round">
      <path d="{outline}" stroke-width="{stroke}"/>
      <path d="{fissure}" stroke-width="{stroke - 4}"/>
      <g stroke-width="{stroke - 6}">{''.join(f'<path d="{d}"/>' for d in folds)}</g>
    </g>
    <rect x="0" y="0" width="{W}" height="{W}" fill="url(#shine)"/>
    <path d="{squircle(OFF + 1.5, OFF + 1.5, BODY - 3, BODY - 3, R - 1.5)}" fill="none" stroke="#FFFFFF" stroke-opacity="0.16" stroke-width="3"/>
  </g>
</svg>
'''
open("Resources/Icon/AppIcon.svg", "w").write(svg)
print("ok", round(top_y), round(bottom_y))
