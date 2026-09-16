# ─────────────────────────────────────────────────────────────────────────────
# Playwright MCP server — the browser, OUTSIDE the Claude sandbox image.
#
# This container holds a real Chromium and speaks MCP over HTTP on the internal
# `browser` network. It deliberately has:
#   • no blue-zone mounts        — it cannot read the code under review
#   • no Anthropic credentials   — CLAUDE_CODE_OAUTH_TOKEN is never passed here
#   • no route to the internet   — except through browser-proxy's allowlist
#   • no writable root fs        — compose mounts a tmpfs and points HOME at it
#
# Why a separate image instead of installing Playwright into the sandbox image:
# a browser is a large, fast-moving attack surface that renders untrusted
# content. Keeping it in its own container means a renderer compromise lands
# somewhere with nothing worth stealing and nowhere to go.
# ─────────────────────────────────────────────────────────────────────────────

# Pin this. The official Playwright image ships the browser binaries matched to
# the Playwright version, plus the `pwuser` (uid 1000) non-root account we run
# as. Override with BLUE_ZONE_BROWSER_IMAGE in blue-zone.config.sh; prefer a
# digest (mcr.microsoft.com/playwright@sha256:...) for a reproducible build.
ARG PLAYWRIGHT_IMAGE=mcr.microsoft.com/playwright:v1.55.0-noble
FROM ${PLAYWRIGHT_IMAGE}

# Pin this too, for the same reason — `latest` means a new, unreviewed version
# of the thing driving your browser can arrive on any rebuild. Set
# BLUE_ZONE_BROWSER_MCP_VERSION to an exact version before real use.
ARG PLAYWRIGHT_MCP_VERSION=latest

# --ignore-scripts: the MCP package needs no install hooks, and refusing to run
# them removes the most common npm supply-chain foothold. The browsers are
# already in the base image, so nothing needs downloading at install time.
RUN npm install -g --ignore-scripts "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" \
    && npm cache clean --force

# Where --output-dir points (traces, screenshots the server writes to disk).
# tmpfs in compose, so nothing survives the session.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# Non-root. The compose service pins this as well (`user: pwuser`) so it holds
# even if this line is ever lost in a base-image bump.
USER pwuser

EXPOSE 8931

# Flags come from the compose overlay, which generates them from
# blue-zone.config.sh (--allowed-origins, --proxy-server, --headless,
# --isolated, …). Nothing policy-relevant is baked in here, so changing the
# allowlist never requires an image rebuild.
ENTRYPOINT ["mcp-server-playwright"]
CMD ["--help"]
