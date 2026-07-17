# Build for the host's native architecture by default. node:22-alpine is
# multi-arch, so this works on both arm64 (Apple Silicon) and amd64 without
# emulation. To force a specific arch, pass `docker build --platform <arch>`
# (CI builds linux/amd64 that way); via compose, set CLAUDE_PLATFORM.
FROM node:22-alpine

# Install dependencies
RUN apk add --no-cache \
    bash \
    git \
    jq \
    curl

# Install Claude Code CLI globally
RUN npm install -g @anthropic-ai/claude-code

# Create non-root user for security
RUN addgroup -S claude && adduser -S claude -G claude

# The claude-home volume seeds from the image's /home/claude on first use;
# make sure the config dir exists and everything is owned by claude so
# persisted state (/login credentials, ~/.claude.json) is writable
RUN mkdir -p /home/claude/.claude && chown -R claude:claude /home/claude

# Working directory — blue zone will be mounted here.
# Owned by claude so files can be created at the workspace root too.
WORKDIR /workspace
RUN chown claude:claude /workspace

# Switch to non-root user
USER claude

# Default entrypoint: claude CLI in headless mode
ENTRYPOINT ["claude"]
CMD ["--help"]
