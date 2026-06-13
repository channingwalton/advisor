#!/usr/bin/env python3
"""Generate the Advisor app icon.

A voice waveform rising into an "insight" spark, on a blue->indigo
depth-gradient squircle. Writes the master PNG and the full macOS .iconset
(every size iconutil needs) next to this script:

    AppIcon-1024.png            master
    AppIcon.iconset/*.png       16..1024, @1x/@2x

package.sh compiles AppIcon.iconset -> AppIcon.icns at packaging time, so just
re-run this and repackage after fiddling.

Deps:  python3 -m pip install pillow numpy
Run:   python3 make-icon.py
"""

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# ---------------------------------------------------------------- knobs ----
S = 1024            # master canvas (px)
SS = 4              # supersample factor — render big, downscale for clean edges
N = S * SS

MARGIN = 0.86       # icon body as a fraction of the canvas (rest is shadow gap)
SQUIRCLE_EXP = 5.0  # superellipse exponent — higher = squarer corners

C_TL = (86, 152, 255)   # gradient top-left   (bright blue)
C_BR = (72, 58, 222)    # gradient bottom-right (indigo violet)

# Waveform bars: heights as a fraction of N, left -> right.
BAR_HEIGHTS = [0.28, 0.50, 0.66, 0.50, 0.33]
BAR_W = 0.050           # bar width   (fraction of N)
BAR_GAP = 0.052         # gap between bars
BAR_X0 = 0.185          # left edge of first bar
BAR_CY = 0.52           # vertical centre line of the wave

SPARK = (0.755, 0.335, 0.105, 0.020)   # cx, cy, radius, waist (fractions of N)

# iconset entries: filename -> pixel size
ICONSET = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}

HERE = Path(__file__).resolve().parent


# --------------------------------------------------------------- helpers ----
def squircle_mask(size, body, exp):
    """Anti-aliased superellipse mask, `body` px wide, centred."""
    a = body / 2.0
    c = size / 2.0
    ys, xs = np.mgrid[0:size, 0:size]
    dx = np.abs(xs + 0.5 - c) / a
    dy = np.abs(ys + 0.5 - c) / a
    v = dx**exp + dy**exp
    edge = 0.06
    alpha = np.clip(1.0 - (v - 1.0) / edge, 0, 1)
    alpha = np.where(v <= 1.0, 1.0, alpha)
    return Image.fromarray((alpha * 255).astype("uint8"), "L")


def diagonal_gradient(size, c_tl, c_br):
    ys, xs = np.mgrid[0:size, 0:size]
    t = (xs + ys) / (2.0 * (size - 1))
    img = np.zeros((size, size, 3), dtype="uint8")
    for i in range(3):
        img[..., i] = (c_tl[i] + (c_br[i] - c_tl[i]) * t).astype("uint8")
    return Image.fromarray(img, "RGB")


def star4(draw, cx, cy, R, waist, col):
    """A 4-point insight spark."""
    pts = []
    for k in range(4):
        a0 = math.radians(90 * k)
        a1 = math.radians(90 * k + 45)
        pts.append((cx + R * math.cos(a0), cy - R * math.sin(a0)))
        pts.append((cx + waist * math.cos(a1), cy - waist * math.sin(a1)))
    draw.polygon(pts, fill=col)


