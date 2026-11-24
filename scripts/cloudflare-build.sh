#!/usr/bin/env bash
set -euo pipefail

# Cloudflare Workers Builds settings:
#   Build command: bash scripts/cloudflare-build.sh
#   Deploy command: npx --yes wrangler@4 deploy --config wrangler.toml
#   Build variables: HUGO_VERSION=0.170.1, GO_VERSION=1.27.4,
#                    SITE_URL, ABOUT_URL, PUBLICATIONS_URL

: "${SITE_URL:?Set SITE_URL in Cloudflare Build variables}"
: "${ABOUT_URL:?Set ABOUT_URL in Cloudflare Build variables}"
: "${PUBLICATIONS_URL:?Set PUBLICATIONS_URL in Cloudflare Build variables}"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

toml_quote() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    case "$value" in
        *$'\n'*) echo "Build variable contains a newline" >&2; return 1 ;;
    esac
    printf '"%s"' "$value"
}

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
if ! GOPROXY=direct go run github.com/lbenicio/theme/cmd/ogimage@v0.6.0 \
    --glob="content/post/*/*/*/*.md" --out="static/static/og"; then
    echo "Warning: Open Graph image generation failed; continuing with the site build" >&2
fi

dynamic_config="$work_dir/hugo-dynamic.toml"
{
    printf 'baseURL = %s\n' "$(toml_quote "$SITE_URL")"
    printf '[params]\n'
    printf 'siteUrl = %s\n' "$(toml_quote "$SITE_URL")"
    printf 'aboutOrigin = %s\n' "$(toml_quote "$ABOUT_URL")"
    printf 'blogOrigin = %s\n' "$(toml_quote "$SITE_URL")"
    printf 'publicationsOrigin = %s\n' "$(toml_quote "$PUBLICATIONS_URL")"
} > "$dynamic_config"

echo "Building Hugo site"
hugo --minify --environment production --cleanDestinationDir \
    --config "hugo.toml,$dynamic_config" --logLevel info

echo "Obfuscating generated site assets"
GOPROXY=direct go run github.com/lbenicio/theme/cmd/obfuscate@v0.6.0 -verbose ./public

echo "Cloudflare build complete: $(find public -type f | wc -l | tr -d ' ') files"
