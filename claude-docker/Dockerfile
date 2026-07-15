FROM --platform=linux/amd64 node:22-alpine

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

# Config dir must exist and be owned by claude BEFORE the claude-config
# volume is first mounted, so persisted /login credentials are writable
RUN mkdir -p /home/claude/.claude && chown -R claude:claude /home/claude/.claude

# Working directory — blue zone will be mounted here
WORKDIR /workspace

# Switch to non-root user
USER claude

# Default entrypoint: claude CLI in headless mode
ENTRYPOINT ["claude"]
CMD ["--help"]
