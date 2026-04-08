#!/usr/bin/env python3
"""Generate the Witzper macOS app icon set + menu-bar template.

Pure Pillow. Renders at 4x supersample, downsamples with LANCZOS for AA edges.

Design: rounded-rect (squircle-ish) with a midnight-blue -> amber linear
gradient background. Foreground mark is a stylized "W" whose lower edge
emits 3 concentric soundwave arcs — the W is "speaking".
"""
from __future__ import annotations

import math
import os
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"
ICONSET = ASSETS / "AppIcon.iconset"

MASTER = 1024
SS = 4  # supersample factor
W = MASTER * SS

# Colours
TOP_LEFT = (16, 18, 32)        # deep midnight
BOTTOM_RIGHT = (255, 150, 24)  # vivid amber
MARK = (255, 245, 224)         # warm white
CORNER_RADIUS = 230            # at 1024


# ---------------------------------------------------------------------------
# Background
# ---------------------------------------------------------------------------
def make_gradient(size: int) -> Image.Image:
    """Diagonal linear gradient top-left -> bottom-right, built fast via
    a small gradient strip rotated/resized — avoids per-pixel Python loops."""
    # Build a 1xN strip then stretch + rotate to cover the diagonal.
    n = 512
    strip = Image.new("RGB", (n, 1))
    px = strip.load()
    for i in range(n):
        t = i / (n - 1)
        # Smoothstep for richer midtones
        ts = t * t * (3 - 2 * t)
        r = int(TOP_LEFT[0] + (BOTTOM_RIGHT[0] - TOP_LEFT[0]) * ts)
        g = int(TOP_LEFT[1] + (BOTTOM_RIGHT[1] - TOP_LEFT[1]) * ts)
        b = int(TOP_LEFT[2] + (BOTTOM_RIGHT[2] - TOP_LEFT[2]) * ts)
        px[i, 0] = (r, g, b)
    # Stretch to a tall rectangle then rotate 45° and centre-crop.
    big = strip.resize((int(size * 1.6), int(size * 1.6)), Image.BILINEAR)
    big = big.rotate(-45, resample=Image.BICUBIC, expand=False)
    left = (big.width - size) // 2
    top = (big.height - size) // 2
    return big.crop((left, top, left + size, top + size))


def add_radial_highlight(img: Image.Image) -> None:
    """Soft white radial glow near top-left for depth."""
    size = img.width
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    cx, cy = size * 0.32, size * 0.22
    max_r = size * 0.55
    steps = 60
    for i in range(steps, 0, -1):
        a = int(38 * (i / steps) ** 2)
        r = max_r * (1 - i / steps) + 20
        d.ellipse((cx - r, cy - r, cx + r, cy + r),
                  fill=(255, 255, 255, a))
    overlay = overlay.filter(ImageFilter.GaussianBlur(size * 0.04))
    img.alpha_composite(overlay)


# ---------------------------------------------------------------------------
# Squircle mask + edge polish
# ---------------------------------------------------------------------------
def squircle_mask(size: int, radius: int) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=radius, fill=255
    )
    return m


