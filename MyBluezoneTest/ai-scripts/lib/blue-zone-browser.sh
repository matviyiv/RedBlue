#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# lib/blue-zone-browser.sh — the opt-in Playwright MCP browser.
#
# The Playwright MCP server runs OUTSIDE the Claude sandbox image, in its own
# container, and is reachable only from the interactive session. This file is
# the whole mechanism:
#
#   blue_zone_browser_enabled   is the browser switched on for this run?
#   blue_zone_browser_check     validate the egress policy — fails CLOSED
#   blue_zone_browser_write     generate the proxy config, filter, .mcp.json
#                               and the docker-compose overlay
#   blue_zone_browser_summary   print what the browser may reach
#
# Topology (each arrow is the ONLY path between those two boxes):
#
#   claude-cli ──[network: browser, internal]──> playwright-mcp
#                                                     │
#                                      [network: browser-egress, internal]
#                                                     v
#                                                browser-proxy ──> allowlist
#
#   • `browser` is internal — claude-cli gains no internet from it. Its only
#     use is speaking MCP to the browser container.
#   • playwright-mcp never mounts the blue zone. A compromised browser (or a
#     compromised page) cannot read the code under review.
#   • browser-proxy is NOT on the `browser` network, so the session cannot use
#     it as a proxy directly — only Chromium, inside playwright-mcp, can.
#   • Chromium is started with --proxy-server pointing at browser-proxy, and
#     the MCP server additionally enforces --allowed-origins. Network layer and
#     app layer, from the same list.
#   • A dev server Claude runs inside claude-cli is the one exception to the
#     proxy: it is reached DIRECTLY across the `browser` network, because
#     browser-proxy is not on that network and could never route to it. That
#     traffic never leaves Docker, so there is nothing for an egress allowlist
#     to allow — the bypass adds no reach the browser did not already have.
#
# Sourced, not executed. Requires blue-zone.config.sh to be sourced first.
# ─────────────────────────────────────────────────────────────────────────────

: "${BOLD:=}" "${GREEN:=}" "${YELLOW:=}" "${RED:=}" "${CYAN:=}" "${RESET:=}"

# Defensive defaults so an older blue-zone.config.sh (deployed before the
# browser existed) still sources cleanly: the browser is simply off.
: "${BLUE_ZONE_BROWSER_ENABLED:=0}"
: "${BLUE_ZONE_BROWSER_ALLOW_HOST_GATEWAY:=0}"
: "${BLUE_ZONE_BROWSER_ALLOW_PRIVATE_IPS:=0}"
: "${BLUE_ZONE_BROWSER_TOOLS:=}"
: "${BLUE_ZONE_BROWSER_IMAGE:=mcr.microsoft.com/playwright:v1.55.0-noble}"
: "${BLUE_ZONE_BROWSER_MCP_VERSION:=latest}"
: "${BLUE_ZONE_BROWSER_MEMORY:=2g}"
: "${BLUE_ZONE_BROWSER_COMPOSE_FILE:=docker-compose.browser.yml}"
: "${BLUE_ZONE_BROWSER_DIR:=${BLUE_ZONE_ROOT:-/tmp/blue-zone/project}/.browser}"
declare -p BLUE_ZONE_BROWSER_ORIGINS >/dev/null 2>&1 || BLUE_ZONE_BROWSER_ORIGINS=()
declare -p BLUE_ZONE_BROWSER_DEV_PORTS >/dev/null 2>&1 || BLUE_ZONE_BROWSER_DEV_PORTS=()
: "${BLUE_ZONE_BROWSER_DEV_HOST:=devserver}"

# The MCP server's listening port on the internal `browser` network. Not
# published to the host — nothing outside Docker can reach it.
BLUE_ZONE_BROWSER_MCP_PORT="${BLUE_ZONE_BROWSER_MCP_PORT:-8931}"

