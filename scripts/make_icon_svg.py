#!/usr/bin/env python3
"""Generates Resources/Icon/AppIcon.svg: a neural synapse in layered, Liquid Glass style on an indigo squircle
(macOS icon grid).

Back to front: a deep gradient plate with a soft glow in the synaptic cleft, the receiving dendrite as tinted glass,
the axon terminal as frosted white glass with vesicles inside, and neurotransmitter beads crossing the gap. Every glass
layer gets the same treatment: translucent body, luminous inner edge, specular highlight on the lit (top-left) side
and a soft shadow on the layer beneath. There are no outlines: shapes are separated by light and depth only."""

W = 1024
BODY = 824
OFF = (W - BODY) / 2
R = 185.4
CX = 512

def squircle(x, y, w, h, r, k=0.64):
    return (f"M{x+r},{y} H{x+w-r} C{x+w-r*(1-k)},{y} {x+w},{y+r*(1-k)} {x+w},{y+r} "
            f"V{y+h-r} C{x+w},{y+h-r*(1-k)} {x+w-r*(1-k)},{y+h} {x+w-r},{y+h} "
            f"H{x+r} C{x+r*(1-k)},{y+h} {x},{y+h-r*(1-k)} {x},{y+h-r} "
            f"V{y+r} C{x},{y+r*(1-k)} {x+r*(1-k)},{y} {x+r},{y} Z")

def mirrored(half):
    """Closes a left-half outline (list of cubic segments from the top center down to the bottom center) into a
    symmetric path around x = CX."""
    def mx(p): return (2 * CX - p[0], p[1])
    start = half[0][0]
    d = f"M{start[0]:.1f},{start[1]:.1f}"
    for _, c1, c2, e in half:
        d += f" C{c1[0]:.1f},{c1[1]:.1f} {c2[0]:.1f},{c2[1]:.1f} {e[0]:.1f},{e[1]:.1f}"
    for s, c1, c2, _ in reversed(half):
        a, b, c = mx(c2), mx(c1), mx(s)
        d += f" C{a[0]:.1f},{a[1]:.1f} {b[0]:.1f},{b[1]:.1f} {c[0]:.1f},{c[1]:.1f}"
    return d + " Z"

# Axon terminal: a stem entering from the top that swells into a rounded bouton with a gently convex membrane.
TERM_BOTTOM = 520
terminal = mirrored([
    ((CX, 40), (CX - 30, 40), (CX - 62, 40), (CX - 62, 40)),
    ((CX - 62, 40), (CX - 62, 150), (CX - 70, 212), (CX - 128, 262)),
    ((CX - 128, 262), (CX - 196, 314), (CX - 226, 372), (CX - 222, 430)),
    ((CX - 222, 430), (CX - 216, 492), (CX - 120, TERM_BOTTOM), (CX, TERM_BOTTOM)),
])

# Dendritic spine: rises from the bottom and opens into a cup that cradles the terminal across a narrow cleft.
CLEFT = 50
spine = mirrored([
    ((CX, 984), (CX - 36, 984), (CX - 64, 984), (CX - 64, 984)),
    ((CX - 64, 984), (CX - 64, 830), (CX - 78, 770), (CX - 150, 722)),
    ((CX - 150, 722), (CX - 232, 668), (CX - 290, 590), (CX - 290, 488)),
    ((CX - 290, 488), (CX - 290, 440), (CX - 236, 436), (CX - 240, 480)),
    ((CX - 240, 480), (CX - 222, 540), (CX - 120, TERM_BOTTOM + CLEFT), (CX, TERM_BOTTOM + CLEFT)),
])

# Vesicles waiting inside the terminal, and transmitter beads released into the cleft.
vesicles = [(CX - 92, 432, 34), (CX + 4, 452, 38), (CX + 100, 424, 30), (CX - 26, 366, 26), (CX + 58, 352, 22)]
beads = [(CX - 128, 546, 13), (CX - 58, 536, 16), (CX + 12, 548, 12), (CX + 76, 538, 15), (CX + 140, 552, 11),
         (CX - 16, 522, 9), (CX + 46, 562, 9)]

