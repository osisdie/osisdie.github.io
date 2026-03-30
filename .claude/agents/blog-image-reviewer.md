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
4. **Font size >= 11px** — text below 11px becomes unreadable in PNG
5. **System font stack used** — should contain `-apple-system` or `Noto Sans TC`

### PNG Files
1. **Resolution** — width should be >= 2x the SVG viewBox width (use `file` command to check dimensions)
2. **White background** — not transparent (transparent renders as black)
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
