# Stage 1 — build the site
FROM alpine:latest AS build

# Install Hugo Extended and Go
RUN apk add --update --no-cache hugo go git

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
