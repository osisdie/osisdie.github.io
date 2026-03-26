---
name: publish-post
description: Commit, push, create PR, wait for CI, and merge a blog post branch
user_invocable: true
---

# Publish Blog Post

Finalize and publish the current blog post branch via PR workflow.

## Step 1: Pre-flight Checks

```bash
git status
git diff --stat
```

Verify:
- [ ] Post file exists in `_posts/{year}/`
- [ ] Hero image (SVG + PNG) exists in `assets/img/blog/{year}/{slug}/`
- [ ] No untracked files that should be committed
- [ ] No sensitive files (.env, credentials)

## Step 2: Commit

Stage all post-related files and commit:

```bash
git add _posts/{year}/ assets/img/blog/{year}/{slug}/ {any other changed files}
git commit -m "feat: add blog post - {short description}"
```

**Rules:**
- Conventional commits only
- NO AI model names anywhere in commit message
- NO Co-Authored-By lines

## Step 3: Push and Create PR

```bash
git push -u origin {branch-name}
gh pr create --title "feat: {short title}" --body "$(cat <<'EOF'
## Summary
- {1-3 bullet points}

## Test plan
- [ ] Verify post renders with correct TOC sidebar
- [ ] Verify hero image is crisp
- [ ] Verify code blocks render correctly
- [ ] Verify all links work
EOF
)"
```

## Step 4: Wait for CI

```bash
sleep 10 && gh pr checks {pr-number}
```

Wait for GitGuardian Security Checks to pass.

## Step 5: Merge

```bash
gh pr merge {pr-number} --admin --merge --delete-branch
```

## Step 6: Verify Deployment

After GitHub Pages rebuilds (~2 min), verify:
```bash
# Use Playwright MCP to screenshot the deployed post
```

Or ask the user to check the live URL.
