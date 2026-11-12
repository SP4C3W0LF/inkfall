#!/usr/bin/env python3
"""Inkfall identity: single source of truth. Python 3 + Pillow only.

    python3 design/build_icon.py            # regenerate every master, raster and export
    python3 design/build_icon.py --ladder /path/ladder.png   # also write the size ladder

Concept A, "Falling line": five round-capped bars hang from one level top edge like ink running
down a page; the centre bar is longest and releases a single drop. Flat ember on emberInk.
All geometry is constants below; SVGs are written from the same path data the rasteriser uses.
"""
import math
import os
import re
import sys

from PIL import Image, ImageDraw, ImageChops

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wordmark_data  # noqa: E402  (outlined "Inkfall", Fraunces SemiBold, OFL)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MASTERS = os.path.join(HERE, "masters")
EXPORT = os.path.join(HERE, "export")
APPICON = os.path.join(ROOT, "Resources/Assets.xcassets/AppIcon.appiconset")
MENUBAR_SET = os.path.join(ROOT, "Resources/Assets.xcassets/MenuBarGlyph.imageset")

EMBER, INK, PAPER, WHITE, BLACK = "#F2A84B", "#1A1205", "#FBFBFA", "#FFFFFF", "#000000"
DARK_PAGE = "#0F0D0A"
K = 0.5522847498  # circle -> cubic

# ----------------------------------------------------------------------------------------------
# path model: list of contours; contour = list of ("M",x,y) ("L",x,y) ("C",x1,y1,x2,y2,x,y) ("Z",)
# ----------------------------------------------------------------------------------------------


def fmt(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def bar(cx, top, bottom, w):
    r = w / 2
    y = bottom - r
    return [("M", cx - r, top), ("L", cx - r, y),
            ("C", cx - r, y + K * r, cx - K * r, y + r, cx, y + r),
            ("C", cx + K * r, y + r, cx + r, y + K * r, cx + r, y),
            ("L", cx + r, top), ("Z",)]


def drop(cx, tip, cy, r):
    return [("M", cx, tip),
            ("C", cx + 0.3 * r, tip + 1.1 * r, cx + r, cy - 0.75 * r, cx + r, cy),
            ("C", cx + r, cy + K * r, cx + K * r, cy + r, cx, cy + r),
            ("C", cx - K * r, cy + r, cx - r, cy + K * r, cx - r, cy),
            ("C", cx - r, cy - 0.75 * r, cx - 0.3 * r, tip + 1.1 * r, cx, tip), ("Z",)]


def squircle(size=1024.0, tile=824.0, n=5.0, segments=32):
    """Superellipse |x|^n + |y|^n = 1 (n=5, the usual stand-in for Apple's continuous corner) as
    `segments` cubic Beziers: points on the curve, axis-aligned tangents at the extremes."""
    c, h = size / 2, tile / 2

    def pt(t):
        ct, st = math.cos(t), math.sin(t)
        return (c + h * math.copysign(abs(ct) ** (2 / n), ct), c + h * math.copysign(abs(st) ** (2 / n), st))

    def tangent(t):
        q = t / (math.pi / 2)
        if abs(q - round(q)) < 1e-9:  # on an axis: tangent is vertical or horizontal
            return [(0, 1), (-1, 0), (0, -1), (1, 0)][int(round(q)) % 4]
        a, b = pt(t - 1e-5), pt(t + 1e-5)
        d = math.dist(a, b)
        return ((b[0] - a[0]) / d, (b[1] - a[1]) / d)

    ts = [2 * math.pi * i / segments for i in range(segments + 1)]
    out = [("M",) + pt(ts[0])]
    for t0, t1 in zip(ts, ts[1:]):
        p0, p1, d0, d1 = pt(t0), pt(t1), tangent(t0), tangent(t1)
        hl = math.dist(p0, p1) / 3
        ctl = (p0[0] + d0[0] * hl, p0[1] + d0[1] * hl, p1[0] - d1[0] * hl, p1[1] - d1[1] * hl)
        ctl = tuple(min(max(v, c - h), c + h) for v in ctl)  # a flat extreme must not overshoot the grid
        out.append(("C",) + ctl + p1)
    out.append(("Z",))
    return out


def parse_wordmark(d):
    """Absolute M L H V Q C Z (fontTools SVGPathPen) -> model; Q raised to C."""
    i, cur, start, out, cmd = 0, (0.0, 0.0), (0.0, 0.0), [], None
    toks = re.findall(r"[MLHVQCZ]|-?\d*\.?\d+", d)
    nums = lambda n: [float(toks[i + j]) for j in range(n)]
    while i < len(toks):
        if toks[i] in "MLHVQCZ":
            cmd = toks[i]
            i += 1
            if cmd == "Z":
                out.append(("Z",))
                cur = start
                continue
        if cmd == "M":
            x, y = nums(2); i += 2
            out.append(("M", x, y)); cur = start = (x, y); cmd = "L"
        elif cmd == "L":
            x, y = nums(2); i += 2
            out.append(("L", x, y)); cur = (x, y)
        elif cmd == "H":
            x = float(toks[i]); i += 1
            out.append(("L", x, cur[1])); cur = (x, cur[1])
        elif cmd == "V":
            y = float(toks[i]); i += 1
            out.append(("L", cur[0], y)); cur = (cur[0], y)
        elif cmd == "Q":
            qx, qy, x, y = nums(4); i += 4
            out.append(("C", cur[0] + 2 / 3 * (qx - cur[0]), cur[1] + 2 / 3 * (qy - cur[1]),
                        x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y), x, y)); cur = (x, y)
        elif cmd == "C":
            v = nums(6); i += 6
            out.append(("C",) + tuple(v)); cur = (v[4], v[5])
    return out


