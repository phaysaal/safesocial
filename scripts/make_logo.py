#!/usr/bin/env python3
"""Draw the Spheres mark and every launcher size from it.

One shaded sphere, split by a lazy S into three bands: rose on top, violet,
teal underneath. The seams wrap around the ball in latitude and longitude,
so the bands curve away at the edges; each band's lip throws a soft shadow
on the band below, one light from the top left gives a single highlight,
and the ball sits on a faint ground shadow. The S is for Spheres; the ball
is one. Crisp silhouette, so it holds at 48 px and in the header.

Writes:
  safesocial_app/assets/images/logo.png            1024 px, transparent
  safesocial_app/assets/images/icon_1024.png       same, on the icon background
  safesocial_app/android/.../mipmap-*/ic_launcher_foreground.png  (adaptive, no ground shadow)
  safesocial_app/android/.../mipmap-*/ic_launcher_monochrome.png  (themed icons, Android 13+)
  safesocial_app/android/.../mipmap-*/ic_launcher.png             (legacy)

Run from the repository root:  python3 scripts/make_logo.py
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent / "safesocial_app"
RES = ROOT / "android/app/src/main/res"

ROSE = (0xE2, 0x5A, 0x6B)
VIOLET = (0x8B, 0x5C, 0xF6)
TEAL = (0x2D, 0xB7, 0xA3)
BACKGROUND = (0xFF, 0xF8, 0xF7)

SS = 4  # supersampling for crisp edges
RADIUS = 0.36  # of the canvas, at scale 1
WAVE = 0.22  # how far the S swings up and down, in latitude (-1..1)
BAND = 0.36  # the two seams sit this far above and below the equator
LIP_SHADOW = 0.50  # how dark a band's shadow on the next is
LIGHT = (-0.30, -0.68, 0.66)  # from the top left, towards the viewer


def _blur(mask: np.ndarray, sigma: float) -> np.ndarray:
    """Gaussian blur of a 0..1 mask, through PIL so numpy and PIL stay the
    only dependencies."""
    img = Image.fromarray((np.clip(mask, 0, 1) * 255).astype(np.uint8), "L")
    return np.asarray(img.filter(ImageFilter.GaussianBlur(sigma)), dtype=np.float64) / 255.0


def mark(size: int, scale: float = 1.0, ground_shadow: bool = True) -> Image.Image:
    """The mark on a transparent square, the ball's diameter 2*RADIUS*scale of it.
    The adaptive launcher foreground goes without the ground shadow: the
    launcher draws its own under the tile, and two look wrong."""
    n = size * SS
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float64) / n
    xs, ys = (xs - 0.5) / scale, (ys - 0.5) / scale  # centred, unscaled units
    r = RADIUS

    # The ball: normals, one light, Blinn-Phong highlight, a little limb
    # darkening so it reads as a ball on a light background too.
    d2 = xs * xs + ys * ys
    inside = (d2 < r * r).astype(np.float64)
    nz = np.sqrt(np.clip(1 - d2 / (r * r), 0, 1))
    nx, ny = xs / r, ys / r
    light = np.array(LIGHT) / np.linalg.norm(LIGHT)
    half = light + np.array([0.0, 0.0, 1.0])
    half /= np.linalg.norm(half)
    diffuse = np.clip(nx * light[0] + ny * light[1] + nz * light[2], 0, 1)
    spec = np.clip(nx * half[0] + ny * half[1] + nz * half[2], 0, 1) ** 48
    shade = (0.42 + 0.62 * diffuse) * (0.80 + 0.20 * nz)

    # The bands, as regions of the ball's surface: the seams follow a sine
    # in longitude, so they wrap round rather than lying flat on the face.
    lon = np.arctan2(nx, np.maximum(nz, 1e-6))
    lat = ny

    def above(seam: float) -> np.ndarray:
        return (lat < seam + WAVE * np.sin(lon * 2.0)).astype(np.float64) * inside

    top = above(-BAND)
    mid = above(BAND) * (1 - top)
    bottom = inside * (1 - top) * (1 - mid)
    base = (np.array(TEAL) * bottom[..., None]
            + np.array(VIOLET) * mid[..., None]
            + np.array(ROSE) * top[..., None]) / 255.0
    colour = base * shade[..., None]
    colour = colour + 0.55 * spec[..., None] * (1 - colour)

    # Each lip's shadow on the band below.
    for upper, lower in ((top, mid), (top + mid, bottom)):
        shifted = np.roll(upper, int(0.016 * n * scale), axis=0)
        sh = _blur(shifted, 0.018 * n * scale) * (1 - upper) * lower
        colour = colour * (1 - LIP_SHADOW * sh)[..., None]

    out = np.dstack([np.clip(colour, 0, 1) * 255, inside[..., None] * 255.0]).astype(np.uint8)
    img = Image.fromarray(out, "RGBA")

    if not ground_shadow:
        return img.resize((size, size), Image.LANCZOS)
    # A soft ground shadow, so the ball sits on whatever is behind it.
    shadow = Image.new("L", (n, n), 0)
    c = n / 2
    sw, sh = 0.30 * n * scale, 0.05 * n * scale
    sx, sy = c + 0.01 * n * scale, c + 0.40 * n * scale
    ImageDraw.Draw(shadow).ellipse([sx - sw, sy - sh, sx + sw, sy + sh], fill=255)
    shadow = shadow.filter(ImageFilter.GaussianBlur(0.03 * n * scale))
    layer = Image.new("RGBA", (n, n), (40, 20, 50, 0))
    layer.putalpha(shadow.point(lambda v: int(v * 0.28)))
    layer.alpha_composite(img)
    return layer.resize((size, size), Image.LANCZOS)


def monochrome(size: int, scale: float = 1.0) -> Image.Image:
    """The themed-icon layer (Android 13+): only its alpha is used, the
    launcher tints it. A flat silhouette of the ball with the two seams cut
    through it as thin gaps, so a themed Spheres still shows the wave."""
    n = size * SS
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float64) / n
    xs, ys = (xs - 0.5) / scale, (ys - 0.5) / scale
    r = RADIUS
    d2 = xs * xs + ys * ys
    inside = d2 < r * r
    nz = np.sqrt(np.clip(1 - d2 / (r * r), 0, 1))
    nx, ny = xs / r, ys / r
    lon = np.arctan2(nx, np.maximum(nz, 1e-6))
    gap = 0.07  # in latitude units, so the seams stay visible at 48 dp
    seams = np.zeros_like(inside)
    for seam in (-BAND, BAND):
        seams |= np.abs(ny - (seam + WAVE * np.sin(lon * 2.0))) < gap
    alpha = (inside & ~seams) * 255.0
    out = np.dstack([np.full((n, n, 3), 255.0), alpha[..., None]]).astype(np.uint8)
    return Image.fromarray(out, "RGBA").resize((size, size), Image.LANCZOS)


def on_background(size: int, scale: float, radius_frac: float) -> Image.Image:
    """The mark on the icon background inside a rounded square."""
    n = size * SS
    base = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(base).rounded_rectangle(
        [0, 0, n - 1, n - 1], radius=radius_frac * n, fill=BACKGROUND + (255,))
    base = base.resize((size, size), Image.LANCZOS)
    base.alpha_composite(mark(size, scale))
    return base


def main() -> None:
    images = ROOT / "assets/images"
    mark(1024).save(images / "logo.png")
    on_background(1024, 0.95, 0.22).save(images / "icon_1024.png")

    # Adaptive icon: 108 dp canvas, 66 dp safe zone; the disc is 72% of the
    # mark, so 0.82 keeps it at 64 dp and clear of every mask shape.
    # Legacy icon: 48 dp, the disc on a rounded square.
    densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for name, k in densities.items():
        folder = RES / f"mipmap-{name}"
        folder.mkdir(exist_ok=True)
        mark(int(108 * k), 0.82, ground_shadow=False).save(folder / "ic_launcher_foreground.png")
        monochrome(int(108 * k), 0.82).save(folder / "ic_launcher_monochrome.png")
        on_background(int(48 * k), 0.95, 0.2).save(folder / "ic_launcher.png")

    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />\n'
        '</adaptive-icon>\n')
    (RES / "values/colors.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<resources>\n'
        '    <color name="ic_launcher_background">#%02X%02X%02X</color>\n'
        '</resources>\n' % BACKGROUND)
    print("logo and launcher icons written")


if __name__ == "__main__":
    main()
