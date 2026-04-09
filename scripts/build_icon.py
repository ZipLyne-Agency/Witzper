#!/usr/bin/env python3
"""Generate the Witzper macOS app icon set + menu-bar template.

Pure Pillow. Renders at 4x supersample, downsamples with LANCZOS for AA edges.

Design (v2): a refined squircle with a deep indigo -> violet -> coral diagonal
gradient, a soft top-left highlight, and a centred audio-waveform mark — seven
rounded vertical bars whose heights form a smooth, symmetric envelope. The
mark is the universal "voice" glyph and reads cleanly at every size, including
16px. Menu-bar template is a monochrome version of the same bars.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"
ICONSET = ASSETS / "AppIcon.iconset"

MASTER = 1024
SS = 4  # supersample factor
W = MASTER * SS

# Three-stop diagonal gradient — modern, premium, voice-AI vibe
STOPS = [
    (0.00, (15, 17, 46)),     # near-black indigo
    (0.55, (88, 28, 135)),    # royal violet
    (1.00, (244, 114, 95)),   # warm coral
]
MARK = (255, 250, 240)        # warm white
CORNER_RADIUS = 230           # at 1024 (matches macOS Big Sur+ squircle)


# ---------------------------------------------------------------------------
# Background
# ---------------------------------------------------------------------------
def _lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def _sample_stops(t: float):
    for i in range(len(STOPS) - 1):
        t0, c0 = STOPS[i]
        t1, c1 = STOPS[i + 1]
        if t <= t1:
            u = (t - t0) / (t1 - t0) if t1 > t0 else 0
            u = u * u * (3 - 2 * u)  # smoothstep
            return _lerp(c0, c1, u)
    return STOPS[-1][1]


def make_gradient(size: int) -> Image.Image:
    """Diagonal multi-stop gradient via a 1xN strip rotated 45° and cropped."""
    n = 1024
    strip = Image.new("RGB", (n, 1))
    px = strip.load()
    for i in range(n):
        px[i, 0] = _sample_stops(i / (n - 1))
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
    cx, cy = size * 0.30, size * 0.20
    max_r = size * 0.62
    steps = 80
    for i in range(steps, 0, -1):
        a = int(48 * (i / steps) ** 2)
        r = max_r * (1 - i / steps) + 20
        d.ellipse((cx - r, cy - r, cx + r, cy + r),
                  fill=(255, 255, 255, a))
    overlay = overlay.filter(ImageFilter.GaussianBlur(size * 0.05))
    img.alpha_composite(overlay)


def add_bottom_shade(img: Image.Image) -> None:
    """Subtle dark vignette at the bottom for grounding."""
    size = img.width
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    cx, cy = size * 0.70, size * 1.05
    max_r = size * 0.85
    steps = 60
    for i in range(steps, 0, -1):
        a = int(70 * (i / steps) ** 2)
        r = max_r * (1 - i / steps) + 20
        d.ellipse((cx - r, cy - r, cx + r, cy + r),
                  fill=(0, 0, 0, a))
    overlay = overlay.filter(ImageFilter.GaussianBlur(size * 0.06))
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
    """Inner top highlight + inner bottom shadow + crisp outer dark border."""
    size = img.width

    # Inner top highlight
    hl = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(hl)
    band = int(size * 0.014)
    for i in range(band):
        a = int(150 * (1 - i / band))
        d.rounded_rectangle(
            (i, i, size - 1 - i, size - 1 - i),
            radius=radius - i, outline=(255, 255, 255, a), width=1,
        )
    half = Image.new("L", (size, size), 0)
    ImageDraw.Draw(half).rectangle((0, 0, size, size // 2), fill=255)
    half = half.filter(ImageFilter.GaussianBlur(size * 0.05))
    img.alpha_composite(Image.composite(hl, Image.new("RGBA", hl.size), half))

    # Inner bottom shadow
    sh = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(sh)
    band = int(size * 0.022)
    for i in range(band):
        a = int(130 * (1 - i / band))
        d.rounded_rectangle(
            (i, i, size - 1 - i, size - 1 - i),
            radius=radius - i, outline=(0, 0, 0, a), width=1,
        )
    bot = Image.new("L", (size, size), 0)
    ImageDraw.Draw(bot).rectangle((0, size // 2, size, size), fill=255)
    bot = bot.filter(ImageFilter.GaussianBlur(size * 0.05))
    img.alpha_composite(Image.composite(sh, Image.new("RGBA", sh.size), bot))

    # Crisp outer dark border
    border = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=radius,
        outline=(0, 0, 0, 200), width=max(2, size // 512),
    )
    img.alpha_composite(border)


# ---------------------------------------------------------------------------
# Waveform mark
# ---------------------------------------------------------------------------
# Symmetric envelope, classic equaliser feel — reads at every size.
BAR_HEIGHTS = (0.34, 0.58, 0.84, 1.00, 0.84, 0.58, 0.34)


def draw_waveform(size: int, color=(255, 250, 240, 255)) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    n = len(BAR_HEIGHTS)
    field_w = size * 0.62
    max_h = size * 0.58
    bar_w = field_w / (n * 1.85)
    gap = (field_w - bar_w * n) / (n - 1)

    cx, cy = size / 2, size / 2
    left0 = cx - field_w / 2
    r = bar_w / 2  # rounded cap radius

    for i, h_frac in enumerate(BAR_HEIGHTS):
        h = max_h * h_frac
        x0 = left0 + i * (bar_w + gap)
        x1 = x0 + bar_w
        y0 = cy - h / 2
        y1 = cy + h / 2
        d.rounded_rectangle((x0, y0, x1, y1), radius=r, fill=color)

    return img


def add_mark_glow(mark: Image.Image) -> Image.Image:
    """Warm soft glow behind the bars."""
    size = mark.width
    glow = mark.filter(ImageFilter.GaussianBlur(size * 0.020))
    tint = Image.new("RGBA", mark.size, (255, 220, 170, 0))
    tint.putalpha(glow.split()[3].point(lambda v: int(v * 0.55)))
    out = Image.new("RGBA", mark.size, (0, 0, 0, 0))
    out.alpha_composite(tint)
    out.alpha_composite(mark)
    return out


# ---------------------------------------------------------------------------
# Master compose
# ---------------------------------------------------------------------------
def build_master() -> Image.Image:
    size = W
    radius = int(CORNER_RADIUS * SS)

    bg = make_gradient(size).convert("RGBA")
    add_radial_highlight(bg)
    add_bottom_shade(bg)

    mark = draw_waveform(size)
    mark = add_mark_glow(mark)
    bg.alpha_composite(mark)

    edge_polish(bg, radius)

    mask = squircle_mask(size, radius)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(bg, (0, 0), mask)

    return out.resize((MASTER, MASTER), Image.LANCZOS)


# ---------------------------------------------------------------------------
# Menu bar template (monochrome, transparent bg)
# ---------------------------------------------------------------------------
def build_menubar() -> Image.Image:
    s = 44 * 8
    img = draw_waveform(s, color=(255, 255, 255, 255))
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
