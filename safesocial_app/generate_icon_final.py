"""
Spheres app icon — three cascading 3D spheres with strong shading.
Darker edges, bright center highlight, pronounced depth.
"""

from PIL import Image, ImageDraw, ImageFilter
import math
import os

SIZE = 1024
CX, CY = SIZE // 2, SIZE // 2
BASE = "/home/faisal/code/hobby/SafeSelf/safesocial/safesocial_app"


def draw_3d_sphere(img, cx, cy, r, base_color, alpha=180):
    """Draw a sphere with radial gradient: bright center, dark edges."""
    # Build the sphere pixel-by-pixel for true radial gradient
    sphere = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # Light source: upper-left
    light_x = cx - r * 0.3
    light_y = cy - r * 0.35

    br, bg_c, bb = base_color

    for y_off in range(-r, r + 1):
        for x_off in range(-r, r + 1):
            dist_from_center = math.sqrt(x_off * x_off + y_off * y_off)
            if dist_from_center > r:
                continue

            px = cx + x_off
            py = cy + y_off

            # Distance from light source (normalized 0-1)
            dist_from_light = math.sqrt(
                (px - light_x) ** 2 + (py - light_y) ** 2
            )
            light_factor = min(dist_from_light / (r * 1.4), 1.0)

            # Edge darkening (normalized 0-1, 0 = center, 1 = edge)
            edge_factor = dist_from_center / r

            # Combine: near light = bright, far from light + near edge = dark
            darkness = light_factor * 0.6 + edge_factor * 0.4

            # Color: blend from bright (white-ish) to dark (deeper base color)
            pr = int(br + (255 - br) * (1 - darkness) * 0.7)
            pg = int(bg_c + (255 - bg_c) * (1 - darkness) * 0.7)
            pb = int(bb + (255 - bb) * (1 - darkness) * 0.7)

            # Darken edges more
            edge_darken = edge_factor ** 2 * 0.4
            pr = int(pr * (1 - edge_darken))
            pg = int(pg * (1 - edge_darken))
            pb = int(pb * (1 - edge_darken))

            # Alpha: slightly fade at very edge for softness
            pa = alpha
            if edge_factor > 0.9:
                pa = int(alpha * (1 - (edge_factor - 0.9) / 0.1 * 0.3))

            sphere.putpixel((px, py), (
                max(0, min(255, pr)),
                max(0, min(255, pg)),
                max(0, min(255, pb)),
                pa,
            ))

    # Add a crisp specular highlight
    spec = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(spec)
    # Primary highlight
    sr = int(r * 0.22)
    sx = int(light_x)
    sy = int(light_y)
    sd.ellipse([sx - sr, sy - sr, sx + sr, sy + sr], fill=(255, 255, 255, 120))
    spec = spec.filter(ImageFilter.GaussianBlur(radius=sr * 0.6))

    # Small sharp specular dot
    spec2 = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sd2 = ImageDraw.Draw(spec2)
    sr2 = int(r * 0.08)
    sd2.ellipse([sx - sr2, sy - sr2, sx + sr2, sy + sr2], fill=(255, 255, 255, 200))
    spec2 = spec2.filter(ImageFilter.GaussianBlur(radius=sr2 * 0.4))

    img = Image.alpha_composite(img, sphere)
    img = Image.alpha_composite(img, spec)
    img = Image.alpha_composite(img, spec2)
    return img


def main():
    # White rounded-square background
    bg = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(bg)
    r = int(SIZE * 0.22)
    draw.rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=r, fill=(255, 255, 255, 255))

    # Three cascading 3D spheres — enlarged, darker, saturated
    bg = draw_3d_sphere(bg, CX - 150, CY - 110, 280, (200, 50, 75), alpha=200)   # Deep coral
    bg = draw_3d_sphere(bg, CX + 70, CY + 50, 320, (100, 40, 190), alpha=190)    # Deep purple
    bg = draw_3d_sphere(bg, CX + 270, CY + 240, 185, (30, 140, 140), alpha=200)  # Deep teal

    # Save
    os.makedirs(f"{BASE}/assets/images", exist_ok=True)
    bg.save(f"{BASE}/assets/images/icon_1024.png", "PNG")
    bg.save(f"{BASE}/assets/images/logo.png", "PNG")

    # Android mipmap sizes
    res_dir = f"{BASE}/android/app/src/main/res"
    for folder, sz in [
        ("mipmap-mdpi", 48),
        ("mipmap-hdpi", 72),
        ("mipmap-xhdpi", 96),
        ("mipmap-xxhdpi", 144),
        ("mipmap-xxxhdpi", 192),
    ]:
        resized = bg.resize((sz, sz), Image.LANCZOS)
        resized.save(f"{res_dir}/{folder}/ic_launcher.png", "PNG")

        fg_size = int(sz * 108 / 48)
        fg = Image.new("RGBA", (fg_size, fg_size), (0, 0, 0, 0))
        pad = (fg_size - sz) // 2
        fg.paste(resized, (pad, pad))
        fg.save(f"{res_dir}/{folder}/ic_launcher_foreground.png", "PNG")

    print("Done! 3D Spheres icon generated.")


if __name__ == "__main__":
    main()
