# osisdie.github.io

[![Deploy site](https://github.com/osisdie/osisdie.github.io/actions/workflows/deploy.yml/badge.svg)](https://github.com/osisdie/osisdie.github.io/actions/workflows/deploy.yml)
[![GitHub Pages](https://img.shields.io/badge/GitHub%20Pages-live-brightgreen?logo=github)](https://osisdie.github.io)
[![Jekyll](https://img.shields.io/badge/Jekyll-al--folio-red?logo=jekyll)](https://github.com/alshedivat/al-folio)
[![License](https://img.shields.io/github/license/osisdie/osisdie.github.io)](LICENSE)

Tech blog covering LLM, AI, RAG, .NET, Python, and Cloud engineering.

**Live site**: [https://osisdie.github.io](https://osisdie.github.io)

## Tech Stack

- [Jekyll](https://jekyllrb.com/) with [al-folio](https://github.com/alshedivat/al-folio) theme (v0.16.3)
- GitHub Pages + GitHub Actions CI/CD
- Deployed automatically on push to `main` via PR workflow

## Blog Tags

| Tag | Area |
|-----|------|
| `llm`, `ai`, `rag` | Displayed on blog index page |
| `graph-rag`, `agentic-rag`, `self-rag`, `ragas` | Post-level tags for discoverability |
| `claude-code`, `hooks`, `automation` | Tooling & workflow |

## Project Categories

| Category | Count |
|----------|-------|
| `claude` | 3 |
| `openclaw` | 2 |
| `ai` | 8 |
| `agent` | 2 |
| `game` | 3 |
| `dotnet` | 6 |
| `tool` | 3 |
| `programming` | 4 |

## Local Development

```bash
# Docker (recommended)
docker compose up
# Site available at http://localhost:8080
```

## Writing Posts

Create a new file in `_posts/{year}/YYYY-MM-DD-title.md`:

```yaml
---
layout: post
title: "Your Post Title"
date: 2026-03-26 10:00:00 +0800
description: Brief description for SEO and previews
tags: rag llm ai
featured: true
og_image: /assets/img/blog/2026/your-slug/hero.png
toc:
  sidebar: left
---
```

### Conventions

- **Blog images**: `assets/img/blog/{year}/{slug}/` (e.g. `assets/img/blog/2026/rag-challenges/`)
- **Commit messages**: use [Conventional Commits](https://www.conventionalcommits.org/) — no AI model names (enforced by pre-push hook)
- **Workflow**: always create a feature branch and submit a PR — no direct pushes to `main`
