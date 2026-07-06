# Installer mascot branding

Drop the faculty mascot here and the installer wizard picks it up — mascot on
a Logix-blue panel on the Welcome/Finish pages, a small logo in every inner
page header, a matching `.exe` icon, and the same mascot in the sign-in popup.
The look is modeled on mascot-branded installers like Comnyang.

## How to use

1. Save the mascot as **`mascot-source.png`** in this folder.
   - **PNG with a transparent background** gives the best result (the mascot
     sits cleanly on the blue panel and makes a clean icon). JPG/WebP/BMP also
     work but a solid background will show as a rectangle.
   - Roughly square and **≥ 512×512** is ideal; larger is fine.
2. Generate the assets:
   ```powershell
   py ..\build_branding.py
   ```
   (or just run `powershell -File ..\build.ps1`, which does this automatically
   before compiling.)
3. This writes `wizard-image.bmp`, `wizard-small.bmp`, `logix.ico` here, and
   `..\..\windows\logo.png` for the sign-in popup.

## Notes

- Only `mascot-source.*` and this README are tracked in git. The generated
  `*.bmp` / `*.ico` are build artifacts (git-ignored) — rebuild them from the
  source anytime.
- No mascot here? The build still works; Inno Setup uses its stock wizard
  images. Nothing breaks.
- Want to tweak the panel colors, wordmark, or tagline? They're constants at
  the top of `../build_branding.py` (`BRAND_TOP`, `BRAND_BOTTOM`, `WORDMARK`,
  `TAGLINE`).
- Use only artwork you have the right to ship. The official FTMM/UNAIR mascot
  is your faculty's mark — confirm it's cleared for this use.
