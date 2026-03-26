#!/bin/bash
# =============================================================================
# Jekyll Local Development Setup (Docker)
# =============================================================================
#
# This project uses Docker for local development. Native Ruby is not supported
# due to gem compatibility issues (sassc vs dart-sass, activesupport version).
#
# Usage:
#   ./scripts/install.sh        # Build and start
#   docker compose up           # Start (after initial build)
#   docker compose up --build   # Rebuild after Gemfile changes
#
# Site: http://localhost:4000
#
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Check Docker
if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Install Docker Desktop first:"
  echo "  https://docs.docker.com/get-docker/"
  exit 1
fi

# Generate Gemfile.lock if missing
if [[ ! -f Gemfile.lock ]]; then
  info "Generating Gemfile.lock..."
  docker run --rm -v "$PWD":/srv/jekyll -w /srv/jekyll ruby:3.3 bundle lock
fi

# Build
info "Building Docker image..."
docker compose build

# Start
info "Starting Jekyll..."
echo ""
echo "  Site: http://localhost:4000"
echo "  LiveReload: auto-enabled on port 35729"
echo "  Stop: Ctrl+C"
echo ""
warn "If port 4000 is not accessible on WSL2, try: http://127.0.0.1:4000"
echo ""

docker compose up
