# Changelog

All notable changes to this project are documented in this file. This project follows the "Keep a Changelog" format and adheres to Semantic Versioning.

Full changelog: <https://github.com/lbenicio/blog/commits/main>

## [2.1.1] - 2026-10-16

### Added

- **Post index JSON** — added structured JSON output for post metadata, tags, categories, dates, covers, and links.
- **Publications origin** — added configuration for cross-site publication links.

### Changed

- **Theme updated** to v0.4.1 — production-only class obfuscation, readable local development classes, valid CSS aliases, and the Hugo deprecation fix.
- **CI site URLs** — blog variant builds now use the blog’s own Pages URL and publish the home site’s publications origin.

### Fixed

- **Umami analytics** — configured the blog website ID `649d8c68-53f2-4687-9971-c39ba81c408f` with `https://analytics.4686189.xyz/script.js`.

## [2.1.0] - 2026-06-21

### Added

- **Calendar** — month, day, and year views with calendar-grid rendering, prev/next navigation, and post links in day cells. Generated automatically at build time via the theme's content adapter (`_content.gotmpl`); zero stub files required.
- **Blog subnav** — Tags, Categories, and Calendar links in a secondary navigation bar below the header.
- **Dynamic URL resolution** — CI workflow queries GitHub API for cross-repo Pages URLs and writes a `/tmp/hugo-dynamic.toml` config at build time.

### Changed

- **Hardcoded URLs** — replaced production URLs in `hugo.toml` with `localhost:1313` dev defaults; CI overrides them dynamically.
- **Go version** — CI workflows updated from Go 1.23 to 1.26.
- **Action versions** — synced across all workflow jobs (`cache@v5`, `setup-go@v6`, `deploy-pages@v5`, `upload-pages-artifact@v5`).
- **Calendar page generation** — removed CI `Generate calendar pages` step and local `scripts/generate-calendar-pages.sh`; replaced by theme content adapter.

### Fixed

- **CSS grid** — added missing `.grid-cols-4` through `.grid-cols-7`, responsive variants, `xl` breakpoint, ring, gap, and arbitrary-value classes to the theme SCSS.
- **Search** — index.json path respects `baseURL` for sub-path deployments.
- **Post images** — hero image URLs use `relURL` for correct path resolution under `/blog/` base path.
- **Tags styling** — taxonomy and term pages use grid layout with hover states and post-card rendering.

## [2.0.0] - 2026-06-20

### Added

- Initial blog deployment using `aboutme-v2-theme` v0.3.0 (SCSS-powered, no Node.js).
- BLOG_ONLY mode with blog listing, search, pagination, and RSS feed.
- GitHub Actions workflow for build + obfuscate + deploy to GitHub Pages.
- Docker support for containerized deployment.

### Changed

- Configured for `https://lbenicio.github.io/blog/` with `/blog/` base path.
- Header links back to about site (`https://lbenicio.dev`).
- Umami analytics via `umamiBlogId`.

### Removed

- Non-blog content types (publications, reading, timeline, about, contact).
- Newsletter configuration.
