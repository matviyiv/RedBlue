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
# of the thing driving your browser can arrive on any rebuild. Override with
# BLUE_ZONE_BROWSER_MCP_VERSION.
ARG PLAYWRIGHT_MCP_VERSION=0.0.81

# Browsers live here, both the ones the base image ships and the one installed
# below. Set before the install so it lands in the right place.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# --ignore-scripts: the MCP package needs no install hooks, and refusing to run
# them removes the most common npm supply-chain foothold.
#
# It also skips Playwright's own postinstall browser download, which we then do
# explicitly — and must. @playwright/mcp bundles an exact Playwright version
# (0.0.81 pins 1.64.0-alpha), and Playwright resolves Chromium by build revision,
# not by "whatever Chromium is present". The base image ships the revision for
# ITS Playwright version, so unless the two happen to match, the server starts
# and then dies on "Executable doesn't exist at /ms-playwright/chromium-XXXX/…".
#
# Installing through the MCP package's own playwright-core means the browser is
# by construction the one that package expects, whatever either version is. The
# base image is then what it is actually good at: the OS libraries, fonts and
# the non-root pwuser account that Chromium needs.
RUN npm install -g --ignore-scripts "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" \
    && node "$(npm root -g)/@playwright/mcp/node_modules/playwright-core/cli.js" \
       install chromium \
    && chmod -R a+rX /ms-playwright \
    && npm cache clean --force

# Fail at BUILD time, loudly, if the entrypoint is not what we think it is.
# The package's bin is `playwright-mcp`; an earlier version of this file guessed
# a different name and the only symptom was the container exiting with
# "no such file or directory", which says nothing about the cause. A build that
# cannot start its own entrypoint should never produce an image.
RUN command -v playwright-mcp >/dev/null \
    || { echo "FATAL: @playwright/mcp ${PLAYWRIGHT_MCP_VERSION} does not install a 'playwright-mcp' binary."; \
         echo "Check the package's bin field and update ENTRYPOINT below."; exit 1; }
RUN playwright-mcp --help >/dev/null

# Non-root. The compose service pins this as well (`user: pwuser`) so it holds
# even if this line is ever lost in a base-image bump.
USER pwuser

EXPOSE 8931

# Flags come from the compose overlay, which generates them from
# blue-zone.config.sh (--allowed-origins, --proxy-server, --headless,
# --isolated, …). Nothing policy-relevant is baked in here, so changing the
# allowlist never requires an image rebuild.
ENTRYPOINT ["playwright-mcp"]
CMD ["--help"]