def xform(path, s, tx, ty, sy=None):
    sy = s if sy is None else sy
    out = []
    for seg in path:
        if seg[0] == "Z":
            out.append(seg)
        else:
            out.append((seg[0],) + tuple(v * (s if k % 2 == 0 else sy) + (tx if k % 2 == 0 else ty)
                                         for k, v in enumerate(seg[1:])))
    return out


def d_attr(path):
    parts = []
    for seg in path:
        parts.append(seg[0] + " ".join(fmt(v) for v in seg[1:]))
    return "".join(parts)


def bounds(paths):
    xs, ys = [], []
    for p in paths:
        for seg in p:
            xs += seg[1::2]
            ys += seg[2::2]
    return min(xs), min(ys), max(xs), max(ys)


# ----------------------------------------------------------------------------------------------
# geometry
# ----------------------------------------------------------------------------------------------
W = 26
# normal cut, 256 viewBox
SYMBOL = [bar(48, 40, 112, W), bar(88, 40, 152, W), bar(128, 40, 188, W), bar(168, 40, 152, W),
          bar(208, 40, 112, W), drop(128, 196, 226, 13)]
SYMBOL_BBOX = (35, 40, 221, 239)

# small cut, 16 px grid (every edge on a whole pixel; 32 px is exactly 2x): three fat bars + a drop
SMALL = [bar(5, 3, 7, 2), bar(8, 3, 10, 2), bar(11, 3, 7, 2), drop(8, 11, 12.9, 1)]
SMALL_TILE = 14  # whole pixels (1..15) so the edge is crisp; Apple draws its own 16 px tiles near full size

MARK_BOX = 620          # mark's long side inside the 824 tile (12.4 % padding each side)


def fit(path_list, bbox, box):
    """affine putting bbox centred in the square box (x, y, size); returns transformed paths."""
    x0, y0, x1, y1 = bbox
    s = box[2] / max(x1 - x0, y1 - y0)
    tx = box[0] + (box[2] - (x1 - x0) * s) / 2 - x0 * s
    ty = box[1] + (box[2] - (y1 - y0) * s) / 2 - y0 * s
    return [xform(p, s, tx, ty) for p in path_list]


def icon_shapes(size):
    """[(paths, colour)] for the app icon at `size` px, in pixel coordinates."""
    k = size / 1024.0
    if size <= 32:
        u = size / 16.0
        tile = xform(squircle(16, SMALL_TILE), u, 0, 0)
        mark = [xform(p, u, 0, 0) for p in SMALL]
    else:
        tile = xform(squircle(), k, 0, 0)
        mark = fit(SYMBOL, SYMBOL_BBOX, (512 - MARK_BOX / 2, 512 - MARK_BOX / 2, MARK_BOX))
        mark = [xform(p, k, 0, 0) for p in mark]
    return [([tile], INK), (mark, EMBER)]


