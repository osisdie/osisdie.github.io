#!/bin/bash
# Add watermark to blog images (SVG or PNG)
#
# Usage:
#   ./scripts/watermark.sh <file-or-dir> [title]
#
# Examples:
#   ./scripts/watermark.sh assets/img/blog/2026/iot-architecture/iot-architecture-overview.svg "IoT Architecture"
#   ./scripts/watermark.sh assets/img/blog/2026/channel-plugin-dev/telegram-buttons.png
#   ./scripts/watermark.sh assets/img/blog/2026/iot-architecture/   # process all images in dir
#
# SVG: inserts/replaces bottom-center <g opacity="0.45"> watermark, then regenerates PNG
# PNG (no SVG source): stamps watermark directly via Pillow

set -euo pipefail

# --- Config ---
DOMAIN="osisdie.github.io"
OPACITY="0.45"
FONT_WEIGHT="600"
FONT_SIZE="11"
LETTER_SPACING="0.5px"
FILL="#64748b"

watermark_svg() {
  local svg="$1"
  local title="${2:-}"

  # Extract viewBox dimensions
  local vb
  vb=$(grep -oP 'viewBox="[^"]*"' "$svg" | head -1)
  local vb_w vb_h
  vb_w=$(echo "$vb" | grep -oP '[\d.]+' | sed -n '3p')
  vb_h=$(echo "$vb" | grep -oP '[\d.]+' | sed -n '4p')

  local cx
  cx=$(awk "BEGIN { printf \"%.0f\", $vb_w / 2 }")
  local ty
  ty=$(awk "BEGIN { printf \"%.0f\", $vb_h - 12 }")

  # Build watermark text
  local wm_text="$DOMAIN"
  [ -n "$title" ] && wm_text="$DOMAIN · $title"

  # Detect font-family from SVG root
  local font_family
  font_family=$(grep -oP '<svg[^>]*font-family="[^"]*"' "$svg" | grep -oP 'font-family="[^"]*"' | sed 's/font-family="//;s/"$//' || true)
  [ -z "$font_family" ] && font_family="Segoe UI, Arial, sans-serif"

  # Build the watermark block
  local wm_block
  wm_block=$(cat <<WM
  <!-- Bottom attribution -->
  <g opacity="$OPACITY">
    <text x="$cx" y="$ty" text-anchor="middle" fill="$FILL" font-family="$font_family" font-size="$FONT_SIZE" font-weight="$FONT_WEIGHT" letter-spacing="$LETTER_SPACING">$wm_text</text>
  </g>
WM
)

  # Remove existing watermark (between "Bottom attribution" and </svg>)
  if grep -q '<!-- Bottom attribution -->' "$svg"; then
    # Delete from attribution comment to closing </svg>, then re-add both
    sed -i '/<!-- Bottom attribution -->/,/<\/svg>/d' "$svg"
    printf '%s\n</svg>\n' "$wm_block" >> "$svg"
  else
    # Insert before closing </svg>
    sed -i "s|</svg>|${wm_block//$'\n'/\\n}\n</svg>|" "$svg"
  fi

  echo "  [SVG] $svg — watermark: \"$wm_text\" at ($cx, $ty)"

  # Regenerate matching PNG
  local png="${svg%.svg}.png"
  # Also check for filename mismatches (e.g. rag_challenges_solutions.svg -> rag-challenges-overview.png)
  local dir
  dir=$(dirname "$svg")
  local slug
  slug=$(basename "$dir")
  local alt_png="$dir/${slug}-overview.png"

  local target_png=""
  if [ -f "$png" ]; then
    target_png="$png"
  elif [ -f "$alt_png" ]; then
    target_png="$alt_png"
  fi

  if [ -n "$target_png" ]; then
    local png_w
    png_w=$(awk "BEGIN { printf \"%.0f\", $vb_w * 2 }")
    rsvg-convert "$svg" -w "$png_w" -b white -o "$target_png"
    echo "  [PNG] $target_png — regenerated at ${png_w}px wide"
  fi
}

watermark_png() {
  local png="$1"
  local title="${2:-}"

  # Restore from git first to avoid stacking watermarks
  if git ls-files --error-unmatch "$png" &>/dev/null; then
    git checkout -- "$png"
  fi

  local wm_text="$DOMAIN"
  [ -n "$title" ] && wm_text="$DOMAIN · $title"

  python3 - "$png" "$wm_text" "$OPACITY" <<'PYEOF'
import sys
from PIL import Image, ImageDraw, ImageFont

png_path, wm_text, opacity_str = sys.argv[1], sys.argv[2], sys.argv[3]
alpha = int(float(opacity_str) * 255)

img = Image.open(png_path).convert("RGBA")
overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
draw = ImageDraw.Draw(overlay)

# Scale font size relative to image width (~2.3% of width, min 18px)
font_size = max(18, int(img.width * 0.023))
font = None
for name in [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
]:
    try:
        font = ImageFont.truetype(name, font_size)
        break
    except OSError:
        pass
if font is None:
    font = ImageFont.load_default()

bbox = draw.textbbox((0, 0), wm_text, font=font)
tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
x = (img.width - tw) // 2
y = img.height - th - 14

draw.text((x, y), wm_text, fill=(100, 116, 139, alpha), font=font)
img = Image.alpha_composite(img, overlay).convert("RGB")
img.save(png_path)
print(f"  [PNG] {png_path} — stamped: \"{wm_text}\" ({img.width}x{img.height})")
PYEOF
}

process_file() {
  local file="$1"
  local title="${2:-}"
  local ext="${file##*.}"

  case "$ext" in
    svg)
      watermark_svg "$file" "$title"
      ;;
    png)
      # Only stamp PNG directly if no matching SVG source exists for THIS file
      local basename_no_ext="${file%.png}"
      local matching_svg="${basename_no_ext}.svg"
      # Also check slug-based naming (e.g. rag-challenges-overview.png -> rag_challenges_solutions.svg)
      local dir
      dir=$(dirname "$file")
      local slug
      slug=$(basename "$file" .png)
      local has_matching_svg=false
      if [ -f "$matching_svg" ]; then
        has_matching_svg=true
      else
        # Check if this PNG is an -overview.png that gets regenerated from any SVG in the dir
        if [[ "$slug" == *-overview ]]; then
          for s in "$dir"/*.svg; do
            [ -f "$s" ] && has_matching_svg=true && break
          done
        fi
      fi
      if [ "$has_matching_svg" = false ]; then
        watermark_png "$file" "$title"
      else
        echo "  [SKIP] $file — has SVG source, process the SVG instead"
      fi
      ;;
    *)
      echo "  [SKIP] $file — unsupported format"
      ;;
  esac
}

# --- Main ---
if [ $# -lt 1 ]; then
  echo "Usage: $0 <file-or-dir> [title]"
  exit 1
fi

TARGET="$1"
TITLE="${2:-}"

echo "Watermark: $DOMAIN"
echo "---"

if [ -d "$TARGET" ]; then
  for f in "$TARGET"/*.svg "$TARGET"/*.png; do
    [ -f "$f" ] || continue
    process_file "$f" "$TITLE"
  done
else
  process_file "$TARGET" "$TITLE"
fi

echo "---"
echo "Done."
