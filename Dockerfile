# Stage 1 — build the site
FROM alpine:latest AS build

ARG HUGO_VERSION=0.163.1
ARG HUGO_SHA256=b64ead3135eab66e0fab818b96a63c21c37a068fbb8c2d300627ed51c1217dd7

# Install the same Hugo Extended release used by the deployment workflow.
RUN apk add --no-cache ca-certificates curl go git tar \
    && curl --fail --silent --show-error --location \
      "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-amd64.tar.gz" \
      --output /tmp/hugo.tar.gz \
    && echo "${HUGO_SHA256}  /tmp/hugo.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/hugo.tar.gz -C /usr/local/bin hugo \
    && rm /tmp/hugo.tar.gz

# Allow Go to download required toolchain version (go.mod requires >=1.26.4, Alpine ships 1.26.3)
ENV GOTOOLCHAIN=auto

RUN hugo version && go version

WORKDIR /src

COPY . .

# Download Hugo modules
RUN hugo mod get

# Generate OG images and build
RUN go run github.com/lbenicio/aboutme-v2-theme/cmd/ogimage@latest \
      --glob="content/post/*.md" --out="static/assets/og" || true
RUN hugo --minify --environment production --cleanDestinationDir
RUN go run github.com/lbenicio/aboutme-v2-theme/cmd/obfuscate@latest ./public || true

# Stage 2 — serve
FROM nginx:alpine

WORKDIR /usr/share/nginx/html

COPY --from=build /src/public .

EXPOSE 80
