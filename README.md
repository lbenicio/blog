# Blog — Personal Blog

**Current version:** `2.1.11`

![GitHub License](https://img.shields.io/github/license/lbenicio/blog?style=flat&color=blue)
![GitHub Release](https://img.shields.io/github/v/release/lbenicio/blog?color=blue)
[![Deploy](https://github.com/lbenicio/blog/actions/workflows/deploy.yml/badge.svg)](https://github.com/lbenicio/blog/actions/workflows/deploy.yml)

Personal blog built with [Hugo](https://gohugo.io/) and the [aboutme-theme](https://github.com/lbenicio/theme) in `BLOG_ONLY` mode. No Node.js required; Hugo Pipes compiles SCSS using Dart Sass.

Deployed at **[blog.lbenicio.dev](https://blog.lbenicio.dev/)**. The main about site lives at **[lbenicio.dev](https://lbenicio.dev/)**.

## 🚀 Quick Start

### Prerequisites

- **Hugo** v0.163.0 or higher (standard or extended edition)
- **Dart Sass** with the `sass` executable available on `PATH`
- **Go** 1.27.0 or higher

### Run locally

```bash
git clone https://github.com/lbenicio/blog.git
```

```bash
cd blog
```

```bash
hugo server
```

No `npm install` is required. Hugo uses Dart Sass on `PATH` for SCSS compilation, CSS minification, and asset processing.

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
  siteUrl = "https://blog.lbenicio.dev/"
  aboutOrigin = "https://lbenicio.dev/"        # Header link back to about
  blogOrigin = "https://blog.lbenicio.dev/"
```

### Adding posts

Create a markdown file in `content/post/YYYY/MM/DD/` using a lowercase, hyphen-separated filename. The directory date comes from the post's `date` front matter. For example, `content/post/2026/06/20/your-post-title.md`:

```yaml
---
title: "Your Post Title"
description: "Brief description for SEO and listings"
date: "2026-06-20"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory"]
draft: false
cover: "https://cdn.lbenicio.dev/static/images/blog/your-cover.png"
coverAlt: "Description of cover image"
---
```

## 🔒 Security

- **Class/ID obfuscation**: All identifiers obfuscated post-build.
- **Analytics**: Google Analytics 4 runs on production builds and respects the browser's Do Not Track signal.
- **Static site**: No server-side attack surface.

## 🚢 Deployment

Pushes to `main` trigger the [deploy workflow](.github/workflows/deploy.yml), which builds the Hugo site, obfuscates identifiers, and deploys the generated files to Cloudflare Workers.

GitHub Actions deploys this static site to Cloudflare Workers. Configure the repository secrets `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`; the Worker serves the site on its custom domain.

## 📦 Dependencies

```
require github.com/lbenicio/theme v0.7.2
```

---

**Built with Hugo + aboutme-theme • © 2026 Leonardo Benicio**


Before the first deployment, configure the two Cloudflare secrets above. If the hostname still has a DNS CNAME pointing to AWS, remove that conflicting record before Wrangler creates the Worker custom domain.
