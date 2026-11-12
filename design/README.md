# Inkfall identity kit

Concept A, "Falling line": five round-capped bars hang from one level top edge like ink running
down a page; the centre bar is longest and releases a single drop.

Regenerate everything (Python 3 + Pillow, no SVG renderer needed):

    python3 design/build_icon.py

Add `--ladder out.png` for the 16/32/60/180/1024 size ladder on light and dark grounds.

## What it writes

| File | Use |
| --- | --- |
| `masters/inkfall-symbol.svg`, `-black`, `-white` | symbol, 256 viewBox |
| `masters/inkfall-symbol-small.svg` | 16 px cut: three fat bars and a drop, every edge on a whole pixel (32 px is exactly 2x) |
| `masters/inkfall-icon.svg` | app icon tile, 1024 canvas |
| `masters/inkfall-menubar.svg` | menu-bar template glyph, 18 pt, black only (also copied to `Resources/Assets.xcassets/MenuBarGlyph.imageset/`) |
| `masters/inkfall-lockup.svg`, `-reversed.svg` | symbol + wordmark, letters outlined |
| `export/readme-lockup-light.svg`, `-dark.svg` | README header |
| `export/social-preview.png` | 1280x640, for the GitHub repo social preview (set by hand in Settings) |
| `Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png` | 16 to 1024; 16 and 32 come from the small cut, not downscaled |

## Rules

- Colours: ember `#F2A84B` on emberInk `#1A1205` (9.25:1), the same tokens as `DesignSystem.swift`.
  Ember is never the wordmark on a light ground (2.5:1): the light lockup is all emberInk, the dark
  lockup is an ember symbol with a white wordmark. Flat: no glow, no gradient.
- Grid: the app icon tile is 824 px in the 1024 canvas (100 px margin, alpha bbox exactly 100..924).
  The mark's long side is 620 px, a 12.4 % margin inside the tile. At 16 and 32 px the tile is 14 and
  28 px (whole pixels) so the edge stays crisp.
- Wordmark: "Inkfall" in Fraunces SemiBold (SIL OFL 1.1), outlined in `wordmark_data.py`.
  `extract_wordmark.py` regenerates that file from the font; it is only needed to change the wordmark.
- The menu-bar glyph is used for the idle state only; the state symbols stay SF Symbols.
- This folder is `design/` because `scripts/*` is git-ignored.
