#!/bin/bash
# Generate a Pragmatic Cream hero SVG for a blog post, then delegate to
# scripts/watermark.sh to stamp the watermark and rasterize PNG.
#
# Usage:
#   ./scripts/generate-hero.sh \
#     --slug rag-challenges \
#     --year 2026 \
#     --category "AI / RAG" \
#     --headline "Hybrid Search Taught Me|What Embeddings Miss" \
#     --sub-hook "How intent routing cut latency 40%." \
#     --variant flow \
#     --anchor "RETRIEVE|RERANK|GENERATE" \
#     --title "Hybrid Search in RAG"
#
# Variants:
#   essay — no visual anchor. --anchor ignored. Best for lessons-learned / opinion.
#   flow  — 3-box horizontal chain. --anchor "A|B|C" (1-10 chars each, shown uppercase).
#   stat  — oversized number on left + headline on right. --anchor "NUMBER|CAPTION".
#
# Other flags:
#   --lang en|tc   — tc shrinks headline 10% and relaxes leading for CJK glyphs (default en)
#   --date YYYY.MM — meta date; defaults to current year.month
#   --title "..."  — passed to watermark.sh; defaults to headline joined with space

set -euo pipefail

SLUG=""
YEAR="$(date +%Y)"
CATEGORY=""
HEADLINE=""
SUB_HOOK=""
VARIANT="essay"
ANCHOR=""
LANG="en"
DATE=""
TITLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug)      SLUG="$2"; shift 2 ;;
    --year)      YEAR="$2"; shift 2 ;;
    --category)  CATEGORY="$2"; shift 2 ;;
    --headline)  HEADLINE="$2"; shift 2 ;;
    --sub-hook)  SUB_HOOK="$2"; shift 2 ;;
    --variant)   VARIANT="$2"; shift 2 ;;
    --anchor)    ANCHOR="$2"; shift 2 ;;
    --lang)      LANG="$2"; shift 2 ;;
    --date)      DATE="$2"; shift 2 ;;
    --title)     TITLE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$SLUG" ]]     && { echo "ERROR: --slug required" >&2; exit 1; }
[[ -z "$HEADLINE" ]] && { echo "ERROR: --headline required" >&2; exit 1; }
[[ -z "$CATEGORY" ]] && CATEGORY="Blog"
[[ -z "$DATE" ]]     && DATE="$(date +%Y.%m)"

case "$VARIANT" in essay|flow|chips|stat) ;; *)
  echo "ERROR: --variant must be essay|flow|chips|stat" >&2; exit 1 ;;
esac

# Split headline on |
IFS='|' read -r H1 H2 <<< "$HEADLINE"
H2="${H2:-}"

# XML-escape (SVG text nodes): &, <, >
xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}
H1_ESC=$(xml_escape "$H1")
H2_ESC=$(xml_escape "$H2")
SUB_ESC=$(xml_escape "$SUB_HOOK")
CATEGORY_UPPER=$(echo "$CATEGORY" | tr '[:lower:]' '[:upper:]')
CAT_ESC=$(xml_escape "$CATEGORY_UPPER")

# Font stack (shared)
FONT_SANS='-apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans TC", sans-serif'
FONT_MONO='"JetBrains Mono", "Consolas", "Menlo", monospace'