# ─────────────────────────────────────────────────────────────────────────────
# blue_zone_browser_enabled — true when the browser should be wired up.
# ─────────────────────────────────────────────────────────────────────────────
blue_zone_browser_enabled() {
  [ "${BLUE_ZONE_BROWSER_ENABLED:-0}" = "1" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# blue_zone_browser_dev_enabled — true when a dev server inside the sandbox is
# part of this session's browser setup.
# ─────────────────────────────────────────────────────────────────────────────
blue_zone_browser_dev_enabled() {
  [ "${#BLUE_ZONE_BROWSER_DEV_PORTS[@]}" -gt 0 ]
}

# Dev-server origins, one per line, in the same "scheme host port" shape as
# blue_zone_browser_each so both can be consumed the same way.
blue_zone_browser_dev_each() {
  local port
  for port in ${BLUE_ZONE_BROWSER_DEV_PORTS[@]+"${BLUE_ZONE_BROWSER_DEV_PORTS[@]}"}; do
    [ -n "$port" ] || continue
    printf 'http %s %s\n' "$BLUE_ZONE_BROWSER_DEV_HOST" "$port"
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# blue_zone_browser_split <origin> — parse "scheme://host[:port]".
# Prints "scheme host port" on success; non-zero exit on anything malformed.
# Deliberately strict: no path, no query, no credentials, no wildcards. An
# origin we cannot parse exactly is an origin we cannot enforce exactly.
# ─────────────────────────────────────────────────────────────────────────────
blue_zone_browser_split() {
  local o="$1" scheme rest host port
  case "$o" in *://*) ;; *) return 1 ;; esac
  scheme="${o%%://*}"
  rest="${o#*://}"
  [ "$scheme" = "http" ] || [ "$scheme" = "https" ] || return 1
  case "$rest" in ""|*/*|*@*|*\?*|*\#*|*" "*) return 1 ;; esac
  # Wildcards and regex metacharacters would silently widen the allowlist once
  # they reach the proxy's filter file, which is itself a regex. Refuse them.
  case "$rest" in *\**|*\|*|*\(*|*\)*|*\[*|*\$*|*\^*|*\\*|*+*) return 1 ;; esac
  host="${rest%%:*}"
  if [ "$rest" = "$host" ]; then
    [ "$scheme" = "https" ] && port=443 || port=80
  else
    port="${rest#*:}"
  fi
  [ -n "$host" ] || return 1
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || return 1
  printf '%s %s %s' "$scheme" "$host" "$port"
}

# ─────────────────────────────────────────────────────────────────────────────
# blue_zone_browser_is_private <host> — true for anything that resolves into
# your own machine or your LAN. These are the addresses a browser must not be
# pointed at by accident: they are exactly what the container isolation exists
# to keep out of reach.
# ─────────────────────────────────────────────────────────────────────────────
blue_zone_browser_is_private() {
  case "$1" in
    localhost|*.localhost|127.*|::1|0.0.0.0) return 0 ;;
    10.*|192.168.*|169.254.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    *.local|*.internal|*.lan|*.home|*.corp) return 0 ;;
  esac
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# blue_zone_browser_check — validate the configured egress policy.
#
# Fails CLOSED: anything it cannot prove is narrow is a violation, and the
# caller must refuse to start the browser. Prints one line per problem.
# Returns 0 when the policy is safe to apply, 1 otherwise.
# ─────────────────────────────────────────────────────────────────────────────
blue_zone_browser_check() {
  local bad=0 origin parsed scheme host port
  local n="${#BLUE_ZONE_BROWSER_ORIGINS[@]}"

  # Dev-server ports first: an empty external allowlist is perfectly fine — and
  # is the safest setup there is — when the browser's only job is to open what
  # Claude just built inside the sandbox.
  local port
  for port in ${BLUE_ZONE_BROWSER_DEV_PORTS[@]+"${BLUE_ZONE_BROWSER_DEV_PORTS[@]}"}; do
    case "$port" in
      ''|*[!0-9]*)
        echo -e "  ${RED}VIOLATION${RESET} - dev server port '$port' is not a number."
        bad=1
        continue ;;
    esac
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      echo -e "  ${RED}VIOLATION${RESET} - dev server port '$port' is out of range (1-65535)."
      bad=1
    fi
  done

  case "$BLUE_ZONE_BROWSER_DEV_HOST" in
    ''|*[!a-zA-Z0-9-]*)
      echo -e "  ${RED}VIOLATION${RESET} - BLUE_ZONE_BROWSER_DEV_HOST ('$BLUE_ZONE_BROWSER_DEV_HOST') is not a"
      echo    "              usable hostname. It becomes a Docker network alias, so it must"
      echo    "              be letters, digits and hyphens only."
      bad=1 ;;
  esac

  if [ "$n" -eq 0 ] && ! blue_zone_browser_dev_enabled; then
    echo -e "  ${RED}VIOLATION${RESET} - browser is enabled but nothing is reachable."
    echo    "              Set BLUE_ZONE_BROWSER_DEV_PORTS for a dev server Claude runs"
    echo    "              inside the sandbox, and/or list external origins in"
    echo    "              BLUE_ZONE_BROWSER_ORIGINS. Or set BLUE_ZONE_BROWSER_ENABLED=0."
    return 1
  fi

  for origin in "${BLUE_ZONE_BROWSER_ORIGINS[@]}"; do
    [ -n "$origin" ] || continue

    if ! parsed="$(blue_zone_browser_split "$origin")"; then
      echo -e "  ${RED}VIOLATION${RESET} - unusable browser origin: '$origin'"
      echo    "              Expected scheme://host[:port] — http or https, no path,"
      echo    "              no credentials, no wildcards."
      bad=1
      continue
    fi
    # shellcheck disable=SC2086
    set -- $parsed
    scheme="$1"; host="$2"; port="$3"

    if [ "$host" = "host.docker.internal" ] || [ "$host" = "gateway.docker.internal" ]; then
      if [ "${BLUE_ZONE_BROWSER_ALLOW_HOST_GATEWAY:-0}" != "1" ]; then
        echo -e "  ${RED}VIOLATION${RESET} - '$origin' points at your host machine."
        echo    "              That punches a route from the browser container to the host"
        echo    "              (and whatever the host can reach). Set"
        echo    "              BLUE_ZONE_BROWSER_ALLOW_HOST_GATEWAY=1 to accept that,"
        echo    "              deliberately, or drop the origin."
        bad=1
      fi
      continue
    fi

    if blue_zone_browser_is_private "$host"; then
      if [ "${BLUE_ZONE_BROWSER_ALLOW_PRIVATE_IPS:-0}" != "1" ]; then
        echo -e "  ${RED}VIOLATION${RESET} - '$origin' is a private/LAN address."
        echo    "              Pointing the browser at your internal network defeats the"
        echo    "              isolation the sandbox exists for. Set"
        echo    "              BLUE_ZONE_BROWSER_ALLOW_PRIVATE_IPS=1 only if this specific"
        echo    "              host is genuinely in scope."
        bad=1
      else
        echo -e "  ${YELLOW}WARNING${RESET}  - '$origin' is a private/LAN address, allowed by"
        echo    "              BLUE_ZONE_BROWSER_ALLOW_PRIVATE_IPS=1."
      fi
      continue
    fi

    if [ "$scheme" = "http" ]; then
      echo -e "  ${YELLOW}WARNING${RESET}  - '$origin' is plaintext HTTP to a public host;"
      echo    "              prefer https:// where the site supports it."
    fi
    : "$port"
  done

  return $bad
}

# ─────────────────────────────────────────────────────────────────────────────
# blue_zone_browser_needs_host_gateway — true when at least one allowed origin
# is on the host, so the proxy (and ONLY the proxy) needs a host route.
# ─────────────────────────────────────────────────────────────────────────────
blue_zone_browser_needs_host_gateway() {
  local origin
  for origin in ${BLUE_ZONE_BROWSER_ORIGINS[@]+"${BLUE_ZONE_BROWSER_ORIGINS[@]}"}; do
    case "$origin" in
      *//host.docker.internal|*//host.docker.internal:*) return 0 ;;
      *//gateway.docker.internal|*//gateway.docker.internal:*) return 0 ;;
    esac
  done
  return 1
}

# Normalized origin list, one "scheme host port" triple per line. Skips
# anything unparseable — blue_zone_browser_check has already refused those.
blue_zone_browser_each() {
  local origin parsed
  for origin in ${BLUE_ZONE_BROWSER_ORIGINS[@]+"${BLUE_ZONE_BROWSER_ORIGINS[@]}"}; do
    [ -n "$origin" ] || continue
    parsed="$(blue_zone_browser_split "$origin")" || continue
    printf '%s\n' "$parsed"
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# blue_zone_browser_write <project-root> — generate everything the browser
# needs, from blue-zone.config.sh alone:
#
#   $BLUE_ZONE_BROWSER_DIR/tinyproxy.conf   browser proxy, default-deny
#   $BLUE_ZONE_BROWSER_DIR/filter           the host allowlist (one ERE/line)
#   $BLUE_ZONE_BROWSER_DIR/mcp.json         mounted read-only at /workspace/.mcp.json
#   <project-root>/$BLUE_ZONE_BROWSER_COMPOSE_FILE   the compose overlay
#
# Everything here is regenerated on every run; none of it is hand-edited, so
# the config file stays the single source of truth for the policy.
# ─────────────────────────────────────────────────────────────────────────────
blue_zone_browser_write() {
  local project_root="$1"
  local dir="$BLUE_ZONE_BROWSER_DIR"
  local scheme host port esc
  local connect_ports="" origins_arg="" dev_bypass_arg="" dev_alias_block=""

  # The dev server is inside claude-cli, on the internal `browser` network that
  # only the browser container shares. browser-proxy is deliberately NOT on that
  # network, so proxying this traffic could never work — Chromium has to reach
  # it directly. This bypass therefore grants no reach the browser did not
  # already have; it just stops the proxy swallowing a request it cannot route.
  if blue_zone_browser_dev_enabled; then
    dev_bypass_arg="
      - --proxy-bypass=$BLUE_ZONE_BROWSER_DEV_HOST"
    # `docker compose run` does not apply a service's network aliases unless it
    # is asked to (--use-aliases, added by start-cli.sh), so this alias plus
    # that flag are what make the name resolve at all.
    dev_alias_block="
    networks:
      browser:
        aliases:
          - $BLUE_ZONE_BROWSER_DEV_HOST"
  fi

  mkdir -p "$dir"

  # ── filter: exact-host allowlist ───────────────────────────────────────────
  # Anchored to the WHOLE host on purpose (^host$, not (^|\.)host$): a browser
  # allowlist that silently includes every subdomain is a much bigger hole than
  # the one you meant to open. Add subdomains explicitly if you need them.
  {
    echo "# AUTO-GENERATED from BLUE_ZONE_BROWSER_ORIGINS in blue-zone.config.sh."
    echo "# Regenerated every run — do NOT edit by hand; edit the config instead."
    echo "#"
    echo "# Exact-host allowlist for the browser's egress proxy. FilterDefaultDeny"
    echo "# refuses every destination that does not match a line here."
    while read -r scheme host port; do
      [ -n "$host" ] || continue
      esc="$(printf '%s' "$host" | sed 's/\./\\./g')"
      printf '^%s$\n' "$esc"
    done < <(blue_zone_browser_each | sort -u -k2,2)
  } > "$dir/filter"

  # ── ConnectPort lines: which ports may be CONNECT-tunnelled (https) ───────
  while read -r scheme host port; do
    [ "$scheme" = "https" ] || continue
    case " $connect_ports " in *" $port "*) continue ;; esac
    connect_ports="$connect_ports $port"
  done < <(blue_zone_browser_each)

  {
    echo "# AUTO-GENERATED from blue-zone.config.sh — regenerated every run."
    echo "#"
    echo "# Egress allowlist proxy for the Playwright browser ONLY. It is a second,"
    echo "# separate instance from the session's own egress-proxy: the browser's"
    echo "# allowlist and Claude's allowlist are deliberately not the same list."
    echo ""
    echo "User  tinyproxy"
    echo "Group tinyproxy"
    echo ""
    echo "Port   8888"
    echo "Listen 0.0.0.0"
    echo "Timeout 600"
    echo ""
    echo "LogLevel Info"
    echo "MaxClients 20"
    echo ""
    echo "# Default-deny. Only hosts matching /etc/tinyproxy/filter are reachable;"
    echo "# every other destination, including every LAN address, is refused before"
    echo "# a connection is opened."
    echo "FilterDefaultDeny Yes"
    echo "Filter \"/etc/tinyproxy/filter\""
    echo "FilterType ere"
    echo "FilterCaseSensitive Off"
    echo ""
    echo "# CONNECT tunnels are limited to the ports actually configured as https"
    echo "# origins. No line here at all means no CONNECT is possible."
    for port in $connect_ports; do
      echo "ConnectPort $port"
    done
    echo ""
    echo "# Only the playwright-mcp container is on the network this listens on."
    echo "Allow 0.0.0.0/0"
  } > "$dir/tinyproxy.conf"

  # ── mcp.json — mounted read-only into the session ─────────────────────────
  # Passed with --strict-mcp-config so this is the ONLY MCP server the session
  # can load: a server left behind in the persisted ~/.claude.json from an
  # earlier run cannot quietly come along.
  cat > "$dir/mcp.json" <<JSON
{
  "mcpServers": {
    "playwright": {
      "type": "http",
      "url": "http://playwright-mcp:${BLUE_ZONE_BROWSER_MCP_PORT}/mcp"
    }
  }
}
JSON

  # ── --allowed-origins for the MCP server (app-layer enforcement) ──────────
  # Semicolon-separated, the format @playwright/mcp expects. This duplicates
  # the proxy allowlist on purpose: the proxy is the control that holds if the
  # MCP server is ever misconfigured, and this is the control that holds if a
  # page tries a redirect chain the proxy would technically permit.
  while read -r scheme host port; do
    [ -n "$host" ] || continue
    [ -n "$origins_arg" ] && origins_arg="$origins_arg;"
    origins_arg="$origins_arg$scheme://$host:$port"
  done < <(blue_zone_browser_each; blue_zone_browser_dev_each)

  # ── compose overlay ───────────────────────────────────────────────────────
  {
    cat <<'HEAD'
# ─────────────────────────────────────────────────────────────────────────────
# AUTO-GENERATED by ai-scripts/lib/blue-zone-browser.sh from blue-zone.config.sh.
# Regenerated on every interactive run — do NOT edit by hand.
#
# Adds the two browser containers. Neither is attached to the `egress` network
# the session uses for Anthropic, and neither mounts any part of the blue zone.
# ─────────────────────────────────────────────────────────────────────────────
services:
  # The session gets the MCP config, read-only, and — when a dev server is
  # configured — a stable name on the `browser` network for the browser to
  # reach it by. Nothing else new.
  claude-cli:
    volumes:
HEAD
    echo "      - $dir/mcp.json:/workspace/.mcp.json:ro"
    [ -n "$dev_alias_block" ] && printf '%s\n' "$dev_alias_block"
    cat <<HEAD

  # Playwright MCP — OUTSIDE the Claude sandbox image, in its own container.
  # It holds no credentials, mounts no source, and can reach nothing except the
  # browser proxy. Claude speaks MCP to it over the internal \`browser\` network.
  playwright-mcp:
    build:
      context: ./ai-playwright
      dockerfile: Dockerfile
      args:
        PLAYWRIGHT_IMAGE: "$BLUE_ZONE_BROWSER_IMAGE"
        PLAYWRIGHT_MCP_VERSION: "$BLUE_ZONE_BROWSER_MCP_VERSION"
    image: claude-playwright-mcp:latest
    platform: \${CLAUDE_PLATFORM:-}
    init: true
    user: pwuser
    command:
      - --headless
      - --isolated
      - --no-sandbox
      - --browser=chromium
      - --host=0.0.0.0
      - --port=$BLUE_ZONE_BROWSER_MCP_PORT
      - --proxy-server=http://browser-proxy:8888$dev_bypass_arg
      - --allowed-origins=$origins_arg
      - --output-dir=/tmp/playwright-output
    read_only: true
    # Nothing the browser does survives the session: the root filesystem is
    # read-only and the only writable space is tmpfs. HOME points into it
    # rather than at /home/pwuser, so this does not depend on which uid the
    # base image happens to give pwuser.
    environment:
      HOME: /tmp
    tmpfs:
      - /tmp:mode=1777
    shm_size: 512m
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    networks:
      - browser
      - browser-egress
    deploy:
      resources:
        limits:
          memory: $BLUE_ZONE_BROWSER_MEMORY
          # A fork bomb in the browser container should not take the host down
          # with it. Chromium spawns a process per tab/renderer, so this is
          # generous but finite.
          pids: 512

  # The browser's own egress allowlist. Reuses the session proxy's image but
  # NOT its config: a separate instance with a separate, generated allowlist.
  # It is deliberately absent from the \`browser\` network, so the session cannot
  # use it as a proxy — only Chromium can.
  browser-proxy:
    build:
      context: ./ai-proxy
      dockerfile: Dockerfile
    image: claude-egress-proxy:latest
    volumes:
      - $dir/tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf:ro
      - $dir/filter:/etc/tinyproxy/filter:ro
    cap_drop:
      - ALL
    # tinyproxy binds its port as root and then drops to the unprivileged
    # \`tinyproxy\` user itself (the User/Group directives in the generated
    # config). setuid/setgid are the only capabilities that needs — without
    # them it cannot drop privileges and refuses to start.
    cap_add:
      - SETUID
      - SETGID
    security_opt:
      - no-new-privileges:true
    networks:
      - browser-egress
      - browser-upstream
HEAD
    if blue_zone_browser_needs_host_gateway; then
      cat <<'HOSTGW'
    # A configured origin points at the host, so the PROXY — and only the proxy
    # — gets a route to it. The browser container still has no host route of its
    # own; it must go through the allowlist to get there.
    extra_hosts:
      - "host.docker.internal:host-gateway"
HOSTGW
    fi
    cat <<'TAIL'
    deploy:
      resources:
        limits:
          memory: 64m
          pids: 64

networks:
  # playwright-mcp <-> browser-proxy. Internal: the browser has no route out
  # except through the proxy.
  browser-egress:
    internal: true
  # Only browser-proxy is attached here — the single, auditable egress point
  # for anything the browser does.
  browser-upstream:
    driver: bridge
TAIL
  } > "$project_root/$BLUE_ZONE_BROWSER_COMPOSE_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# blue_zone_browser_summary — show the operator exactly what they just allowed.
# ─────────────────────────────────────────────────────────────────────────────
blue_zone_browser_summary() {
  local scheme host port shown=0
  echo -e "${BOLD}Browser (Playwright MCP): ${GREEN}enabled${RESET}"
  echo -e "  Runs in its own container — no blue-zone mounts, no credentials."
  echo -e "  ${BOLD}Reachable origins (everything else is denied):${RESET}"
  while read -r scheme host port; do
    [ -n "$host" ] || continue
    echo -e "    ${GREEN}•${RESET} $scheme://$host:$port"
    shown=$((shown + 1))
  done < <(blue_zone_browser_each)
  [ "$shown" -gt 0 ] || echo -e "    ${YELLOW}(none — external egress fully denied)${RESET}"
  if blue_zone_browser_dev_enabled; then
    echo -e "  ${BOLD}Dev server inside the sandbox${RESET} (direct, never leaves Docker):"
    while read -r scheme host port; do
      [ -n "$host" ] || continue
      echo -e "    ${GREEN}•${RESET} $scheme://$host:$port"
    done < <(blue_zone_browser_dev_each)
    echo -e "    Claude must bind it to ${BOLD}0.0.0.0${RESET} and allow the host"
    echo -e "    name ${BOLD}$BLUE_ZONE_BROWSER_DEV_HOST${RESET} (webpack: ${BOLD}allowedHosts${RESET})."
  fi
  if [ -n "$BLUE_ZONE_BROWSER_TOOLS" ]; then
    echo -e "  Pre-approved tools: ${YELLOW}$BLUE_ZONE_BROWSER_TOOLS${RESET}"
  else
    echo -e "  Every browser action asks you first (no pre-approved tools)."
  fi
}
