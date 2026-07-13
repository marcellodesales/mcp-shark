####
#### MCP Shark — proxy + browser dashboard runtime image.
####
#### This image is a thin runtime wrapper around the published `@mcp-shark/mcp-shark`
#### npm CLI — it does NOT build the product from local source. It matches the
#### deployment pattern used by the kortex mcp-inspector Deployment, which pins
#### and runs the upstream `modelcontextprotocol/inspector` image directly.
####
#### Build:
####   docker build -t mcp-shark:local .
####   docker build --build-arg MCP_SHARK_VERSION=1.7.2 -t mcp-shark:1.7.2 .
####
#### Run:
####   docker run --rm -p 9853:9853 \
####     -v mcp-shark-home:/home/mcpshark/.mcp-shark \
####     mcp-shark:local
####   # then open http://localhost:9853
####
# --- Stage 1: compile native modules with a full toolchain ---
# `better-sqlite3`'s prebuilt binary doesn't always match the runtime's Node
# ABI + libc + arch triple (e.g. on Node 20.20 arm64), so we build from source
# once in a throwaway builder image and copy the compiled artifacts forward.
FROM node:20-slim AS builder

ARG MCP_SHARK_VERSION=1.7.2

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ \
 && rm -rf /var/lib/apt/lists/*

# Install globally into /usr/local/lib/node_modules. `--unsafe-perm` lets the
# better-sqlite3 postinstall run its gyp rebuild (npm otherwise drops perms
# for scripts run by root and node-gyp then fails to write into /root/.cache).
RUN npm install -g --unsafe-perm --omit=dev "@mcp-shark/mcp-shark@${MCP_SHARK_VERSION}" \
 && npm cache clean --force

# --- Stage 2: runtime image, no toolchain ---
FROM node:20-slim AS runtime

ARG MCP_SHARK_VERSION=1.7.2

LABEL org.opencontainers.image.title="mcp-shark" \
      org.opencontainers.image.description="Security scanner for AI agent tools — proxy + browser dashboard for MCP" \
      org.opencontainers.image.source="https://github.com/mcp-shark/mcp-shark" \
      org.opencontainers.image.url="https://mcpshark.sh" \
      org.opencontainers.image.licenses="SEE LICENSE IN LICENSE" \
      org.opencontainers.image.version="${MCP_SHARK_VERSION}"

# Copy the installed global package tree. Transitive deps are nested inside
# @mcp-shark/mcp-shark/node_modules — Node's ESM resolver walks UP from the
# script's real path, so the CLI shim MUST be a symlink into the package (not
# a copied-file, which would break resolution). COPY dereferences symlinks,
# so we skip copying /usr/local/bin/mcp-shark and recreate the symlink below.
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/@mcp-shark/mcp-shark/bin/mcp-shark.js \
          /usr/local/bin/mcp-shark

# --- Non-root user ---
# uid 65532 matches the distroless "nonroot" uid used by kubernetes-mcp-server
# and is a well-known choice for pod SecurityContext.runAsUser in Kortex.
RUN groupadd -g 65532 mcpshark \
 && useradd -u 65532 -g 65532 -m -d /home/mcpshark -s /usr/sbin/nologin mcpshark \
 && mkdir -p /home/mcpshark/.mcp-shark \
 && chown -R 65532:65532 /home/mcpshark

USER 65532:65532
WORKDIR /home/mcpshark

# HOME + MCP_SHARK_HOME point at the mounted volume so mcps.json, the sqlite
# traffic DB, downloaded rule packs and YARA rules survive container restarts.
# UI_PORT is honoured by the server (see core/configs/environment.js) and must
# match the port that docker-compose / -p publishes.
ENV HOME=/home/mcpshark \
    MCP_SHARK_HOME=/home/mcpshark/.mcp-shark \
    UI_PORT=9853

EXPOSE 9853

# `serve` starts the UI + proxy on UI_PORT bound to 0.0.0.0. `--open` is
# intentionally omitted — containers can't spawn a host browser; open
# http://localhost:9853 from your machine instead.
ENTRYPOINT ["mcp-shark"]
CMD ["serve"]