# Auto-scale headline font size based on longest line length to prevent right-edge overflow.
# Content runs x=100 to x=1100 = 1000px; char widths at weight 800 are ~0.52em.
# Thresholds tuned empirically — wide glyphs (W, M) push shorter strings to overflow.
max_len=0
for s in "$H1" "$H2"; do
  len=${#s}
  (( len > max_len )) && max_len=$len
done

if [[ "$LANG" == "tc" ]]; then
  # CJK glyphs are denser; scale down and loosen leading
  if   (( max_len <= 10 )); then HEADLINE_SIZE_NORMAL=68
  elif (( max_len <= 14 )); then HEADLINE_SIZE_NORMAL=58
  elif (( max_len <= 18 )); then HEADLINE_SIZE_NORMAL=50
  else                           HEADLINE_SIZE_NORMAL=44
  fi
  HEADLINE_SIZE_STAT=$(( HEADLINE_SIZE_NORMAL - 8 ))
else
  # Latin: 76px fits ~16 chars; step down as lines get longer
  if   (( max_len <= 16 )); then HEADLINE_SIZE_NORMAL=76
  elif (( max_len <= 20 )); then HEADLINE_SIZE_NORMAL=66
  elif (( max_len <= 24 )); then HEADLINE_SIZE_NORMAL=58
  elif (( max_len <= 28 )); then HEADLINE_SIZE_NORMAL=52
  else                           HEADLINE_SIZE_NORMAL=46
  fi
  HEADLINE_SIZE_STAT=$(( HEADLINE_SIZE_NORMAL - 16 ))
fi

# Line spacing scales with size (~1.18 leading looks balanced)
H2_Y_NORMAL=$(( 255 + HEADLINE_SIZE_NORMAL + HEADLINE_SIZE_NORMAL / 5 ))
H2_Y_STAT=$(( 280 + HEADLINE_SIZE_STAT + HEADLINE_SIZE_STAT / 5 ))

# Output path
OUT_DIR="assets/img/blog/${YEAR}/${SLUG}"
OUT_SVG="${OUT_DIR}/${SLUG}-overview.svg"
mkdir -p "$OUT_DIR"

# Build variant-specific anchor SVG fragment (empty for essay).
# flow: sequential boxes with arrows (N=3..5)
# chips: parallel boxes, no arrows, optional "*" suffix on one item for primary highlight (N=2..6)
ANCHOR_BLOCK=""
if [[ "$VARIANT" == "flow" || "$VARIANT" == "chips" ]]; then
  IFS='|' read -ra ITEMS <<< "$ANCHOR"
  N=${#ITEMS[@]}

  if [[ "$VARIANT" == "flow" ]]; then
    (( N < 3 || N > 5 )) && {
      echo "ERROR: flow variant needs --anchor with 3 to 5 items (got $N)" >&2; exit 1; }
    case $N in
      3) BOX_W=160; GAP=60 ;;
      4) BOX_W=138; GAP=40 ;;
      5) BOX_W=116; GAP=28 ;;
    esac
    BOX_H=72
    Y_TOP=465
    LABEL_SIZE=15
  else
    (( N < 2 || N > 6 )) && {
      echo "ERROR: chips variant needs --anchor with 2 to 6 items (got $N)" >&2; exit 1; }
    case $N in
      2) BOX_W=200; GAP=40 ;;
      3) BOX_W=180; GAP=28 ;;
      4) BOX_W=160; GAP=20 ;;
      5) BOX_W=140; GAP=16 ;;
      6) BOX_W=120; GAP=14 ;;
    esac
    BOX_H=56
    Y_TOP=475
    LABEL_SIZE=14
  fi

  TOTAL_W=$(( N * BOX_W + (N - 1) * GAP ))
  START_X=$(( 600 - TOTAL_W / 2 ))
  LABEL_Y=$(( Y_TOP + BOX_H / 2 + 5 ))
  ARROW_Y=$LABEL_Y

  # Pre-validate: at most one "*" highlight marker across all items.
  # (Pre-increment — post-increment returns 0 on first hit and trips `set -e`.)
  star_count=0
  for it in "${ITEMS[@]}"; do
    [[ "${it: -1}" == "*" ]] && (( ++star_count ))
  done
  (( star_count > 1 )) && {
    echo "ERROR: at most one item may carry a '*' suffix (got $star_count)" >&2; exit 1; }
  if [[ "$VARIANT" == "flow" && $star_count -gt 0 ]]; then
    echo "ERROR: '*' highlight is only valid on chips variant, not flow" >&2; exit 1
  fi

  ANCHOR_BLOCK="  <!-- Anchor: ${VARIANT} (${N} items) -->"$'\n'"  <g>"$'\n'
  for i in $(seq 0 $((N - 1))); do
    label="${ITEMS[$i]}"
    is_primary=0
    if [[ "${label: -1}" == "*" ]]; then
      is_primary=1
      label="${label%\*}"
    fi
    label_upper=$(echo "$label" | tr '[:lower:]' '[:upper:]')
    label_esc=$(xml_escape "$label_upper")
    bx=$(( START_X + i * (BOX_W + GAP) ))
    tcx=$(( bx + BOX_W / 2 ))

    if (( is_primary )); then
      rect_fill='fill="#CB4B16"'
      text_fill='#FDF6E3'
    else
      rect_fill='fill="none"'
      text_fill='#CB4B16'
    fi

    ANCHOR_BLOCK+="    <rect x=\"$bx\" y=\"$Y_TOP\" width=\"$BOX_W\" height=\"$BOX_H\" rx=\"14\" $rect_fill stroke=\"#CB4B16\" stroke-width=\"3\"/>"$'\n'
    ANCHOR_BLOCK+="    <text x=\"$tcx\" y=\"$LABEL_Y\" text-anchor=\"middle\" font-family='${FONT_MONO}' font-size=\"$LABEL_SIZE\" font-weight=\"700\" fill=\"$text_fill\" letter-spacing=\"1px\">${label_esc}</text>"$'\n'

    if [[ "$VARIANT" == "flow" && $i -lt $((N - 1)) ]]; then
      arrow_x=$(( bx + BOX_W + GAP / 2 ))
      ANCHOR_BLOCK+="    <text x=\"$arrow_x\" y=\"$ARROW_Y\" text-anchor=\"middle\" font-family='${FONT_SANS}' font-size=\"28\" font-weight=\"700\" fill=\"#93A1A1\">&#8594;</text>"$'\n'
    fi
  done
  ANCHOR_BLOCK+="  </g>"
fi

