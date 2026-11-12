# Stage 1 — build the site
FROM golang:1.27.0-bookworm AS build

ARG HUGO_VERSION=0.163.1
ARG DART_SASS_VERSION=1.108.0
ARG HUGO_SHA256_AMD64=b64ead3135eab66e0fab818b96a63c21c37a068fbb8c2d300627ed51c1217dd7
ARG HUGO_SHA256_ARM64=6ec4cc914c475ab0091e2b3cddce81442015c6cf2bc784361a5d30ce4701824c
ARG TARGETARCH

# Install the same Hugo Extended release used by the deployment workflow.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git libstdc++6 tar \
    && rm -rf /var/lib/apt/lists/* \
    && case "${TARGETARCH}" in \
         amd64) HUGO_SHA256="${HUGO_SHA256_AMD64}" ;; \
         arm64) HUGO_SHA256="${HUGO_SHA256_ARM64}" ;; \
         *) echo "Unsupported target architecture: ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && curl --fail --silent --show-error --location \
      "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-${TARGETARCH}.tar.gz" \
      --output /tmp/hugo.tar.gz \
    && echo "${HUGO_SHA256}  /tmp/hugo.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/hugo.tar.gz -C /usr/local/bin hugo \
    && rm /tmp/hugo.tar.gz

RUN case "${TARGETARCH}" in \
         amd64) DART_SASS_ARCH=x64; DART_SASS_SHA256=e608a6a633af36ab518919b502581d891d50a05e3adf5bd541e977ab6a4a92a1 ;; \
         arm64) DART_SASS_ARCH=arm64; DART_SASS_SHA256=48144565dacb0277e3894be57e85ea7c1b4620ed50326366731aa484fa12b9e3 ;; \
         *) echo "Unsupported target architecture: ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && curl --fail --silent --show-error --location \
      "https://github.com/sass/dart-sass/releases/download/${DART_SASS_VERSION}/dart-sass-${DART_SASS_VERSION}-linux-${DART_SASS_ARCH}.tar.gz" \
      --output /tmp/dart-sass.tar.gz \
    && echo "${DART_SASS_SHA256}  /tmp/dart-sass.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/dart-sass.tar.gz -C /usr/local/lib \
    && ln -s /usr/local/lib/dart-sass/sass /usr/local/bin/sass \
    && rm /tmp/dart-sass.tar.gz \
    && sass --version

# Allow Go to fetch the version required by go.mod if it is newer than the image toolchain.
ENV GOTOOLCHAIN=auto

RUN hugo version && go version

WORKDIR /src

COPY . .

# Download Hugo modules
RUN hugo mod get

# Generate OG images and build
RUN go run github.com/lbenicio/theme/cmd/ogimage@v0.6.0 \
      --glob="content/post/*.md" --out="static/assets/og" || true
RUN hugo --minify --environment production --cleanDestinationDir
RUN GOPROXY=direct go run github.com/lbenicio/theme/cmd/obfuscate@v0.6.0 ./public || true

# Stage 2 — serve
FROM nginx:alpine

WORKDIR /usr/share/nginx/html

COPY --from=build /src/public .

EXPOSE 80
