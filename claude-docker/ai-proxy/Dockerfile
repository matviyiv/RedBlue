# ─────────────────────────────────────────────────────────────────────────────
# Egress allowlist proxy for the interactive Claude Code container.
#
# tinyproxy forwards ONLY to the domains listed in `filter` (Anthropic auth +
# API). Everything else — including every LAN address — is denied. The claude
# container has no other route out, so this is the single, auditable egress
# point for `network_mode`-less interactive sessions.
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:3.20

RUN apk add --no-cache tinyproxy

COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY filter         /etc/tinyproxy/filter

EXPOSE 8888

# tinyproxy drops to the unprivileged `tinyproxy` user itself (see the
# User/Group directives in tinyproxy.conf). -d keeps it in the foreground.
CMD ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
