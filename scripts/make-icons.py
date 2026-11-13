# Generates the menu bar glyph and the app icon (AppIcon.icon), both from the same knife.
# Usage: python3 scripts/make-icons.py Penknife/Resources
import sys, os, math
res = sys.argv[1]
assets = os.path.join(res, "AppIcon.icon", "Assets")
BLADE_ANGLE = -32          # blade opened ~150° from the handle
PIVOT = (10, 0)
BLADE = [(-20, -64), (300, -64), (452, -18), (380, 30), (300, 64), (-20, 64)]

def handle_path(h):
    r = h / 2
    return f'M {-290-r} 0 A {r} {r} 0 0 1 -290 {-r} L -30 {-r} A {r} {r} 0 0 1 {-30+r} 0 A {r} {r} 0 0 1 -30 {r} L -290 {r} A {r} {r} 0 0 1 {-290-r} 0 Z'
blade = 'M -20 -64 L 300 -64 Q 392 -64 452 -18 Q 404 46 300 64 L -20 64 Z'
bladeT = f'translate({PIVOT[0]} {PIVOT[1]}) rotate({BLADE_ANGLE})'

def rot(p, deg):
    a = math.radians(deg); x, y = p
    return (x * math.cos(a) - y * math.sin(a), x * math.sin(a) + y * math.cos(a))

def blade_pts():
    return [(PIVOT[0] + q[0], PIVOT[1] + q[1]) for q in (rot(p, BLADE_ANGLE) for p in BLADE)]

# Rotate everything so the line from the handle end to the blade tip runs at exactly 45°.
tip = blade_pts()[2]; end = (-370, 0)
ROT = -45 - math.degrees(math.atan2(tip[1] - end[1], tip[0] - end[0]))

def bbox(h):
    P = [(cx + h / 2 * math.cos(math.radians(a)), h / 2 * math.sin(math.radians(a))) for a in range(0, 360, 5) for cx in (-290, -30)]
    P = [rot(p, ROT) for p in P + blade_pts()]
    xs = [p[0] for p in P]; ys = [p[1] for p in P]
    return (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, max(max(xs) - min(xs), max(ys) - min(ys))

def svg(body, defs, G):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><defs>{defs}</defs><g transform="{G}">{body}</g></svg>\n'

# Menu bar: thicker handle, 1.5 pt gap between blade and handle, one pivot hole; cropped tight.
H = 220
cx, cy, span = bbox(H)
unit = span / 17            # 1 pt in path units (glyph ~17 pt inside 18 pt)
gap, hole = 1.5 * unit, 0.9 * unit
mask = (f'<mask id="m"><rect x="-3000" y="-3000" width="6000" height="6000" fill="#fff"/>'
        f'<path d="{handle_path(H)}" fill="none" stroke="#000" stroke-width="{2 * gap:.0f}"/></mask>')
body = (f'<g mask="url(#m)"><g transform="{bladeT}"><path d="{blade}"/></g></g>'
        f'<path fill-rule="evenodd" d="{handle_path(H)} M {-60 - hole:.0f} 0 a {hole:.0f} {hole:.0f} 0 1 0 {2 * hole:.0f} 0 a {hole:.0f} {hole:.0f} 0 1 0 {-2 * hole:.0f} 0 Z"/>')
vb = f'{cx - 9 * unit:.1f} {cy - 9 * unit:.1f} {18 * unit:.1f} {18 * unit:.1f}'
open(os.path.join(res, 'Assets.xcassets', 'MenuBarIcon.imageset', 'menubar.svg'), 'w').write(
    f'<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="{vb}"><defs>{mask}</defs><g transform="rotate({ROT:.2f})">{body}</g></svg>\n')

# App icon (chosen by the user, 2026-11-13): the same glyph in white glass on a system blue
# gradient, 640 px of the 1024 canvas; macOS draws the Liquid Glass.
import json, re, shutil
glyph = open(os.path.join(res, 'Assets.xcassets', 'MenuBarIcon.imageset', 'menubar.svg')).read()
v = [float(x) for x in re.search(r'viewBox="([^"]+)"', glyph).group(1).split()]
inner = re.search(r'<svg[^>]*>(.*)</svg>', glyph, re.S).group(1)
size = 640
shutil.rmtree(os.path.join(res, 'AppIcon.icon'), ignore_errors=True)
os.makedirs(assets)
open(os.path.join(assets, 'glyph.svg'), 'w').write(
    f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
    f'<g transform="translate({512 - size / 2} {512 - size / 2}) scale({size / v[2]:.5f}) translate({-v[0]} {-v[1]})" fill="#FFFFFF">{inner}</g></svg>\n')
json.dump({
    "fill": {"automatic-gradient": "srgb:0.04000,0.52000,1.00000,1.00000"},
    "groups": [{"layers": [{"glass": True, "image-name": "glyph.svg", "name": "glyph"}],
                "shadow": {"kind": "neutral", "opacity": 0.4},
                "translucency": {"enabled": True, "value": 0.3}}],
    "supported-platforms": {"squares": ["macOS"]},
}, open(os.path.join(res, 'AppIcon.icon', 'icon.json'), 'w'), indent=2)