# A curved reflection just inside the terminal's lit shoulder.
glint = f"M{CX - 118},{292} C{CX - 162},{322} {CX - 190},{364} {CX - 192},{410}"

# The artwork sits a little above center so the cleft lands on the plate's optical center.
LIFT = -18

def glass(path, pid, fill_top, fill_bottom, tint_opacity, shadow_opacity):
    """One glass layer: soft shadow around it (never seen through its own body), translucent body, luminous inner edge and a specular top-left highlight.
    The stems fade out toward the plate edge so each layer reads as a floating piece of glass."""
    return f'''
    <g mask="url(#stemFade)">
      <path d="{path}" fill="#000000" opacity="{shadow_opacity}" filter="url(#layerShadow)"/>
      <clipPath id="{pid}"><path d="{path}"/></clipPath>
      <linearGradient id="{pid}Fill" gradientUnits="userSpaceOnUse" x1="0" y1="{OFF}" x2="0" y2="{OFF + BODY}">
        <stop offset="0" stop-color="{fill_top}" stop-opacity="{tint_opacity}"/>
        <stop offset="1" stop-color="{fill_bottom}" stop-opacity="{tint_opacity * 0.6:.3f}"/>
      </linearGradient>
      <g clip-path="url(#{pid})">
        <rect x="0" y="0" width="{W}" height="{W}" fill="url(#{pid}Fill)"/>
        <path d="{path}" fill="none" stroke="#FFFFFF" stroke-opacity="0.55" stroke-width="48" filter="url(#soft14)"/>
        <path d="{path}" fill="none" stroke="url(#specular)" stroke-width="9" filter="url(#soft1)"/>
        <path d="{path}" fill="none" stroke="url(#bounce)" stroke-width="12" filter="url(#soft3)"/>
      </g>
    </g>'''

def bead(x, y, r, core, rim):
    return (f'<circle cx="{x}" cy="{y}" r="{r * 2.4:.1f}" fill="{rim}" opacity="0.55" filter="url(#soft{8 if r < 20 else 14})"/>'
            f'<circle cx="{x}" cy="{y}" r="{r}" fill="url(#{core})"/>'
            f'<ellipse cx="{x - r * 0.32:.1f}" cy="{y - r * 0.38:.1f}" rx="{r * 0.42:.1f}" ry="{r * 0.26:.1f}" '
            f'fill="#FFFFFF" opacity="0.85" transform="rotate(-28 {x - r * 0.32:.1f} {y - r * 0.38:.1f})"/>')

