# SVG & PNG Image Guide

Rules for creating blog hero images as SVG and converting to PNG.

## SVG Rules

### Fonts
- **Never use** proprietary fonts (`Anthropic Sans`, `Inter`, etc.) — they won't exist in the rendering environment
- **Use** system font stack: `-apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans TC", sans-serif`
- For monospace: `"SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace`

### Colors
- **Never use** CSS variables (`var(--t)`, `var(--b)`, etc.) — they don't resolve in standalone SVG/PNG
- **Always hardcode** color values: `rgb(115,114,108)`, `#f44d14`, `rgba(31,30,29,0.3)`
- Use the inline `style` attribute, not `stroke`/`fill` attributes referencing variables

### Layout
- Set `viewBox` with fixed dimensions (e.g. `viewBox="0 0 680 720"`)
- Use `width="100%"` for responsive display in HTML
- Keep text sizes >= **13px** for readability after social media compression (see Social Media section)
- Prefer **4:3 or 1:1** aspect ratios — wide images (>2:1) get aggressively shrunk on LinkedIn/Twitter
- Limit to **≤35 text elements** per SVG — more than that becomes illegible in social thumbnails

## PNG Conversion

### Tool
```bash
rsvg-convert input.svg -w 1360 -b white -o output.png
```

### Parameters
- `-w 1360` — 2x the viewBox width (e.g. 680 viewBox → 1360px output) for Retina clarity
- `-b white` — white background (transparent renders as black in most viewers)
- Output should be **2x the viewBox width** minimum (use **3x** for dark-background images — see Social Media section)

### Install `rsvg-convert`
```bash
# Ubuntu/Debian
sudo apt install librsvg2-bin

# macOS
brew install librsvg

# Or use Docker
docker run --rm -v "$PWD":/work -w /work ubuntu:22.04 \
  sh -c "apt-get update && apt-get install -y librsvg2-bin && rsvg-convert input.svg -w 1360 -b white -o output.png"
```

## File Organization
```
assets/img/blog/{year}/{slug}/
  hero.svg              # Source SVG
  hero.png              # Generated PNG (for og:image + figure include)
```

## Social Media Optimization

LinkedIn, Twitter, and Facebook re-encode images as **JPEG**, which degrades text clarity — especially on dark backgrounds.

### Why Dark Backgrounds Lose Text Clarity

| Factor | White Background | Dark Background |
|--------|-----------------|-----------------|
| JPEG text edges | Dark-on-white anti-aliases smoothly | Light-on-dark creates halo/ringing artifacts |
| Color subsampling | Barely affects black text | Colored text (cyan, green) loses sharpness |
| Feed visibility | Blends into white feed | Stands out — higher click-through |

### Rules for Social-Friendly Images

1. **Min font size: 13px** — anything smaller becomes illegible after LinkedIn's resize + JPEG compression
2. **Max ~35 text elements** — more than that turns into noise at thumbnail size
3. **Aspect ratio: 4:3 or 1:1** — wide images (>2:1) get shrunk ~40% more than square ones
4. **Font weight ≥ 600** on dark backgrounds — thin text suffers most from JPEG artifacts
5. **Export at 3x** for dark-background SVGs — gives LinkedIn's compressor more pixels to work with

### Dark Background Best Practices

- Recommended gradient: `#0f172a → #1e293b` (Tailwind Slate 900→800)
- Use **bold accent colors** for labels (cyan `#22d3ee`, green `#4ade80`, orange `#fb923c`) — they survive JPEG better than pastels
- Avoid grey text below `#94a3b8` (slate-400) — it disappears after compression
- PNG export: use **3x viewBox width** (not 2x) to counteract JPEG quality loss

### Hybrid Layout (White-Head + Dark-Detail) — Recommended for Hero Images

All-dark hero images appear as "black rectangles" on LinkedIn/Twitter — content is invisible without clicking to zoom. **Use the hybrid layout for all hero/overview images.**

**Layout (viewBox 1200×630):**

```
┌──────────────────────────────────────────────────┐
│  WHITE HEAD ZONE  (y: 0–370, ~60%)               │
│  Title: 32px, #1e293b, weight 700                │
│  Subtitle: 18px, #475569, weight 600             │
│  2-3 key takeaway pills (pastel bg + dark text)  │
├── gradient fade (#f1f5f9 → #1e293b, 30px) ───────┤
│  DARK DETAIL ZONE  (y: 400–630, ~40%)            │
│  Architecture boxes / code / comparison           │
│  Accent colors: cyan, green, orange               │
└──────────────────────────────────────────────────┘
```

