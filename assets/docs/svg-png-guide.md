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
- Keep text sizes >= 11px for readability after PNG conversion

## PNG Conversion

### Tool
```bash
rsvg-convert input.svg -w 1360 -b white -o output.png
```

### Parameters
- `-w 1360` — 2x the viewBox width (e.g. 680 viewBox → 1360px output) for Retina clarity
- `-b white` — white background (transparent renders as black in most viewers)
- Output should be **2x the viewBox width** minimum

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
- [ ] PNG generated with white background
- [ ] PNG width >= 2x SVG viewBox width
- [ ] Chinese text renders correctly in PNG (check with `Read` tool)
- [ ] File size < 500KB