plate = squircle(OFF, OFF, BODY, BODY, R)
# Blurs use a whole-canvas region so thin strokes and small beads never get their glow clipped.
CANVAS = f'filterUnits="userSpaceOnUse" x="-100" y="-100" width="{W + 200}" height="{W + 200}"'
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">
  <defs>
    <linearGradient id="bg" gradientUnits="userSpaceOnUse" x1="{OFF}" y1="{OFF}" x2="{OFF + BODY * 0.7}" y2="{OFF + BODY}">
      <stop offset="0" stop-color="#8C7DFF"/><stop offset="0.45" stop-color="#5134E6"/><stop offset="1" stop-color="#1D0C78"/>
    </linearGradient>
    <radialGradient id="cleftGlow" gradientUnits="userSpaceOnUse" cx="{CX}" cy="{TERM_BOTTOM + CLEFT / 2}" r="{BODY * 0.5}">
      <stop offset="0" stop-color="#7DEBFF" stop-opacity="0.75"/><stop offset="0.35" stop-color="#6A8BFF" stop-opacity="0.28"/>
      <stop offset="1" stop-color="#6A8BFF" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="sheen" gradientUnits="userSpaceOnUse" cx="{OFF + BODY * 0.22}" cy="{OFF}" r="{BODY * 0.9}">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.30"/><stop offset="0.55" stop-color="#FFFFFF" stop-opacity="0.04"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="specular" gradientUnits="userSpaceOnUse" x1="{CX - 260}" y1="{OFF + 140}" x2="{CX + 40}" y2="{OFF + 520}">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="1"/><stop offset="0.4" stop-color="#FFFFFF" stop-opacity="0.8"/>
      <stop offset="0.75" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="bounce" gradientUnits="userSpaceOnUse" x1="{CX - 200}" y1="{OFF}" x2="{CX + 300}" y2="{OFF + BODY}">
      <stop offset="0.55" stop-color="#B8F4FF" stop-opacity="0"/><stop offset="1" stop-color="#B8F4FF" stop-opacity="0.7"/>
    </linearGradient>
    <radialGradient id="vesicle" cx="0.38" cy="0.34" r="0.7">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.95"/><stop offset="0.45" stop-color="#C9F6FF" stop-opacity="0.75"/>
      <stop offset="1" stop-color="#6FC8FF" stop-opacity="0.55"/>
    </radialGradient>
    <radialGradient id="transmitter" cx="0.38" cy="0.34" r="0.7">
      <stop offset="0" stop-color="#FFFFFF"/><stop offset="0.5" stop-color="#8FF1FF"/><stop offset="1" stop-color="#2FB8F0"/>
    </radialGradient>
    <filter id="drop" x="-10%" y="-10%" width="120%" height="125%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="14"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.30"/></feComponentTransfer>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <filter id="layerShadow" {CANVAS}>
      <feGaussianBlur in="SourceAlpha" stdDeviation="18"/><feOffset dy="18" result="fall"/>
      <feFlood flood-color="#0B0340"/><feComposite in2="fall" operator="in"/>
      <feComposite in2="SourceAlpha" operator="out"/>
    </filter>
    <linearGradient id="fade" gradientUnits="userSpaceOnUse" x1="0" y1="{OFF}" x2="0" y2="{OFF + BODY}">
      <stop offset="0.06" stop-color="#FFFFFF" stop-opacity="0"/><stop offset="0.3" stop-color="#FFFFFF" stop-opacity="1"/>
      <stop offset="0.7" stop-color="#FFFFFF" stop-opacity="1"/><stop offset="0.96" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <mask id="stemFade" maskUnits="userSpaceOnUse" x="0" y="0" width="{W}" height="{W}">
      <rect x="0" y="0" width="{W}" height="{W}" fill="url(#fade)"/>
    </mask>
    <filter id="soft1" {CANVAS}><feGaussianBlur stdDeviation="1.2"/></filter>
    <filter id="soft3" {CANVAS}><feGaussianBlur stdDeviation="3"/></filter>
    <filter id="soft8" {CANVAS}><feGaussianBlur stdDeviation="8"/></filter>
    <filter id="soft14" {CANVAS}><feGaussianBlur stdDeviation="14"/></filter>
    <filter id="soft24" {CANVAS}><feGaussianBlur stdDeviation="24"/></filter>
    <clipPath id="body"><path d="{plate}"/></clipPath>
  </defs>
  <g filter="url(#drop)"><path d="{plate}" fill="url(#bg)"/></g>
  <g clip-path="url(#body)">
    <g transform="translate(0 {LIFT})">
    <rect x="0" y="0" width="{W}" height="{W}" fill="url(#cleftGlow)"/>
    {glass(spine, "spine", "#C4EEFF", "#8FA6FF", 0.34, 0.40)}
    {glass(terminal, "terminal", "#FFFFFF", "#E2DCFF", 0.44, 0.45)}
    <g clip-path="url(#terminal)">
      <path d="{glint}" fill="none" stroke="#FFFFFF" stroke-opacity="0.7" stroke-width="12" stroke-linecap="round" filter="url(#soft3)"/>
      {''.join(bead(x, y, r, "vesicle", "#9FE9FF") for x, y, r in vesicles)}
    </g>
    {''.join(bead(x, y, r, "transmitter", "#7DEBFF") for x, y, r in beads)}
    </g>
    <rect x="0" y="0" width="{W}" height="{W}" fill="url(#sheen)"/>
  </g>
</svg>
'''
open("Resources/Icon/AppIcon.svg", "w").write(svg)
print("ok")
