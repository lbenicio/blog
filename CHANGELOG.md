# Changelog

All notable changes to this project are documented in this file. This project follows the "Keep a Changelog" format and adheres to Semantic Versioning.

Full changelog: <https://github.com/lbenicio/blog/commits/main>

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
