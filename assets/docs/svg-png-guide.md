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

## Checklist before committing
- [ ] No proprietary fonts in SVG
- [ ] No CSS variables in SVG
- [ ] PNG generated with white background
- [ ] PNG width >= 2x SVG viewBox width
- [ ] Chinese text renders correctly in PNG (check with `Read` tool)
- [ ] File size < 500KB
