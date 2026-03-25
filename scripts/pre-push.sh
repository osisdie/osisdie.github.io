#!/usr/bin/env bash
# Git pre-push hook — blocks push on YAML lint, security, or commit message failures.
# Install: ln -sf ../../scripts/pre-push.sh .git/hooks/pre-push
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

MAIN=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@' || echo main)
FAIL=0
WARN=0

pass()  { echo "  [PASS] $1"; }
fail()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn()  { echo "  [WARN] $1"; WARN=$((WARN+1)); }

echo "========================================"
echo "  PRE-PUSH REVIEW"
echo "========================================"

# ── 1. YAML lint ──────────────────────────────
if command -v python3 >/dev/null 2>&1; then
  YAML_ERRORS=""
  for f in _config.yml _data/*.yml; do
    [ -f "$f" ] || continue
    if ! python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null; then
      YAML_ERRORS+="  Invalid YAML: $f"$'\n'
    fi
  done
  if [ -z "$YAML_ERRORS" ]; then
    pass "YAML lint — all config files valid"
  else
    fail "YAML lint — invalid files found"
    echo "$YAML_ERRORS"
  fi
else
  warn "YAML lint — python3 not found, skipping"
fi

# ── 2. Jekyll front matter check ─────────────
FM_ERRORS=""
for f in $(find _posts/ _projects/ -name '*.md' 2>/dev/null); do
  if ! head -1 "$f" | grep -q '^---$'; then
    FM_ERRORS+="  Missing front matter: $f"$'\n'
  fi
done
if [ -z "$FM_ERRORS" ]; then
  pass "Front matter — all posts/projects have YAML header"
else
  fail "Front matter — missing in some files"
  echo "$FM_ERRORS"
fi

# ── 3. Security: secrets in diff ──────────────
DIFF=$(git diff "$MAIN"...HEAD -- . ':!*.lock' ':!node_modules' ':!.venv' ':!*.sample' 2>/dev/null || true)
SECRETS_FOUND=""
while IFS= read -r pattern; do
  if echo "$DIFF" | grep -qiE -- "$pattern"; then
    SECRETS_FOUND+="  Pattern matched: $pattern"$'\n'
  fi
done <<'PATTERNS'
AIza[0-9A-Za-z_-]{35}
sk-[A-Za-z0-9]{20,}
ghp_[A-Za-z0-9]{36}
glpat-[A-Za-z0-9_-]{20}
xoxb-[0-9]{10,}
-----BEGIN (RSA |EC )?PRIVATE KEY-----
PATTERNS

if [ -z "$SECRETS_FOUND" ]; then
  pass "Security — No secrets in diff"
else
  fail "Security — Possible secrets detected"
  echo "$SECRETS_FOUND"
fi

# ── 4. Conventional commits ───────────────────
COMMITS=$(git log "$MAIN"..HEAD --format="%H %s" 2>/dev/null || true)
CC_OK=true
if [ -n "$COMMITS" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    hash="${line%% *}"
    subject="${line#* }"
    short="${hash:0:8}"

    # Check conventional commit format
    if ! echo "$subject" | grep -qP '^(feat|fix|refactor|docs|style|test|ci|chore|perf|build|revert)(\(.+\))?!?: .+'; then
      fail "Commit $short — not conventional: $subject"
      CC_OK=false
    fi

    # Check for AI model mentions (subject + body)
    body=$(git log -1 --format="%B" "$hash")
    if echo "$body" | grep -qiP '(claude|anthropic|openai|co-authored-by.*(claude|anthropic|openai|copilot))'; then
      fail "Commit $short — mentions AI model: $subject"
      CC_OK=false
    fi
  done <<< "$COMMITS"
fi
$CC_OK && pass "Conventional Commits"

# ── 5. Large files check ─────────────────────
LARGE_FILES=""
for f in $(git diff --name-only "$MAIN"...HEAD 2>/dev/null || true); do
  [ -f "$f" ] || continue
  SIZE=$(wc -c < "$f" 2>/dev/null || echo 0)
  if [ "$SIZE" -gt 5242880 ]; then
    LARGE_FILES+="  $f ($(( SIZE / 1048576 ))MB)"$'\n'
  fi
done
if [ -z "$LARGE_FILES" ]; then
  pass "Large files — none over 5MB"
else
  fail "Large files — found files over 5MB"
  echo "$LARGE_FILES"
fi

# ── 6. README existence ──────────────────────
if [ -f README.md ]; then
  pass "README.md exists"
else
  warn "README.md not found"
fi

# ── Result ────────────────────────────────────
echo "========================================"
if [ "$FAIL" -gt 0 ]; then
  echo "  RESULT: FAIL ($FAIL issue(s), $WARN warning(s))"
  echo "========================================"
  exit 1
else
  echo "  RESULT: PASS ($WARN warning(s))"
  echo "========================================"
  exit 0
fi
