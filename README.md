# Blog — Personal Blog

![GitHub License](https://img.shields.io/github/license/lbenicio/blog?style=flat&color=blue)
![GitHub Release](https://img.shields.io/github/v/release/lbenicio/blog?color=blue)
[![Deploy](https://github.com/lbenicio/blog/actions/workflows/deploy.yml/badge.svg)](https://github.com/lbenicio/blog/actions/workflows/deploy.yml)

Personal blog built with [Hugo](https://gohugo.io/) and the [aboutme-v2-theme](https://github.com/lbenicio/aboutme-v2-theme) in `BLOG_ONLY` mode. No Node.js required — SCSS is compiled natively by Hugo Pipes.

Deployed at **[lbenicio.github.io/blog](https://lbenicio.github.io/blog/)**. The main about site lives at **[lbenicio.dev](https://lbenicio.dev/)**.

## 🚀 Quick Start

### Prerequisites

- **Hugo Extended** v0.163.0 or higher
- **Go** 1.23+

### Run locally

```bash
git clone https://github.com/lbenicio/blog.git
cd blog
hugo server
```

No `npm install`. Hugo handles SCSS compilation, CSS minification, and asset processing.

## 📁 Project Structure

```text
.
├── content/
│   ├── _index.md            # Blog landing (handled by BLOG_ONLY mode)
│   └── post/                # Blog posts by year
│       ├── _index.md
│       ├── 2024/
│       ├── 2025/
│       └── 2026/
├── hugo.toml                # Site configuration
├── go.mod                   # Hugo module dependency
└── .github/workflows/       # CI/CD (build → obfuscate → deploy)
```

## ⚙️ Configuration

The site runs in `BLOG_ONLY` mode — only the blog listing and post pages are rendered. The header links back to the main about site.

```toml
[params]
  appMode = "BLOG_ONLY"
  siteUrl = "https://lbenicio.github.io"
  aboutOrigin = "https://lbenicio.dev"        # Header link back to about
  blogOrigin = "https://lbenicio.github.io/blog"
```

### Adding posts

Create a markdown file in `content/post/YYYY/`:

```yaml
---
title: "Your Post Title"
description: "Brief description for SEO and listings"
date: "2026-06-20"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory"]
draft: false
cover: "/static/assets/images/blog/your-cover.png"
coverAlt: "Description of cover image"
---
```

## 🔒 Security

- **Class/ID obfuscation**: All identifiers obfuscated post-build.
- **No external scripts**: Self-hosted JS only (search, theme toggle, analytics).
- **Static site**: No server-side attack surface.

## 🚢 Deployment

Pushes to `main` trigger the [deploy workflow](.github/workflows/deploy.yml):
1. Install Go + Hugo deps
2. Generate OG images for posts
3. Build with Hugo (`--minify --environment production`)
4. Obfuscate identifiers
5. Deploy to GitHub Pages

## 📦 Dependencies

Zero Node.js. Only Hugo Extended required.

```
require github.com/lbenicio/aboutme-v2-theme v0.3.0
```

---

**Built with Hugo + aboutme-v2-theme • © 2026 Leonardo Benicio**
