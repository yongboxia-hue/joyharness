#!/usr/bin/env python3
"""Generate the JoyHarness macOS launcher icon."""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
ASSET_DIR = ROOT / "assets" / "macos"
ICONSET_DIR = ASSET_DIR / "JoyHarness.iconset"
PNG_PATH = ASSET_DIR / "JoyHarness-icon.png"


def main() -> None:
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    ICONSET_DIR.mkdir(parents=True, exist_ok=True)
    image = _render_icon(1024)
    image.save(PNG_PATH)
    _write_iconset(image)
    print(PNG_PATH)


def _render_icon(size: int) -> Image.Image:
    scale = 4
    canvas_size = size * scale
    image = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    margin = int(canvas_size * 0.065)
    radius = int(canvas_size * 0.225)
    body = [margin, margin, canvas_size - margin, canvas_size - margin]

    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        [body[0], body[1] + int(canvas_size * 0.035), body[2], body[3] + int(canvas_size * 0.035)],
        radius=radius,
        fill=(0, 0, 0, 95),
    )
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(int(canvas_size * 0.035))))

    _draw_vertical_gradient(
        image,
        body,
        radius,
        top=(33, 38, 46, 255),
        bottom=(12, 15, 21, 255),
    )
    draw.rounded_rectangle(body, radius=radius, outline=(255, 255, 255, 34), width=int(canvas_size * 0.012))

    _draw_menubar(draw, canvas_size)
    _draw_joycon_pair(draw, canvas_size)
    _draw_battery_mark(draw, canvas_size)

    return image.resize((size, size), Image.Resampling.LANCZOS)


def _draw_vertical_gradient(image: Image.Image, box, radius: int, top, bottom) -> None:
    x0, y0, x1, y1 = box
    height = y1 - y0
    gradient = Image.new("RGBA", (1, height), (0, 0, 0, 0))
    pixels = gradient.load()
    for y in range(height):
        t = y / max(height - 1, 1)
        pixels[0, y] = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(4))
    gradient = gradient.resize((x1 - x0, height))
    mask = Image.new("L", (x1 - x0, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, x1 - x0, height], radius=radius, fill=255)
    image.paste(gradient, (x0, y0), mask)


def _draw_menubar(draw: ImageDraw.ImageDraw, size: int) -> None:
    x0 = int(size * 0.19)
    y0 = int(size * 0.17)
    x1 = int(size * 0.81)
    y1 = int(size * 0.26)
    draw.rounded_rectangle([x0, y0, x1, y1], radius=int(size * 0.035), fill=(244, 248, 255, 34))
    for i, alpha in enumerate((220, 150, 105)):
        cx = x0 + int(size * (0.055 + i * 0.055))
        cy = (y0 + y1) // 2
        r = int(size * 0.014)
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(244, 248, 255, alpha))


def _draw_joycon_pair(draw: ImageDraw.ImageDraw, size: int) -> None:
    left = [int(size * 0.215), int(size * 0.29), int(size * 0.46), int(size * 0.79)]
    right = [int(size * 0.54), int(size * 0.29), int(size * 0.785), int(size * 0.79)]
    _draw_joycon(draw, left, (36, 210, 190, 255), left_side=True)
    _draw_joycon(draw, right, (255, 94, 120, 255), left_side=False)
    bridge = [int(size * 0.425), int(size * 0.51), int(size * 0.575), int(size * 0.59)]
    draw.rounded_rectangle(bridge, radius=int(size * 0.032), fill=(236, 242, 255, 225))


def _draw_joycon(draw: ImageDraw.ImageDraw, box, fill, left_side: bool) -> None:
    x0, y0, x1, y1 = box
    w = x1 - x0
    h = y1 - y0
    radius = int(w * 0.45)
    draw.rounded_rectangle([x0, y0, x1, y1], radius=radius, fill=(0, 0, 0, 70))
    body = [x0 + int(w * 0.02), y0 - int(h * 0.018), x1 - int(w * 0.02), y1 - int(h * 0.018)]
    draw.rounded_rectangle(body, radius=radius, fill=fill)
    draw.rounded_rectangle(body, radius=radius, outline=(255, 255, 255, 80), width=max(2, int(w * 0.035)))

    stick_cx = x0 + int(w * (0.53 if left_side else 0.47))
    stick_cy = y0 + int(h * (0.28 if left_side else 0.68))
    stick_r = int(w * 0.17)
    draw.ellipse(
        [stick_cx - stick_r, stick_cy - stick_r, stick_cx + stick_r, stick_cy + stick_r],
        fill=(22, 25, 33, 230),
    )
    draw.ellipse(
        [
            stick_cx - int(stick_r * 0.45),
            stick_cy - int(stick_r * 0.45),
            stick_cx + int(stick_r * 0.45),
            stick_cy + int(stick_r * 0.45),
        ],
        fill=(255, 255, 255, 72),
    )

    button_y = y0 + int(h * (0.66 if left_side else 0.30))
    button_r = int(w * 0.055)
    for dx, dy in ((0, -1), (-1, 0), (1, 0), (0, 1)):
        cx = x0 + int(w * 0.5) + dx * int(w * 0.09)
        cy = button_y + dy * int(w * 0.09)
        draw.ellipse([cx - button_r, cy - button_r, cx + button_r, cy + button_r], fill=(255, 255, 255, 210))


def _draw_battery_mark(draw: ImageDraw.ImageDraw, size: int) -> None:
    x0 = int(size * 0.385)
    y0 = int(size * 0.78)
    x1 = int(size * 0.615)
    y1 = int(size * 0.86)
    draw.rounded_rectangle([x0, y0, x1, y1], radius=int(size * 0.025), fill=(248, 251, 255, 235))
    nub_w = int(size * 0.018)
    nub = [x1, y0 + int(size * 0.024), x1 + nub_w, y1 - int(size * 0.024)]
    draw.rounded_rectangle(nub, radius=int(size * 0.008), fill=(248, 251, 255, 210))
    fill = [x0 + int(size * 0.018), y0 + int(size * 0.018), x1 - int(size * 0.02), y1 - int(size * 0.018)]
    draw.rounded_rectangle(fill, radius=int(size * 0.015), fill=(47, 198, 122, 255))


def _write_iconset(image: Image.Image) -> None:
    for point_size in (16, 32, 128, 256, 512):
        image.resize((point_size, point_size), Image.Resampling.LANCZOS).save(
            ICONSET_DIR / f"icon_{point_size}x{point_size}.png"
        )
        image.resize((point_size * 2, point_size * 2), Image.Resampling.LANCZOS).save(
            ICONSET_DIR / f"icon_{point_size}x{point_size}@2x.png"
        )


if __name__ == "__main__":
    main()