# ----------------------------------------------------------------------------------------------
# lockup: symbol (160 high) + wordmark, everything in one coordinate space, padding baked in
# ----------------------------------------------------------------------------------------------
PAD = 20
SYM_H = 160
TEXT_SIZE = 112
WORD = parse_wordmark(wordmark_data.PATH)


def lockup(pad=PAD):
    sym = fit(SYMBOL, SYMBOL_BBOX, (pad, pad, SYM_H))
    ts = TEXT_SIZE / 100.0
    word = xform(WORD, ts, pad + SYM_H + 36, pad + 118, ts)
    w = pad * 2 + SYM_H + 36 + wordmark_data.WIDTH * ts
    return sym, [word], math.ceil(w), SYM_H + pad * 2


# ----------------------------------------------------------------------------------------------
# svg writers
# ----------------------------------------------------------------------------------------------
def svg_doc(w, h, groups, title, bg=None):
    body = ""
    if bg:
        body += f'<rect width="{fmt(w)}" height="{fmt(h)}" fill="{bg}"/>'
    for paths, colour in groups:
        body += f'<path d="{"".join(d_attr(p) for p in paths)}" fill="{colour}"/>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {fmt(w)} {fmt(h)}">'
            f'<title>{title}</title>{body}</svg>\n')


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mode = "wb" if isinstance(data, bytes) else "w"
    with open(path, mode) as fh:
        fh.write(data)


def menubar_paths():
    return fit(SYMBOL, SYMBOL_BBOX, (1, 1, 16))


def write_svgs():
    for name, colour in (("inkfall-symbol", EMBER), ("inkfall-symbol-black", BLACK), ("inkfall-symbol-white", WHITE)):
        write(f"{MASTERS}/{name}.svg", svg_doc(256, 256, [(SYMBOL, colour)], "Inkfall symbol"))
    write(f"{MASTERS}/inkfall-symbol-small.svg", svg_doc(16, 16, [(SMALL, EMBER)], "Inkfall symbol, 16 px cut"))
    write(f"{MASTERS}/inkfall-menubar.svg", svg_doc(18, 18, [(menubar_paths(), BLACK)], "Inkfall menu bar glyph"))
    tile, mark = icon_shapes(1024)
    write(f"{MASTERS}/inkfall-icon.svg", svg_doc(1024, 1024, [tile, mark], "Inkfall app icon"))
    for pad, folder, light, dark in ((PAD, MASTERS, "inkfall-lockup", "inkfall-lockup-reversed"),
                                     (8, EXPORT, "readme-lockup-light", "readme-lockup-dark")):
        sym, word, w, h = lockup(pad)
        write(f"{folder}/{light}.svg", svg_doc(w, h, [(sym + word, INK)], "Inkfall"))
        write(f"{folder}/{dark}.svg", svg_doc(w, h, [(sym, EMBER), (word, WHITE)], "Inkfall"))
    # the template glyph also ships inside the asset catalog
    write(f"{MENUBAR_SET}/menubar.svg", svg_doc(18, 18, [(menubar_paths(), BLACK)], "Inkfall menu bar glyph"))
    write(f"{MENUBAR_SET}/Contents.json",
          '{\n  "images" : [\n    { "idiom" : "universal", "filename" : "menubar.svg" }\n  ],\n'
          '  "info" : { "version" : 1, "author" : "xcode" },\n'
          '  "properties" : {\n    "preserves-vector-representation" : true,\n'
          '    "template-rendering-intent" : "template"\n  }\n}\n')


# ----------------------------------------------------------------------------------------------
# rasteriser (supersampled, even-odd per path group)
# ----------------------------------------------------------------------------------------------
def flatten(path, scale):
    contours, cur, pts = [], None, []
    for seg in path:
        if seg[0] == "M":
            if pts:
                contours.append(pts)
            pts = [(seg[1] * scale, seg[2] * scale)]
            cur = pts[0]
        elif seg[0] == "L":
            cur = (seg[1] * scale, seg[2] * scale)
            pts.append(cur)
        elif seg[0] == "C":
            p0 = cur
            p1, p2, p3 = (seg[1] * scale, seg[2] * scale), (seg[3] * scale, seg[4] * scale), (seg[5] * scale, seg[6] * scale)
            n = max(8, int((math.dist(p0, p1) + math.dist(p1, p2) + math.dist(p2, p3)) / 1.5))
            for i in range(1, n + 1):
                t = i / n
                a, b, c, d = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t * t, t ** 3
                pts.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
            cur = p3
    if pts:
        contours.append(pts)
    return contours


