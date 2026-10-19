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

# The gradient the mascot sits on: the v4 "Denyut" ink ramp, the same dark
# frame as the dashboard sidebar and the workstation client
# (frontend/src/tokens.css --lx-frame-raise down to --lx-frame).
BRAND_TOP = (29, 31, 35)      # #1D1F23
BRAND_BOTTOM = (11, 12, 14)   # #0B0C0E
WORDMARK = "Logix"
TAGLINE = "Lab Komputasi FTMM"

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


# The dashboard's typeface, from the static TTFs the Windows client bundles.
FONT_DIR = WINDOWS_DIR / "fonts"
ACCENT = (197, 242, 58)       # --lx-accent #C5F23A
ON_ACCENT = (17, 18, 20)      # --lx-on-accent #111214
FRAME = (15, 16, 18)          # --lx-frame #0F1012
FRAME_RAISE = (29, 31, 35)    # --lx-frame-raise #1D1F23
FRAME_TEXT = (242, 243, 245)  # --lx-frame-text
FRAME_MUTED = (139, 144, 152) # --lx-frame-muted


def load_font(size: int, bold: bool = True, weight: str = "") -> ImageFont.FreeTypeFont:
    style = weight or ("Bold" if bold else "Regular")
    bundled = FONT_DIR / f"PlusJakartaSans-{style}.ttf"
    names = [str(bundled)] + (["arialbd.ttf", "seguisb.ttf", "segoeui.ttf"] if bold
                              else ["segoeui.ttf", "arial.ttf"])
    for name in names:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def draw_brand_mark(draw: ImageDraw.ImageDraw, x: int, y: int, scale: int, label: str = "LOGIX") -> None:
    """The dashboard sidebar's mark: a lime tile with the prompt glyph, then
    the wordmark -- the same thing every client window now opens with."""
    tile = 22 * scale
    draw.rounded_rectangle((x, y, x + tile, y + tile), radius=7 * scale, fill=ACCENT)
    mono = None
    for name in ("consolab.ttf", "consola.ttf"):
        try:
            mono = ImageFont.truetype(name, 11 * scale)
            break
        except OSError:
            continue
    mono = mono or load_font(11 * scale)
    gl, gt, gr, gb = draw.textbbox((0, 0), ">_", font=mono)
    draw.text((x + (tile - (gr - gl)) / 2 - gl, y + (tile - (gb - gt)) / 2 - gt), ">_", font=mono, fill=ON_ACCENT)
    word = load_font(11 * scale, weight="Bold")
    wl, wt, wr, wb = draw.textbbox((0, 0), label, font=word)
    draw.text((x + tile + 8 * scale - wl, y + (tile - (wb - wt)) / 2 - wt), label, font=word, fill=FRAME_TEXT)


def draw_pulse(draw: ImageDraw.ImageDraw, x0: int, x1: int, y: int, scale: int) -> None:
    """The "Denyut" trace: flat, one heartbeat, flat."""
    u = scale
    mid = x0 + (x1 - x0) * 0.42
    pts = [(x0, y), (mid - 14 * u, y), (mid - 10 * u, y - 7 * u), (mid - 5 * u, y + 10 * u),
           (mid + 1 * u, y - 16 * u), (mid + 6 * u, y + 7 * u), (mid + 10 * u, y), (x1, y)]
    draw.line(pts, fill=ACCENT, width=round(2.2 * u), joint="curve")


def build_wizard_image(mascot: Image.Image, out: Path, scale: int = 3) -> None:
    # Inno modern welcome image is 164x314 at 100%; render at 3x and let Inno
    # downscale for crispness on any DPI. Composed like the dashboard's login
    # panel: brand mark top-left, the lab's mascot, the pulse, the headline.
    w, h = 164 * scale, 314 * scale
    u = scale
    panel = Image.new("RGB", (w, h), FRAME)
    draw = ImageDraw.Draw(panel)
    pad = 14 * u

    draw_brand_mark(draw, pad, pad, u)

    # Mascot on a raised disc, the way the dashboard lifts cards off the frame.
    disc = 112 * u
    cx, cy = w // 2, 112 * u
    draw.ellipse((cx - disc // 2, cy - disc // 2, cx + disc // 2, cy + disc // 2), fill=FRAME_RAISE)
    art = fit_within(mascot, int(disc * 0.78), int(disc * 0.78))
    panel.paste(art, (cx - art.width // 2, cy - art.height // 2), art)

    draw_pulse(draw, pad, w - pad, 190 * u, u)

    # Headline, the login page's: "Denyut" on a lime chip, then the rest.
    big = load_font(17 * u, weight="Bold")
    y = 214 * u
    word = "Denyut"
    l, t, r, b = draw.textbbox((0, 0), word, font=big)
    chip_pad = 4 * u
    draw.rounded_rectangle((pad, y - 2 * u, pad + (r - l) + chip_pad * 2, y + (b - t) + 6 * u),
                           radius=5 * u, fill=ACCENT)
    draw.text((pad + chip_pad - l, y + 2 * u - t), word, font=big, fill=ON_ACCENT)
    draw.text((pad + (r - l) + chip_pad * 2 + 5 * u - l, y + 2 * u - t), "lab,", font=big, fill=FRAME_TEXT)
    draw.text((pad - l, y + 26 * u - t), "terbaca sekilas.", font=big, fill=FRAME_TEXT)

    small = load_font(7 * u, weight="SemiBold")
    draw.text((pad, h - pad - 9 * u), TAGLINE.upper(), font=small, fill=FRAME_MUTED)

    panel.save(out, "BMP")


def build_wizard_small(mascot: Image.Image, out: Path, scale: int = 3) -> None:
    # Inno modern header logo is 55x58 at 100%. The wizard runs in its dark
    # style on the frame colour, so the brand tile sits on that, not on white.
    w, h = 55 * scale, 58 * scale
    canvas = Image.new("RGB", (w, h), FRAME)
    draw = ImageDraw.Draw(canvas)
    tile = 40 * scale
    x, y = (w - tile) // 2, (h - tile) // 2
    draw.rounded_rectangle((x, y, x + tile, y + tile), radius=12 * scale, fill=ACCENT)
    mono = None
    for name in ("consolab.ttf", "consola.ttf"):
        try:
            mono = ImageFont.truetype(name, 19 * scale)
            break
        except OSError:
            continue
    mono = mono or load_font(19 * scale)
    gl, gt, gr, gb = draw.textbbox((0, 0), ">_", font=mono)
    draw.text((x + (tile - (gr - gl)) / 2 - gl, y + (tile - (gb - gt)) / 2 - gt), ">_", font=mono, fill=ON_ACCENT)
    canvas.save(out, "BMP")


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
