#!/usr/bin/env bash
# Commit-msg hook: block AI model names and Co-Authored-By in commit messages.

COMMIT_MSG_FILE="$1"

# Block AI model names
AI_PATTERN='(claude|anthropic|openai|chatgpt|gpt-[34]|copilot|gemini|sonnet|opus|haiku)'
if grep -qiE "$AI_PATTERN" "$COMMIT_MSG_FILE"; then
  echo "❌ AI model name detected in commit message:"
  grep -iE "$AI_PATTERN" "$COMMIT_MSG_FILE"
  echo ""
  echo "Remove references to AI models from your commit message."
  exit 1
fi

# Block Co-Authored-By
if grep -qiE '^Co-Authored-By:' "$COMMIT_MSG_FILE"; then
  echo "❌ Co-Authored-By detected in commit message:"
  grep -iE '^Co-Authored-By:' "$COMMIT_MSG_FILE"
  echo ""
  echo "Remove Co-Authored-By lines from your commit message."
  exit 1
fi