def snap(c):
    """PIL fills polygons from floor(x0) to floor(x1) inclusive. A shape covering samples [a, b) therefore
    needs to be drawn from a+0.5 to b-0.5: inset each contour by half a sample per side."""
    x0, y0 = min(p[0] for p in c), min(p[1] for p in c)
    x1, y1 = max(p[0] for p in c), max(p[1] for p in c)
    mx, my = (x0 + x1) / 2, (y0 + y1) / 2
    kx, ky = max(x1 - x0 - 1, 0.01) / max(x1 - x0, 0.01), max(y1 - y0 - 1, 0.01) / max(y1 - y0, 0.01)
    return [(mx + (x - mx) * kx, my + (y - my) * ky) for x, y in c]


def raster(w, h, groups, bg=None, ss=4):
    """groups: [(paths, hex colour)] in pixel units -> RGBA image (w x h)."""
    img = Image.new("RGBA", (w, h), bg or (0, 0, 0, 0))
    for paths, colour in groups:
        # nonzero winding per path: contours wound like the path's largest add, the opposite cut holes
        area = lambda c: sum(c[i][0] * c[(i + 1) % len(c)][1] - c[(i + 1) % len(c)][0] * c[i][1] for i in range(len(c))) / 2
        mask = Image.new("1", (w * ss, h * ss), 0)
        for p in paths:
            contours = flatten(p, ss)
            sign = 1 if area(max(contours, key=lambda c: abs(area(c)))) > 0 else -1
            m = Image.new("1", mask.size, 0)
            for hole in (False, True):
                for c in contours:
                    if (area(c) * sign < 0) != hole:
                        continue
                    layer = Image.new("1", mask.size, 0)
                    ImageDraw.Draw(layer).polygon(snap(c), fill=1)
                    m = ImageChops.logical_and(m, ImageChops.invert(layer)) if hole else ImageChops.logical_or(m, layer)
            mask = ImageChops.logical_or(mask, m)
        a = mask.convert("L").reduce(ss)
        rgb = tuple(int(colour[i:i + 2], 16) for i in (1, 3, 5))
        layer = Image.new("RGBA", (w, h), rgb + (0,))
        layer.putalpha(a)
        img = Image.alpha_composite(img, layer)
    return img


def save_png(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, format="PNG", optimize=False)


def icon_png(size):
    ss = 8 if size <= 64 else 4
    return raster(size, size, icon_shapes(size), ss=ss)


def write_pngs():
    for s in (16, 32, 64, 128, 256, 512, 1024):
        save_png(icon_png(s), f"{APPICON}/icon_{s}.png")
    # 1280x640 social preview: reversed lockup centred on emberInk
    sym, word, w, h = lockup(0)
    k = min(0.56 * 1280 / w, 0.5 * 640 / h)
    ox, oy = (1280 - w * k) / 2, (640 - h * k) / 2
    sh = [([xform(p, k, ox, oy) for p in sym], EMBER), ([xform(p, k, ox, oy) for p in word], WHITE)]
    save_png(raster(1280, 640, sh, bg=INK, ss=4), f"{EXPORT}/social-preview.png")


# ----------------------------------------------------------------------------------------------
def ladder(path):
    """icon at 16/32/60/180/1024 on #F2F2F7 and #1C1C1E; 1024 shown at 400 px, the rest at true size."""
    sizes = [16, 32, 60, 180]
    big = icon_png(1024).resize((400, 400), Image.LANCZOS)
    row_w = 40 + 400 + 40 + sum(s + 40 for s in sizes) + 20
    row_h = 480
    out = Image.new("RGB", (row_w, row_h * 2), "#F2F2F7")
    for r, bg in enumerate(("#F2F2F7", "#1C1C1E")):
        ImageDraw.Draw(out).rectangle([0, r * row_h, row_w, (r + 1) * row_h], fill=bg)
        x = 40
        out.paste(big, (x, r * row_h + 40), big)
        x += 440
        for s in sizes:
            im = icon_png(s)
            out.paste(im, (x, r * row_h + 40 + 400 - s), im)
            x += s + 40
    out.save(path)


def main():
    write_svgs()
    write_pngs()
    if "--ladder" in sys.argv:
        ladder(sys.argv[sys.argv.index("--ladder") + 1])
    print("ok")


if __name__ == "__main__":
    main()