def render():
    mask = squircle_mask(N, int(N * MARGIN), SQUIRCLE_EXP)

    # tile: gradient + top highlight + bottom shade, clipped to the squircle
    grad = diagonal_gradient(N, C_TL, C_BR).convert("RGBA")

    ys, xs = np.mgrid[0:N, 0:N]
    r = np.sqrt((xs - N * 0.5) ** 2 + (ys - N * 0.28) ** 2) / (N * 0.62)
    hi = np.clip(1.0 - r, 0, 1) ** 2
    hi_img = np.zeros((N, N, 4), dtype="uint8")
    hi_img[..., 0:3] = 255
    hi_img[..., 3] = (hi * 72).astype("uint8")
    highlight = Image.fromarray(hi_img, "RGBA")

    bot = np.clip((ys / N - 0.55) / 0.45, 0, 1) ** 2
    sh_img = np.zeros((N, N, 4), dtype="uint8")
    sh_img[..., 3] = (bot * 64).astype("uint8")
    shade = Image.fromarray(sh_img, "RGBA")

    tile = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    tile = Image.alpha_composite(tile, grad)
    tile = Image.alpha_composite(tile, highlight)
    tile = Image.alpha_composite(tile, shade)
    tile.putalpha(mask)

    # soft rim light along the top edge
    edge = mask.filter(ImageFilter.FIND_EDGES)
    edge_up = edge.point(lambda v: 200 if v > 40 else 0).filter(
        ImageFilter.GaussianBlur(N * 0.004)
    )
    ea = np.array(edge_up).astype("float")
    ea[int(N * 0.5):, :] *= 0.12
    rim_arr = np.zeros((N, N, 4), dtype="uint8")
    rim_arr[..., 0:3] = 255
    rim_arr[..., 3] = np.minimum(ea * 0.55, np.array(mask)).astype("uint8")
    tile = Image.alpha_composite(tile, Image.fromarray(rim_arr, "RGBA"))

    # foreground: waveform -> spark
    fg = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(fg)
    white = (255, 255, 255, 255)
    bw, gap, cy_line = N * BAR_W, N * BAR_GAP, N * BAR_CY
    last_cx = last_top = None
    for i, hf in enumerate(BAR_HEIGHTS):
        h = N * hf
        x = N * BAR_X0 + i * (bw + gap)
        d.rounded_rectangle(
            [x, cy_line - h / 2, x + bw, cy_line + h / 2], radius=bw / 2, fill=white
        )
        last_cx, last_top = x + bw / 2, cy_line - h / 2

    scx, scy, sR, sw = (v * N for v in SPARK)
    star4(d, scx, scy, sR, sw, white)
    # bridging mini-sparkle between the last bar and the spark
    star4(
        d,
        (last_cx + scx) / 2 + N * 0.01,
        (last_top + scy) / 2 - N * 0.02,
        N * 0.034,
        N * 0.007,
        white,
    )

    glow = fg.filter(ImageFilter.GaussianBlur(N * 0.013))
    ga = np.array(glow)
    ga[..., 3] = (ga[..., 3] * 0.50).astype("uint8")

    art = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    art = Image.alpha_composite(art, Image.fromarray(ga, "RGBA"))
    art = Image.alpha_composite(art, fg)
    art.putalpha(
        Image.fromarray(
            np.minimum(np.array(art.split()[3]), np.array(mask)).astype("uint8")
        )
    )

    icon = Image.alpha_composite(tile, art)

    # outer drop shadow within the margin
    sh = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    sh.putalpha(mask)
    sa = np.array(sh)
    sa[..., 0:3] = 0
    sa[..., 3] = (sa[..., 3] * 0.30).astype("uint8")
    sh = Image.fromarray(sa, "RGBA").filter(ImageFilter.GaussianBlur(N * 0.018))
    sh = Image.fromarray(np.roll(np.array(sh), int(N * 0.012), axis=0))

    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    canvas = Image.alpha_composite(canvas, sh)
    canvas = Image.alpha_composite(canvas, icon)
    return canvas


def main():
    canvas = render()

    master = HERE / "AppIcon-1024.png"
    canvas.resize((S, S), Image.LANCZOS).save(master)
    print(f"wrote {master.name}")

    iconset = HERE / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for name, px in ICONSET.items():
        canvas.resize((px, px), Image.LANCZOS).save(iconset / name)
    print(f"wrote {len(ICONSET)} sizes -> {iconset.name}/")
    print("next: sh package.sh  (compiles AppIcon.icns via iconutil)")


if __name__ == "__main__":
    main()
