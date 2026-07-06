"""Turn one mascot artwork file into every branded asset the Logix installer
needs, so the wizard looks like a real product (mascot on a brand panel) the
way NSIS installers like Comnyang do.

Drop the faculty mascot at  installer/branding/mascot-source.png  (PNG with
transparency is ideal; JPG/WebP also work) and run:

    py installer/build_branding.py

It writes, into installer/branding/:
  wizard-image.bmp  -- big left panel on the Welcome/Finish pages
                       (mascot on the Logix blue gradient + wordmark)
  wizard-small.bmp  -- small logo in the header of every inner page
  logix.ico         -- multi-resolution icon for LogixAgentSetup.exe
and, into windows/:
  logo.png          -- the mascot the sign-in popup shows (logbook_popup.ps1)

logix-agent.iss picks these up automatically when they exist (see the
#if FileExists guards there); if you never run this, the installer just falls
back to Inno Setup's stock images, so the build never breaks.

Requires Pillow (`py -m pip install pillow`).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("Pillow is required: py -m pip install pillow")

HERE = Path(__file__).resolve().parent
BRANDING_DIR = HERE / "branding"
WINDOWS_DIR = HERE.parent / "windows"

# Logix brand blues -- the gradient the mascot sits on. Matches the dashboard
# theme accent (#2563EB, frontend/src/theme.ts) shading down to a deep navy.
BRAND_TOP = (37, 99, 235)     # #2563EB
BRAND_BOTTOM = (17, 34, 78)   # deep navy
WORDMARK = "Logix"
TAGLINE = "Lab Access Logbook"

# Default source names tried in order when --source isn't given.
SOURCE_CANDIDATES = ["mascot-source.png", "mascot-source.jpg", "mascot-source.jpeg",
                     "mascot-source.webp", "mascot-source.bmp"]


def find_source(explicit: str | None) -> Path:
    if explicit:
        p = Path(explicit)
        if not p.exists():
            sys.exit(f"Source not found: {p}")
        return p
    for name in SOURCE_CANDIDATES:
        candidate = BRANDING_DIR / name
        if candidate.exists():
            return candidate
    sys.exit(
        "No mascot found. Drop your faculty mascot at\n"
        f"  {BRANDING_DIR / 'mascot-source.png'}\n"
        "(PNG with a transparent background is best) and run this again."
    )


def load_rgba(path: Path) -> Image.Image:
    img = Image.open(path).convert("RGBA")
    return img


def trim_to_content(img: Image.Image) -> Image.Image:
    """Crop transparent margins so the mascot fills the frame consistently
    regardless of how much empty space the source PNG has around it."""
    alpha = img.getchannel("A")
    box = alpha.getbbox()
    return img.crop(box) if box else img


def fit_within(img: Image.Image, max_w: int, max_h: int) -> Image.Image:
    scale = min(max_w / img.width, max_h / img.height)
    size = (max(1, round(img.width * scale)), max(1, round(img.height * scale)))
    return img.resize(size, Image.LANCZOS)


def vertical_gradient(w: int, h: int, top: tuple, bottom: tuple) -> Image.Image:
    base = Image.new("RGB", (w, h))
    px = base.load()
    for y in range(h):
        t = y / max(1, h - 1)
        r = round(top[0] + (bottom[0] - top[0]) * t)
        g = round(top[1] + (bottom[1] - top[1]) * t)
        b = round(top[2] + (bottom[2] - top[2]) * t)
        for x in range(w):
            px[x, y] = (r, g, b)
    return base


def load_font(size: int, bold: bool = True) -> ImageFont.FreeTypeFont:
    names = (["arialbd.ttf", "seguisb.ttf", "segoeui.ttf"] if bold
             else ["segoeui.ttf", "arial.ttf"])
    for name in names:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def build_wizard_image(mascot: Image.Image, out: Path, scale: int = 3) -> None:
    # Inno modern welcome image is 164x314 at 100%; render at 3x and let Inno
    # downscale for crispness on any DPI.
    w, h = 164 * scale, 314 * scale
    panel = vertical_gradient(w, h, BRAND_TOP, BRAND_BOTTOM)

    # Mascot centred in the upper ~65% of the panel.
    art = fit_within(mascot, int(w * 0.72), int(h * 0.52))
    ax = (w - art.width) // 2
    ay = int(h * 0.10)
    panel.paste(art, (ax, ay), art)

    draw = ImageDraw.Draw(panel)
    wordmark_font = load_font(round(20 * scale), bold=True)
    tagline_font = load_font(round(8 * scale), bold=False)

    # Stack wordmark + tagline from real glyph metrics so the descender of
    # "Logix" never collides with the tagline, at any scale.
    wm_l, wm_t, wm_r, wm_b = draw.textbbox((0, 0), WORDMARK, font=wordmark_font)
    tg_l, tg_t, tg_r, tg_b = draw.textbbox((0, 0), TAGLINE, font=tagline_font)
    gap = round(6 * scale)
    block_h = (wm_b - wm_t) + gap + (tg_b - tg_t)
    top = h - block_h - round(24 * scale)  # bottom margin

    wm_x = (w - (wm_r - wm_l)) / 2 - wm_l
    draw.text((wm_x, top - wm_t), WORDMARK, font=wordmark_font, fill=(255, 255, 255))
    tg_x = (w - (tg_r - tg_l)) / 2 - tg_l
    draw.text((tg_x, top + (wm_b - wm_t) + gap - tg_t), TAGLINE,
              font=tagline_font, fill=(200, 214, 245))

    panel.convert("RGB").save(out, "BMP")


def build_wizard_small(mascot: Image.Image, out: Path, scale: int = 3) -> None:
    # Inno modern header logo is 55x58 at 100%. The header is white, so sit the
    # mascot on white rather than the brand panel.
    w, h = 55 * scale, 58 * scale
    canvas = Image.new("RGBA", (w, h), (255, 255, 255, 255))
    art = fit_within(mascot, int(w * 0.9), int(h * 0.9))
    canvas.paste(art, ((w - art.width) // 2, (h - art.height) // 2), art)
    canvas.convert("RGB").save(out, "BMP")


def build_icon(mascot: Image.Image, out: Path) -> None:
    # Square, transparent, padded so the mascot doesn't touch the edges.
    side = max(mascot.width, mascot.height)
    pad = round(side * 0.06)
    canvas = Image.new("RGBA", (side + pad * 2, side + pad * 2), (0, 0, 0, 0))
    canvas.paste(mascot, ((canvas.width - mascot.width) // 2,
                          (canvas.height - mascot.height) // 2), mascot)
    sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    canvas.save(out, format="ICO", sizes=sizes)


def build_agent_logo(mascot: Image.Image, out: Path, box: int = 320) -> None:
    # The sign-in popup (windows/logbook_popup.ps1) shows this as a ~130px hero
    # with its own transparency, so keep the alpha and fit it to a box big
    # enough to stay crisp on HiDPI.
    art = fit_within(mascot, box, box)
    canvas = Image.new("RGBA", (art.width, art.height), (0, 0, 0, 0))
    canvas.paste(art, (0, 0), art)
    out.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out, "PNG")


def main() -> None:
    ap = argparse.ArgumentParser(description="Build Logix installer branding from one mascot image.")
    ap.add_argument("--source", help="Path to the mascot artwork (default: installer/branding/mascot-source.*)")
    ap.add_argument("--out", default=str(BRANDING_DIR), help="Output directory for the wizard/icon assets")
    ap.add_argument("--no-agent-logo", action="store_true",
                    help="Skip writing windows/logo.png for the sign-in popup")
    args = ap.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    src = find_source(args.source)
    raw = load_rgba(src)
    mascot = trim_to_content(raw)
    print(f"Source: {src}  ({raw.width}x{raw.height} -> trimmed {mascot.width}x{mascot.height})")

    build_wizard_image(mascot, out_dir / "wizard-image.bmp")
    build_wizard_small(mascot, out_dir / "wizard-small.bmp")
    build_icon(mascot, out_dir / "logix.ico")
    print(f"Wrote: {out_dir / 'wizard-image.bmp'}")
    print(f"Wrote: {out_dir / 'wizard-small.bmp'}")
    print(f"Wrote: {out_dir / 'logix.ico'}")

    if not args.no_agent_logo:
        logo = WINDOWS_DIR / "logo.png"
        build_agent_logo(mascot, logo)
        print(f"Wrote: {logo}  (sign-in popup mascot)")

    print("\nDone. Now build the installer: powershell -File installer/build.ps1")


if __name__ == "__main__":
    main()