# Compose full SVG. Stat variant uses a dedicated layout (number left, headline right).
if [[ "$VARIANT" == "stat" ]]; then
  IFS='|' read -r STAT_NUM STAT_CAP <<< "$ANCHOR"
  [[ -z "$STAT_NUM" ]] && { echo "ERROR: stat variant needs --anchor \"NUMBER|CAPTION\"" >&2; exit 1; }
  NUM_ESC=$(xml_escape "$STAT_NUM")
  CAP_ESC=$(xml_escape "${STAT_CAP:-}")
  cat > "$OUT_SVG" <<STAT_SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 630" width="1200" height="630">
  <!-- layout: cream -->
  <rect width="1200" height="630" fill="#FDF6E3"/>

  <!-- Category (top-left) + accent rule -->
  <text x="100" y="92" font-family='${FONT_MONO}' font-size="18" font-weight="700" fill="#CB4B16" letter-spacing="2px">${CAT_ESC}</text>
  <line x1="100" y1="108" x2="188" y2="108" stroke="#CB4B16" stroke-width="3"/>

  <!-- Blog wordmark (top-right) -->
  <text x="1100" y="92" text-anchor="end" font-family='${FONT_MONO}' font-size="14" font-weight="500" fill="#93A1A1" letter-spacing="0.5px">Kevin&#8217;s Tech Blog</text>

  <!-- Stat number (left half, centered around x=260) -->
  <text x="260" y="390" text-anchor="middle" font-family='${FONT_SANS}' font-size="220" font-weight="800" fill="#CB4B16" letter-spacing="-6px">${NUM_ESC}</text>
  <text x="260" y="445" text-anchor="middle" font-family='${FONT_MONO}' font-size="18" font-weight="500" fill="#586E75" letter-spacing="0.5px">${CAP_ESC}</text>

  <!-- Headline (right half) -->
  <text x="500" y="280" font-family='${FONT_SANS}' font-size="${HEADLINE_SIZE_STAT}" font-weight="800" fill="#073642" letter-spacing="-1px">${H1_ESC}</text>
  <text x="500" y="${H2_Y_STAT}" font-family='${FONT_SANS}' font-size="${HEADLINE_SIZE_STAT}" font-weight="800" fill="#073642" letter-spacing="-1px">${H2_ESC}</text>
  <text x="500" y="405" font-family='${FONT_SANS}' font-size="22" font-weight="500" fill="#586E75">${SUB_ESC}</text>

  <!-- Meta (bottom-left) -->
  <text x="100" y="585" font-family='${FONT_MONO}' font-size="16" font-weight="500" fill="#93A1A1" letter-spacing="0.5px">@osisdie &#183; ${DATE}</text>
</svg>
STAT_SVG

else
  # essay + flow share the same main layout; flow adds the anchor block
  cat > "$OUT_SVG" <<NORMAL_SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 630" width="1200" height="630">
  <!-- layout: cream -->
  <rect width="1200" height="630" fill="#FDF6E3"/>

  <!-- Category (top-left) + accent rule -->
  <text x="100" y="92" font-family='${FONT_MONO}' font-size="18" font-weight="700" fill="#CB4B16" letter-spacing="2px">${CAT_ESC}</text>
  <line x1="100" y1="108" x2="188" y2="108" stroke="#CB4B16" stroke-width="3"/>

  <!-- Blog wordmark (top-right) -->
  <text x="1100" y="92" text-anchor="end" font-family='${FONT_MONO}' font-size="14" font-weight="500" fill="#93A1A1" letter-spacing="0.5px">Kevin&#8217;s Tech Blog</text>

  <!-- Headline (2 lines, left-aligned) -->
  <text x="100" y="255" font-family='${FONT_SANS}' font-size="${HEADLINE_SIZE_NORMAL}" font-weight="800" fill="#073642" letter-spacing="-1px">${H1_ESC}</text>
  <text x="100" y="${H2_Y_NORMAL}" font-family='${FONT_SANS}' font-size="${HEADLINE_SIZE_NORMAL}" font-weight="800" fill="#073642" letter-spacing="-1px">${H2_ESC}</text>

  <!-- Sub-hook -->
  <text x="100" y="405" font-family='${FONT_SANS}' font-size="26" font-weight="500" fill="#586E75">${SUB_ESC}</text>
${ANCHOR_BLOCK}

  <!-- Meta (bottom-left) -->
  <text x="100" y="585" font-family='${FONT_MONO}' font-size="16" font-weight="500" fill="#93A1A1" letter-spacing="0.5px">@osisdie &#183; ${DATE}</text>
</svg>
NORMAL_SVG
fi

echo "[SVG] $OUT_SVG — variant=$VARIANT, lang=$LANG"

# Delegate to watermark.sh for attribution + PNG rasterization
WM_TITLE="${TITLE:-${H1}${H2:+ — $H2}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/watermark.sh" "$OUT_SVG" "$WM_TITLE"