def edge_polish(img: Image.Image, radius: int) -> None:
    """Inner top highlight + inner bottom shadow + 1px outer dark border."""
    size = img.width
    # Inner highlight (top)
    hl = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(hl)
    for i in range(int(size * 0.012)):
        a = int(120 * (1 - i / (size * 0.012)))
        d.rounded_rectangle(
            (i, i, size - 1 - i, size - 1 - i),
            radius=radius - i, outline=(255, 255, 255, a), width=1,
        )
    # Mask to top half only
    half = Image.new("L", (size, size), 0)
    ImageDraw.Draw(half).rectangle((0, 0, size, size // 2), fill=255)
    half = half.filter(ImageFilter.GaussianBlur(size * 0.05))
    hl.putalpha(Image.eval(
        Image.merge("L", (Image.eval(hl.split()[3], lambda v: v),)),
        lambda v: v).point(lambda v: v))
    img.alpha_composite(Image.composite(hl, Image.new("RGBA", hl.size), half))

    # Inner bottom shadow
    sh = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(sh)
    for i in range(int(size * 0.02)):
        a = int(110 * (1 - i / (size * 0.02)))
        d.rounded_rectangle(
            (i, i, size - 1 - i, size - 1 - i),
            radius=radius - i, outline=(0, 0, 0, a), width=1,
        )
    bot = Image.new("L", (size, size), 0)
    ImageDraw.Draw(bot).rectangle((0, size // 2, size, size), fill=255)
    bot = bot.filter(ImageFilter.GaussianBlur(size * 0.05))
    img.alpha_composite(Image.composite(sh, Image.new("RGBA", sh.size), bot))

    # Crisp 1px-equivalent outer dark border
    border = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=radius,
        outline=(0, 0, 0, 180), width=max(2, size // 512),
    )
    img.alpha_composite(border)


# ---------------------------------------------------------------------------
# The "W + soundwave" mark
# ---------------------------------------------------------------------------
def draw_w_mark(size: int, color=(255, 245, 224, 255), stroke_scale=1.0,
                with_glow=True) -> Image.Image:
    """Returns an RGBA image (size x size) with a centred W-mark on transparent.

    The W is drawn as 4 thick line segments (V-V), and 3 soundwave arcs
    sit above/around it suggesting voice emanating outward.
    """
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    cx, cy = size / 2, size / 2
    # W geometry
    w_width = size * 0.56
    w_height = size * 0.40
    stroke = int(size * 0.085 * stroke_scale)

    left = cx - w_width / 2
    right = cx + w_width / 2
    top = cy - w_height * 0.30
    bot = cy + w_height * 0.55

    # Five anchor points of the W
    p1 = (left, top)
    p2 = (left + w_width * 0.25, bot)
    p3 = (cx, top + w_height * 0.30)
    p4 = (right - w_width * 0.25, bot)
    p5 = (right, top)

    def line(a, b):
        d.line([a, b], fill=color, width=stroke,
               joint="curve")

    # Round caps via filled circles at each anchor
    def cap(p):
        r = stroke / 2
        d.ellipse((p[0] - r, p[1] - r, p[0] + r, p[1] + r), fill=color)

    for a, b in ((p1, p2), (p2, p3), (p3, p4), (p4, p5)):
        line(a, b)
    for p in (p1, p2, p3, p4, p5):
        cap(p)

    # Soundwave arcs above the W (concentric, opening upward)
    arc_cx = cx
    arc_cy = top - size * 0.02
    arc_stroke = max(2, int(stroke * 0.55))
    for i, radius_frac in enumerate((0.18, 0.27, 0.36)):
        r = size * radius_frac
        bbox = (arc_cx - r, arc_cy - r, arc_cx + r, arc_cy + r)
        # arc opening upward: 200° -> 340°
        d.arc(bbox, start=200, end=340, fill=color, width=arc_stroke)

    return img


def add_mark_glow(mark: Image.Image) -> Image.Image:
    """Soft inner glow around the W for that 'lit' look."""
    glow = mark.copy()
    glow = glow.filter(ImageFilter.GaussianBlur(mark.width * 0.012))
    out = Image.new("RGBA", mark.size, (0, 0, 0, 0))
    # Tinted warm glow
    tint = Image.new("RGBA", mark.size, (255, 230, 180, 0))
    tint.putalpha(glow.split()[3].point(lambda v: int(v * 0.45)))
    out.alpha_composite(tint)
    out.alpha_composite(mark)
    return out


# ---------------------------------------------------------------------------
# Master compose
# ---------------------------------------------------------------------------
def build_master() -> Image.Image:
    size = W
    radius = int(CORNER_RADIUS * SS)

    # Background gradient
    bg = make_gradient(size).convert("RGBA")
    add_radial_highlight(bg)

    # Mark
    mark = draw_w_mark(size)
    mark = add_mark_glow(mark)
    bg.alpha_composite(mark)

    # Edge polish
    edge_polish(bg, radius)

    # Mask to squircle
    mask = squircle_mask(size, radius)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(bg, (0, 0), mask)

    # Downsample to 1024
    return out.resize((MASTER, MASTER), Image.LANCZOS)


# ---------------------------------------------------------------------------
# Menu bar template
# ---------------------------------------------------------------------------
def build_menubar() -> Image.Image:
    # Render at 8x then downsample for crisp edges at 44px
    s = 44 * 8
    img = draw_w_mark(s, color=(255, 255, 255, 255), stroke_scale=1.25,
                      with_glow=False)
    return img.resize((44, 44), Image.LANCZOS)


# ---------------------------------------------------------------------------
# Iconset emit
# ---------------------------------------------------------------------------
ICONSET_SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    ICONSET.mkdir(parents=True, exist_ok=True)

    print("→ rendering 1024 master")
    master = build_master()
    master_path = ASSETS / "icon-1024.png"
    master.save(master_path)
    print(f"  wrote {master_path}")

    print("→ emitting iconset")
    for name, px in ICONSET_SIZES:
        out = master.resize((px, px), Image.LANCZOS)
        p = ICONSET / name
        out.save(p)
        print(f"  {name}  ({px}x{px})")

    print("→ menu bar template")
    mb = build_menubar()
    mb.save(ASSETS / "MenuBarIcon.png")

    print("→ iconutil → .icns")
    icns = ASSETS / "AppIcon.icns"
    subprocess.run(
        ["iconutil", "-c", "icns", str(ICONSET), "-o", str(icns)],
        check=True,
    )
    print(f"  wrote {icns} ({icns.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
