"""
Place the Spheres v7 golden v2 logo on a white rounded-square background.
"""

from PIL import Image, ImageDraw
import os

SIZE = 1024
BASE = "/home/faisal/code/hobby/SafeSelf/safesocial/safesocial_app"
LOGO = "/home/faisal/code/hobby/SafeSelf/safesocial/safesocial_v7_golden_v2.png"


def main():
    # Load logo
    logo = Image.open(LOGO).convert("RGBA")
    logo_w, logo_h = logo.size

    # Create white rounded-square background
    bg = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(bg)
    r = int(SIZE * 0.22)
    draw.rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=r, fill=(255, 255, 255, 255))

    # Resize logo to fill ~97% of the square (1.5x enlargement), maintain aspect ratio
    target = int(SIZE * 0.97)
    ratio = min(target / logo_w, target / logo_h)
    new_w = int(logo_w * ratio)
    new_h = int(logo_h * ratio)
    logo_resized = logo.resize((new_w, new_h), Image.LANCZOS)

    # Center the logo
    offset_x = (SIZE - new_w) // 2
    offset_y = (SIZE - new_h) // 2

    bg.paste(logo_resized, (offset_x, offset_y), logo_resized)

    # Save
    os.makedirs(f"{BASE}/assets/images", exist_ok=True)
    bg.save(f"{BASE}/assets/images/icon_1024.png", "PNG")

    # Copy logo source
    logo.save(f"{BASE}/assets/images/logo.png", "PNG")

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

    print("Done! Icon generated from spheres_v7_golden_v2.png")


if __name__ == "__main__":
    main()
