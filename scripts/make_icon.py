#!/usr/bin/env python3
"""Generates Resources/Icon/AppIcon.icon, an Icon Composer bundle: a simple diagram of a neuron (a round cell body with
flared, forking dendrites and a nucleus) in white on an indigo gradient.

The artwork is flat, filled shapes with no outlines. The system supplies the Liquid Glass edge, specular, shadow and the
squircle mask, and re-tints the layers for the dark, clear and tinted icon styles. scripts/build-app.sh compiles the
bundle with actool into Assets.car (plus an .icns fallback for older macOS)."""
import json
import math
import os

W = 1024
CX, CY = 512, 512
OUT = "Resources/Icon/AppIcon.icon"

def point(origin, angle, length):
    """Angles are in degrees, clockwise from pointing right (SVG's y axis points down)."""
    a = math.radians(angle)
    return origin[0] + length * math.cos(a), origin[1] + length * math.sin(a)

def branch(start, angle, length, w0, w1, bend=0.0, taper=1.0, wedge=False, steps=48):
    """A filled, tapering process: a gently curved centerline whose width eases from w0 to w1, with round ends so
    children that start at its tip join smoothly. With wedge, the base fans out from a point instead (for trunks that
    start at the cell's center), so their wide flares merge into one body rather than stacking up as a disc.
    Returns the path data and the tip."""
    end = point(start, angle, length)
    mid = ((start[0] + end[0]) / 2, (start[1] + end[1]) / 2)
    ctrl = point(mid, angle + 90, bend * length)
    def at(t):
        u = 1 - t
        return (u * u * start[0] + 2 * u * t * ctrl[0] + t * t * end[0],
                u * u * start[1] + 2 * u * t * ctrl[1] + t * t * end[1])
    def tangent(t):
        dx = 2 * (1 - t) * (ctrl[0] - start[0]) + 2 * t * (end[0] - ctrl[0])
        dy = 2 * (1 - t) * (ctrl[1] - start[1]) + 2 * t * (end[1] - ctrl[1])
        n = math.hypot(dx, dy)
        return dx / n, dy / n
    left, right = [], []
    for i in range(steps + 1):
        t = i / steps
        x, y = at(t)
        tx, ty = tangent(t)
        half = (w1 + (w0 - w1) * (1 - t) ** taper) / 2
        if wedge:
            half = min(half, 4 + 1.2 * t * length)
        left.append((x - ty * half, y + tx * half))
        right.append((x + ty * half, y - tx * half))
    r1, r0 = w1 / 2, w0 / 2
    d = f"M{left[0][0]:.1f},{left[0][1]:.1f} " + " ".join(f"L{x:.1f},{y:.1f}" for x, y in left[1:])
    d += f" A{r1:.1f},{r1:.1f} 0 0 0 {right[-1][0]:.1f},{right[-1][1]:.1f} "
    d += " ".join(f"L{x:.1f},{y:.1f}" for x, y in reversed(right[:-1]))
    d += " Z" if wedge else f" A{r0:.1f},{r0:.1f} 0 0 0 {left[0][0]:.1f},{left[0][1]:.1f} Z"
    return d, end

# Six primary dendrites flare out of the cell body and fork once. Each entry is (angle, length, bend, forks) and each
# fork is (angle, length, bend).
DENDRITES = [
    (-98, 190, 0.10, [(-126, 175, -0.08), (-80, 150, 0.10)]),
    (-34, 200, -0.10, [(-60, 140, -0.06), (-12, 175, 0.10)]),
    (26, 180, 0.08, [(6, 165, -0.10), (52, 130, 0.08)]),
    (94, 200, -0.06, [(72, 140, -0.10), (118, 170, 0.08)]),
    (150, 185, 0.10, [(126, 135, -0.08), (174, 170, 0.08)]),
    (-160, 190, -0.08, [(-184, 165, -0.06), (-136, 135, 0.10)]),
]
SOMA_R = 78
TRUNK = (260, 50)   # width at the cell's center (the flare that shapes the body), width where the dendrite forks
FORK = (50, 28)

shapes = [f'<circle cx="{CX}" cy="{CY}" r="{SOMA_R}"/>']
for angle, length, bend, forks in DENDRITES:
    d, tip = branch((CX, CY), angle, length, *TRUNK, bend=bend, taper=2.6, wedge=True)
    shapes.append(f'<path d="{d}"/>')
    for f_angle, f_length, f_bend in forks:
        d, _ = branch(tip, f_angle, f_length, *FORK, bend=f_bend, taper=1.2)
        shapes.append(f'<path d="{d}"/>')

def svg(body, fill):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">\n'
            f'  <g fill="{fill}">\n    ' + "\n    ".join(body) + "\n  </g>\n</svg>\n")

def color(hex_rgb):
    r, g, b = (int(hex_rgb[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"

icon = {
    "fill": {
        "linear-gradient": [color("#7563FF"), color("#2A1296")],
        "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}},
    },
    # Groups are listed front to back: the nucleus floats just above the cell.
    "groups": [
        {
            "layers": [{"image-name": "nucleus.svg", "name": "nucleus", "glass": True}],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": True, "value": 0.3},
        },
        {
            "layers": [{"image-name": "neuron.svg", "name": "neuron", "glass": True}],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": True, "value": 0.2},
        },
    ],
    "supported-platforms": {"squares": "shared"},
}

os.makedirs(f"{OUT}/Assets", exist_ok=True)
with open(f"{OUT}/Assets/neuron.svg", "w") as f:
    f.write(svg(shapes, "#FFFFFF"))
with open(f"{OUT}/Assets/nucleus.svg", "w") as f:
    f.write(svg([f'<circle cx="{CX}" cy="{CY}" r="46"/>'], "#86E4FF"))
with open(f"{OUT}/icon.json", "w") as f:
    json.dump(icon, f, indent=2)
    f.write("\n")
print("ok")
