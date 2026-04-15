---
name: blog-image-reviewer
description: Verify SVG has no proprietary fonts or CSS variables, and PNG is high-res with white background
model: haiku
tools:
  - Grep
  - Glob
  - Read
  - Bash
---

# Blog Image Reviewer

Review SVG and PNG files in `assets/img/blog/` for compliance with the project's image standards.

## Checks

### SVG Files
1. **No proprietary fonts** — grep for `Anthropic Sans`, `Inter`, or other non-system fonts
2. **No CSS variables** — grep for `var(--` patterns
3. **Has viewBox** — every SVG must have a fixed `viewBox` attribute
4. **Font size >= 13px** — text below 13px becomes unreadable after social media JPEG compression. Grep for `font-size` values and flag any below 13 (watermark text at 11px is exempt)
5. **System font stack used** — should contain `-apple-system` or `Noto Sans TC`

### Social Media Readability
1. **Text element count ≤ 35** — count `<text>` elements; more than 35 becomes illegible in LinkedIn/Twitter thumbnails. Suggest splitting the image if over 35
2. **Aspect ratio ≤ 2:1** — parse viewBox width/height; ratios wider than 2:1 get shrunk aggressively on social feeds. Suggest making the image taller
3. **Dark-bg font weight ≥ 600** — if the SVG has a dark background (gradient with stop-color below `#334155`), check that text `font-weight` is at least 600. Thin text on dark bg suffers from JPEG halo artifacts
4. **No dim text on dark bg** — on dark backgrounds, flag any text fill color darker than `#94a3b8` (slate-400) as it disappears after JPEG compression

### Hybrid Layout (White-Head + Dark-Detail)
1. **Hybrid marker** — if SVG has both white and dark background regions, verify `<!-- layout: hybrid -->` comment is present after the opening `<svg>` tag
2. **Hero viewBox** — for files named `*-overview.svg`, verify viewBox is `1200 630` (LinkedIn optimal)
3. **Head zone readability** — in hybrid SVGs, the title text (in the white head zone, y < 370) must have `font-size` >= 24px for LinkedIn thumbnail readability at 42% scale
4. **Head zone contrast** — text in the white zone (y < 370) must use dark fills (`#1e293b`, `#475569`, or darker) — not light fills meant for dark backgrounds like `#e2e8f0` or `#94a3b8`
5. **Head zone pill/badge overflow** — verify text content fits within its container rect width. Estimate: `char_count × font_size × 0.55` should be less than `rect_width - 20px` padding. Flag any text that likely overflows its pill/badge
6. **Transition gradient** — verify a gradient transition exists between the white and dark zones (typically y=370-400)
7. **Detail zone text size >= 15px** — all text in the detail zone (y >= 400) should use font-size >= 15px for labels/titles (13px OK for secondary purpose lines). Flag any detail zone label at 13-14px as too small
8. **Detail zone content must add value** — each box/cell in the detail zone must have at least 2 lines: a label AND a purpose/description line. Flag any box with only a single-word or single-line label — it adds no information and wastes space
9. **Detail zone grid centering** — for horizontal box grids in the detail zone, verify the grid is centered: left margin and right margin should be approximately equal (within ±50px). Calculate: `first_box_x` vs `viewBox_width - last_box_x - last_box_width`

### Watermark
1. **Watermark present** — every SVG must contain a `<!-- Bottom attribution -->` comment followed by a `<g opacity="0.45">` block with a `<text>` element
2. **Position: bottom center** — `text-anchor="middle"`, x = half of viewBox width, y = viewBox height minus ~12px
3. **Content format** — text must match `osisdie.github.io · {Post Title}`
4. **Style** — `fill="#64748b"`, `font-size="11"`, `font-weight="600"`, `letter-spacing="0.5px"`
5. **No legacy format** — if a bare `osisdie.github.io` text exists without the `<g opacity="0.45">` wrapper, flag it for replacement
6. **Standalone PNGs** — PNGs without a matching SVG source (e.g. screenshots) must also have a watermark. Use `scripts/watermark.sh` to apply
7. **Suggest fix** — if watermark is missing or outdated, suggest running `./scripts/watermark.sh <file> "Title"`

### PNG Files
1. **Resolution** — width should be >= 2x the SVG viewBox width (3x for dark-background SVGs). Use `file` command to check dimensions
2. **Background** — not transparent (transparent renders as black). Dark-bg SVGs should NOT use `-b white` in rsvg-convert
3. **File size** — should be < 500KB
4. **Chinese text** — read the PNG and visually verify CJK characters render correctly

### SVG Layout
6. **No text/arrow overlap** — check that `<text>` elements and `<path>`/`<line>` arrows do not share the same Y coordinate range within 15px. Labels near curved arrows are especially prone to overlap. Arrows curving above boxes need at least 20px clearance from the nearest text label.
7. **Smooth curve clearance** — curved paths (`<path>` with C/Q bezier) should have control points at least 25px above/below the box edges they connect, so the curve visually separates from box borders and labels.

## How to Run

Search for all SVG/PNG pairs in `assets/img/blog/`:

```bash
find assets/img/blog/ -name "*.svg" -o -name "*.png"
```

For each SVG, run the font/variable checks. For each PNG, verify dimensions and size.

## Output

Report as a checklist:
- [PASS] or [FAIL] for each check
- For failures, include the specific line numbers and suggested fix
