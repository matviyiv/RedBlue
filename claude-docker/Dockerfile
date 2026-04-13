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

# Working directory — blue zone will be mounted here
WORKDIR /workspace

# Switch to non-root user
USER claude

# Default entrypoint: claude CLI in headless mode
ENTRYPOINT ["claude"]
CMD ["--help"]
