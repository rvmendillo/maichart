#!/usr/bin/env python3
"""Generate the MaiChart Studio app icon (1024x1024, no alpha) with supersampling.

Original artwork: a glowing judgement ring with eight button pads, a radiant
star note in the middle and pink/cyan tap notes flying outwards.
"""
import math
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4            # supersampling factor
N = 1024 * S
CX = CY = N / 2


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def radial_bg():
    img = Image.new("RGB", (N, N))
    px = img.load()
    inner = (64, 22, 120)
    mid = (28, 12, 74)
    outer = (8, 6, 30)
    step = 4
    d = ImageDraw.Draw(img)
    for y in range(0, N, step):
        for x in range(0, N, step):
            r = math.hypot(x - CX, y - CY) / (N * 0.72)
            if r < 0.5:
                c = lerp(inner, mid, r / 0.5)
            else:
                c = lerp(mid, outer, min(1, (r - 0.5) / 0.5))
            d.rectangle([x, y, x + step, y + step], fill=c)
    return img


def glow_layer(draw_fn, blur):
    layer = Image.new("RGB", (N, N), (0, 0, 0))
    draw_fn(ImageDraw.Draw(layer))
    return layer.filter(ImageFilter.GaussianBlur(blur))


def star_points(cx, cy, r_out, r_in, n=5, rot=-90):
    pts = []
    for i in range(n * 2):
        r = r_out if i % 2 == 0 else r_in
        a = math.radians(rot + i * 180 / n)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def main(out):
    img = radial_bg()
    ring_r = N * 0.36
    ring_w = N * 0.028

    # faint lane guides
    def guides(d):
        for k in range(8):
            a = math.radians(-90 + 22.5 + 45 * k)
            d.line([(CX, CY), (CX + ring_r * math.cos(a), CY + ring_r * math.sin(a))],
                   fill=(120, 90, 200), width=int(N * 0.004))
    img = ImageChops.add(img, glow_layer(guides, N * 0.002))

    # outer glow of the ring
    def ring(d, w=ring_w, col=(255, 255, 255)):
        d.ellipse([CX - ring_r, CY - ring_r, CX + ring_r, CY + ring_r], outline=col, width=int(w))
    img = ImageChops.add(img, glow_layer(lambda d: ring(d, ring_w * 2.2, (255, 70, 190)), N * 0.03))
    img = ImageChops.add(img, glow_layer(lambda d: ring(d, ring_w * 1.4, (90, 220, 255)), N * 0.012))
    d = ImageDraw.Draw(img)
    ring(d, ring_w, (255, 255, 255))

    # eight button pads
    for k in range(8):
        a = math.radians(-90 + 22.5 + 45 * k)
        bx, by = CX + ring_r * 1.17 * math.cos(a), CY + ring_r * 1.17 * math.sin(a)
        br = N * 0.032
        col = (255, 214, 64) if k in (0, 7) else (255, 255, 255)
        d.ellipse([bx - br, by - br, bx + br, by + br], fill=col)

    # tap notes on the ring (pink single, yellow each pair)
    def tap(d, cx, cy, r, col):
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=col, width=int(N * 0.022))
    notes = [(2, 0.80, (255, 80, 200)), (5, 0.62, (255, 80, 200)),
             (3, 0.45, (255, 214, 64)), (4, 0.45, (255, 214, 64))]
    for k, dist, col in notes:
        a = math.radians(-90 + 22.5 + 45 * k)
        cx, cy = CX + ring_r * dist * math.cos(a), CY + ring_r * dist * math.sin(a)
        r = N * (0.03 + 0.035 * dist)
        img = ImageChops.add(img, glow_layer(lambda dd: tap(dd, cx, cy, r, col), N * 0.01))
        d = ImageDraw.Draw(img)
        tap(d, cx, cy, r, (255, 255, 255))
        d.ellipse([cx - r * 0.78, cy - r * 0.78, cx + r * 0.78, cy + r * 0.78],
                  outline=col, width=int(N * 0.012))

    # radiant centre star
    pts = star_points(CX, CY - N * 0.01, N * 0.16, N * 0.07)
    img = ImageChops.add(img, glow_layer(lambda dd: dd.polygon(pts, fill=(60, 200, 255)), N * 0.04))
    d = ImageDraw.Draw(img)
    d.polygon(pts, fill=(255, 255, 255))
    inner = star_points(CX, CY - N * 0.01, N * 0.115, N * 0.05)
    d.polygon(inner, fill=(70, 190, 255))
    core = star_points(CX, CY - N * 0.01, N * 0.06, N * 0.026)
    d.polygon(core, fill=(220, 250, 255))

    # sparkles
    import random
    rnd = random.Random(7)
    for _ in range(26):
        a = rnd.uniform(0, math.tau)
        r = rnd.uniform(N * 0.12, N * 0.47)
        x, y = CX + r * math.cos(a), CY + r * math.sin(a)
        s = rnd.uniform(N * 0.003, N * 0.009)
        d.polygon(star_points(x, y, s * 2.4, s * 0.6, 4, 0), fill=(255, 240, 255))

    img = img.resize((1024, 1024), Image.LANCZOS)
    img.save(out, "PNG")
    print("wrote", out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png")
