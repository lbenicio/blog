#!/usr/bin/env bash
set -euo pipefail

# Cloudflare Workers Builds settings:
#   Build command: bash scripts/cloudflare-build.sh
#   Deploy command: npx --yes wrangler@4 deploy --config wrangler.toml
#   Build variables: HUGO_VERSION=0.170.1, GO_VERSION=1.27.4

expected_hugo_version="0.170.1"
actual_hugo_version="$(hugo version | awk '{print $2}' | sed -E 's/^v//; s/[-+].*$//')"
if [ "$actual_hugo_version" != "$expected_hugo_version" ]; then
    printf 'Hugo version mismatch: expected %s; Cloudflare Workers Builds must set HUGO_VERSION=%s (found %s).\n' \
        "$expected_hugo_version" "$expected_hugo_version" "${actual_hugo_version:-unknown}" >&2
    exit 1
fi
echo "Using Hugo $actual_hugo_version"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

echo "Downloading Go and Hugo modules"
go mod download
hugo mod get

dart_sass_version="1.108.0"
dart_sass_sha256="e608a6a633af36ab518919b502581d891d50a05e3adf5bd541e977ab6a4a92a1"
dart_sass_archive="$work_dir/dart-sass.tar.gz"
curl --fail --silent --show-error --location \
    "https://github.com/sass/dart-sass/releases/download/${dart_sass_version}/dart-sass-${dart_sass_version}-linux-x64.tar.gz" \
    --output "$dart_sass_archive"
printf '%s  %s\n' "$dart_sass_sha256" "$dart_sass_archive" | sha256sum --check --status
tar -xzf "$dart_sass_archive" -C "$work_dir"
export PATH="$work_dir/dart-sass:$PATH"
sass --version

echo "Generating Open Graph images"
if ! GOPROXY=direct go run github.com/lbenicio/theme/cmd/ogimage@v0.7.1 \
    --glob="content/post/*/*/*/*.md" --out="static/static/og"; then
    echo "Warning: Open Graph image generation failed; continuing with the site build" >&2
fi

echo "Building Hugo site"
hugo --minify --environment production --cleanDestinationDir \
    --config hugo.toml --logLevel info

echo "Obfuscating generated site assets"
GOPROXY=direct go run github.com/lbenicio/theme/cmd/obfuscate@v0.7.1 -verbose ./public

echo "Cloudflare build complete: $(find public -type f | wc -l | tr -d ' ') files"
