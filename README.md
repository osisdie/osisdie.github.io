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
- Deployed automatically on push to `main`

## Topics

| Area | Tags |
|------|------|
| AI / ML | `llm`, `ai`, `rag` |
| Languages | `dotnet`, `python` |
| Infrastructure | `cloud`, `architecture`, `devops` |

## Local Development

```bash
# Docker (recommended)
docker compose up

# Or traditional Ruby setup
bundle install
bundle exec jekyll serve --livereload
```

## Writing Posts

Create a new file in `_posts/` with the format `YYYY-MM-DD-title.md`:

```yaml
---
layout: post
title: "Your Post Title"
date: 2026-03-25 10:00:00 +0800
description: Brief description for SEO and previews
tags: rag llm ai
categories: deep-dives
featured: true
toc:
  sidebar: left
---

Your content here...
```

### Categories

| Category | Purpose |
|----------|---------|
| `tutorials` | Step-by-step guides |
| `deep-dives` | In-depth technical analysis |
| `til` | Today I Learned (short posts) |
| `career` | Career growth, interviews, soft skills |
