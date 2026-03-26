"""
Generate Spheres logo candidates:
A: Two spheres — large + small, transparent, overlapping
B: Three semi-transparent spheres intersecting (Venn-style)
C: Two intersecting spheres with a small keyhole/lock accent
D: Three spheres in a diagonal cascade
"""

from PIL import Image, ImageDraw, ImageFilter
import math

SIZE = 1024
CX, CY = SIZE // 2, SIZE // 2
BASE = "/home/faisal/code/hobby/SafeSelf/safesocial/safesocial_app/assets/images"


def make_canvas():
    return Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))


def draw_sphere(img, cx, cy, r, color, alpha=140):
    """Draw a semi-transparent sphere with gradient shading for 3D effect."""
    overlay = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    # Base circle
    draw.ellipse(
        [cx - r, cy - r, cx + r, cy + r],
        fill=color + (alpha,),
    )

    # Highlight (upper-left for 3D)
    highlight = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    hd = ImageDraw.Draw(highlight)
    hr = int(r * 0.45)
    hx = cx - int(r * 0.25)
    hy = cy - int(r * 0.25)
    hd.ellipse(
        [hx - hr, hy - hr, hx + hr, hy + hr],
        fill=(255, 255, 255, 70),
    )
    highlight = highlight.filter(ImageFilter.GaussianBlur(radius=r * 0.3))

    # Shadow (bottom-right for depth)
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sr = int(r * 0.5)
    sx = cx + int(r * 0.15)
    sy = cy + int(r * 0.2)
    sd.ellipse(
        [sx - sr, sy - sr, sx + sr, sy + sr],
        fill=(0, 0, 0, 30),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=r * 0.25))

    img = Image.alpha_composite(img, overlay)
    img = Image.alpha_composite(img, shadow)
    img = Image.alpha_composite(img, highlight)
    return img


def draw_ring(img, cx, cy, r, color, width=6, alpha=200):
    """Draw a thin ring outline for a more elegant look."""
    overlay = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.ellipse(
        [cx - r, cy - r, cx + r, cy + r],
        outline=color + (alpha,), width=width,
    )
    return Image.alpha_composite(img, overlay)


# ─── Candidate A: Two spheres, large + small ─────────────────────────────────

def candidate_a():
    img = make_canvas()

    # Large sphere — coral/rose
    img = draw_sphere(img, CX - 40, CY + 20, 280, (220, 70, 90), alpha=130)

    # Small sphere — purple, overlapping top-right
    img = draw_sphere(img, CX + 200, CY - 180, 160, (120, 60, 210), alpha=150)

    return img


# ─── Candidate B: Three intersecting spheres (Venn) ──────────────────────────

def candidate_b():
    img = make_canvas()
    r = 210
    offset = 130

    # Three sphere positions (equilateral triangle)
    positions = [
        (CX, CY - offset),                                    # Top
        (CX - int(offset * 0.87), CY + int(offset * 0.5)),   # Bottom-left
        (CX + int(offset * 0.87), CY + int(offset * 0.5)),   # Bottom-right
    ]
    colors = [
        (220, 70, 90),   # Coral/rose
        (120, 60, 210),  # Purple
        (50, 160, 180),  # Teal
    ]

    for pos, color in zip(positions, colors):
        img = draw_sphere(img, pos[0], pos[1], r, color, alpha=100)

    return img


# ─── Candidate C: Two intersecting + small lock accent ───────────────────────

def candidate_c():
    img = make_canvas()

    # Two intersecting spheres
    img = draw_sphere(img, CX - 120, CY, 260, (220, 70, 90), alpha=120)
    img = draw_sphere(img, CX + 120, CY, 260, (120, 60, 210), alpha=120)

    # Small keyhole in the intersection
    overlay = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    # Lock circle
    draw.ellipse([CX - 22, CY - 30, CX + 22, CY + 14], fill=(255, 255, 255, 200))
    # Keyhole slot
    draw.polygon(
        [(CX - 8, CY + 8), (CX, CY + 40), (CX + 8, CY + 8)],
        fill=(255, 255, 255, 200),
    )
    # Keyhole inner
    draw.ellipse([CX - 8, CY - 16, CX + 8, CY], fill=(100, 60, 160, 180))
    draw.polygon(
        [(CX - 4, CY - 2), (CX, CY + 20), (CX + 4, CY - 2)],
        fill=(100, 60, 160, 180),
    )

    img = Image.alpha_composite(img, overlay)
    return img


# ─── Candidate D: Three spheres in diagonal cascade ──────────────────────────

def candidate_d():
    img = make_canvas()

    # Three spheres cascading diagonally, different sizes
    img = draw_sphere(img, CX - 180, CY - 140, 220, (220, 70, 90), alpha=110)
    img = draw_sphere(img, CX + 40, CY + 20, 260, (120, 60, 210), alpha=120)
    img = draw_sphere(img, CX + 230, CY + 200, 150, (50, 170, 160), alpha=140)

    return img


# ─── Candidate E: Two spheres with elegant ring outlines ─────────────────────

def candidate_e():
    img = make_canvas()

    # Large filled sphere
    img = draw_sphere(img, CX - 80, CY + 30, 280, (220, 70, 90), alpha=100)

    # Medium ring sphere overlapping
    img = draw_sphere(img, CX + 160, CY - 120, 200, (120, 60, 210), alpha=80)
    img = draw_ring(img, CX + 160, CY - 120, 200, (120, 60, 210), width=5, alpha=180)

    # Small accent ring
    img = draw_ring(img, CX + 300, CY - 260, 80, (50, 170, 160), width=4, alpha=160)

    return img


def main():
    candidates = {
        "spheres_logo_a": candidate_a,  # Two spheres, large + small
        "spheres_logo_b": candidate_b,  # Three Venn spheres
        # "spheres_logo_c": candidate_c,  # Two + keyhole (syntax fix needed)
        "spheres_logo_d": candidate_d,  # Diagonal cascade
        "spheres_logo_e": candidate_e,  # Spheres with ring outlines
    }

    for name, fn in candidates.items():
        img = fn()
        img.save(f"{BASE}/{name}.png", "PNG")
        print(f"  Saved {name}.png")

    # Fix candidate C manually
    img = make_canvas()
    img = draw_sphere(img, CX - 120, CY, 260, (220, 70, 90), alpha=120)
    img = draw_sphere(img, CX + 120, CY, 260, (120, 60, 210), alpha=120)

    overlay = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.ellipse([CX - 22, CY - 30, CX + 22, CY + 14], fill=(255, 255, 255, 200))
    draw.polygon([(CX - 8, CY + 8), (CX, CY + 40), (CX + 8, CY + 8)], fill=(255, 255, 255, 200))
    draw.ellipse([CX - 8, CY - 16, CX + 8, CY], fill=(100, 60, 160, 180))
    draw.polygon([(CX - 4, CY - 2), (CX, CY + 20), (CX + 4, CY - 2)], fill=(100, 60, 160, 180))
    img = Image.alpha_composite(img, overlay)
    img.save(f"{BASE}/spheres_logo_c.png", "PNG")
    print("  Saved spheres_logo_c.png")

    print("\nAll 5 candidates generated!")


if __name__ == "__main__":
    main()
