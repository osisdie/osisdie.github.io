---
name: new-post
description: Scaffold a new blog post with correct conventions, image directory, and branch
user_invocable: true
arguments:
  - name: topic
    description: Brief topic description (e.g. "RAG challenges", "Stop Hook deep dive")
    required: true
---

# New Blog Post Scaffold

Create a new blog post following the established conventions for this Jekyll (al-folio) tech blog.

## Step 1: Gather Information

Ask the user for:
1. **Topic** (provided as argument): {{ topic }}
2. **Title** (Chinese, with English terms kept as-is)
3. **Slug** (short, lowercase, hyphenated — used for URL and image folder)
4. **Tags** (space-separated, from existing: llm ai rag graph-rag agentic-rag self-rag ragas claude-code hooks agent-loop automation bash — or new ones)
5. **Featured** (true/false, default true)

## Step 2: Create Branch

```bash
git checkout main && git pull
git checkout -b feat/{slug}-post
```

## Step 3: Create Image Directory

```
assets/img/blog/{year}/{slug}/
```

This is where the hero SVG and PNG will go.

## Step 4: Create Post File

Create `_posts/{year}/{year}-{month}-{day}-{slug}.md` with this template:

```markdown
---
layout: post
title: "{title}"
date: {YYYY-MM-DD} 10:00:00 +0800
description: {one-line Chinese description for SEO}
tags: {tags}
featured: {true|false}
og_image: /assets/img/blog/{year}/{slug}/{slug}-overview.png
toc:
  sidebar: left
---

{% raw %}{% include figure.liquid loading="eager" path="assets/img/blog/{year}/{slug}/{slug}-overview.png" class="img-fluid rounded z-depth-1" alt="{English alt text}" caption="{Chinese caption}" %}{% endraw %}

> **English Abstract** — {150 words summarizing the post for international readers}

{Chinese hook sentence — engaging opening that makes readers want to continue}

---

## {Section 1 Title}

### {Subsection}

{Content — keep paragraphs to 4-6 lines max}

```{language}
# Code snippet with language tag (bash, python, yaml, text, json)
```

> **Production Notes** — {Practical tip for this section}

---

## {More sections...}

---

## References

- **{Paper/Tool Name}** — [{Display Text}]({URL})

---

> Source: [osisdie/osisdie.github.io](https://github.com/osisdie/osisdie.github.io) — PRs and Issues welcome!
```

## Step 5: Hero Image (SVG → PNG)

Create the hero SVG following these rules (see `assets/docs/svg-png-guide.md`):

- **Fonts**: use system stack `-apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans TC", sans-serif`
- **Colors**: hardcode values only — NO `var(--*)`, NO proprietary fonts
- **Layout**: vertical flow preferred (avoids horizontal overflow on mobile)
- **viewBox**: fixed dimensions (e.g. `viewBox="0 0 680 780"`)

Convert to PNG:
```bash
rsvg-convert {slug}-overview.svg -w 1360 -b white -o {slug}-overview.png
```

Verify: read the PNG to check Chinese text renders correctly.

## Step 6: Content Conventions

- **Bilingual**: English abstract in blockquote, Chinese body text
- **Bold**: key technical terms on first mention (`**cosine similarity**`)
- **Code blocks**: always specify language tag (```bash, ```python, ```yaml, ```text, ```json)
- **Production Notes**: blockquote after each major section with practical tips
- **Paragraphs**: 4-6 lines max for mobile readability
- **Transition sentences**: end each problem/challenge section with → linking to solution
- **References**: papers with arXiv links, tools with GitHub links

## Step 7: Commit and PR

```bash
git add _posts/{year}/ assets/img/blog/{year}/{slug}/
git commit -m "feat: add blog post - {short description}"
git push -u origin feat/{slug}-post
gh pr create --title "feat: add {slug} blog post" --body "..."
```

**Commit rules:**
- Use conventional commits (`feat:`, `fix:`, `docs:`, `refactor:`)
- NO AI model names in commit messages (enforced by pre-push hook)
- NO Co-Authored-By lines