**Rules:**
- **Standard viewBox**: `1200x630` for all hero images (LinkedIn optimal at 1.9:1 ratio)
- **SVG marker**: add `<!-- layout: hybrid -->` comment after opening `<svg>` tag
- **Head zone**: white `#ffffff` background, title >= 24px, dark text (`#1e293b`, `#475569`)
- **Takeaway pills**: pastel backgrounds (`#dcfce7` green, `#dbeafe` blue, `#fef3c7` amber) with bold dark text
- **Transition**: 30px vertical `linearGradient` from `#f1f5f9` to `#1e293b` (y=370→400)
- **Detail zone**: same rules as dark-bg (weight >= 600, accents, no text below `#94a3b8`)
- **Detail zone minimum font: 15px** for labels/titles (13px only for secondary purpose lines)
- **Detail zone boxes must include purpose** — a label-only box adds no value; always pair `Label` + `one-line purpose description`
- **Center grids horizontally** — calculate left/right margins to ensure visual balance (±50px tolerance)
- **Head zone pill overflow** — verify text fits its container: `char_count × font_size × 0.55 < rect_width - 20`
- **PNG export**: 3x scaling + `-b white` (the white head zone needs it; the dark zone has its own rect)
- **Reference template**: see `assets/docs/hero-template.svg`

**Font sizing for LinkedIn readability (42% scale at 504px thumbnail):**
| SVG size | At 504px | Readable? |
|----------|----------|-----------|
| 32px     | ~13px    | Yes — title |
| 24px     | ~10px    | Yes — pills with bold |
| 18px     | ~7.5px   | Marginal — keep bold weight |
| 14px     | ~6px     | Detail zone only (not thumbnail-critical) |

## Watermark

Every blog SVG must include a bottom-center watermark before `</svg>`:

```svg
<!-- Bottom attribution -->
<g opacity="0.45">
  <text x="{viewBox-center-x}" y="{viewBox-height - 12}" text-anchor="middle"
        fill="#64748b" font-size="11" font-weight="600"
        letter-spacing="0.5px">osisdie.github.io · {Post Title}</text>
</g>
```

### Rules
- Position: **bottom center** (`text-anchor="middle"`, x = half of viewBox width)
- Opacity: **0.45** (visible but non-intrusive)
- Color: `#64748b` (slate-500)
- Font size: **11px**, weight **600**, letter-spacing **0.5px**
- Content format: `osisdie.github.io · {Post Title}`
- If a legacy `osisdie.github.io` text already exists, **replace** it with this format
- Standalone PNGs (screenshots with no SVG source) get watermarked directly via Pillow

### Script

```bash
# Single SVG
./scripts/watermark.sh assets/img/blog/2026/iot-architecture/iot-architecture-overview.svg "IoT Architecture"

# Standalone PNG (no SVG source)
./scripts/watermark.sh assets/img/blog/2026/channel-plugin-dev/telegram-buttons.png

# All images in a directory
./scripts/watermark.sh assets/img/blog/2026/iot-architecture/ "IoT Architecture"
```

The script is idempotent — SVG watermarks are replaced in-place; standalone PNGs are restored from git before stamping.

## Checklist before committing
- [ ] Watermark present (bottom center, opacity 0.45, `osisdie.github.io · Title`)
- [ ] No proprietary fonts in SVG
- [ ] No CSS variables in SVG
- [ ] Font size >= 13px (for social media readability)
- [ ] Text elements ≤ 35 per SVG
- [ ] Aspect ratio ≤ 2:1 (prefer 4:3 or 1:1)
- [ ] Dark-bg SVGs: font-weight ≥ 600, no text color below `#94a3b8`
- [ ] PNG generated with appropriate background
- [ ] PNG width >= 2x viewBox (3x for dark-bg images)
- [ ] Chinese text renders correctly in PNG (check with `Read` tool)
- [ ] File size < 500KB
- [ ] **Hero images**: viewBox `1200x630`, hybrid layout with `<!-- layout: hybrid -->` marker
- [ ] **Hybrid head zone**: title >= 24px, dark fills (`#1e293b`, `#475569`), no light-on-dark text
- [ ] **Hybrid detail zone**: weight >= 600, accent colors, same dark-bg rules
