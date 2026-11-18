#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# lib/blue-zone-android.sh — opt-in Android build + emulator for the
# INTERACTIVE session (start-cli.sh). Off unless BLUE_ZONE_ANDROID_ENABLED=1.
#
#   blue_zone_android_enabled   is Android switched on for this run?
#   blue_zone_android_check     validate the settings — fails CLOSED
#   blue_zone_android_write     generate the egress filter + compose overlay
#   blue_zone_android_summary   print what the session can now reach
#   blue_zone_android_prompt_note  one paragraph appended to the system prompt
#
# Topology (each arrow is the ONLY path between those boxes):
#
#   claude-cli (Android image, linux/amd64)
#     │  ├─[egress, internal]──> egress-proxy ──> Anthropic, npm, GitHub
#     │  │                                         + BLUE_ZONE_ANDROID_EGRESS_HOSTS
#     │  └─[android, internal]─> adb-relay ──> host.docker.internal:<adb port>
#     │                                         (the emulator on your Mac)
#     └─ Metro runs here; `adb reverse` brings the device's :8081 back to it.
#
#   • The emulator cannot run in Docker on macOS (no KVM), so it runs natively
#     on the Mac (ai-scripts/android-emulator.sh) and only its adb port is
#     forwarded. The console port is not.
#   • adb-relay forwards to ONE fixed host:port. The session cannot retarget it.
#   • Gradle/Maven/SDK hosts are added to the session's egress allowlist only
#     while Android is on — ai-proxy/filter itself is never edited.
#
# Residual risk you accept by turning this on: the emulator has the Mac's
# network. `adb shell` gives the session a shell on the emulator, so anything it
# can push there could be sent onward from there. android-emulator.sh puts the
# emulator in airplane mode by default, but the session can undo that — it is a
# guard against accidents, not a boundary. Use a dedicated AVD with no accounts
# signed in. See docs/android.md.
#
# Sourced, not executed. Requires blue-zone.config.sh to be sourced first.
# ─────────────────────────────────────────────────────────────────────────────

: "${BOLD:=}" "${GREEN:=}" "${YELLOW:=}" "${RED:=}" "${CYAN:=}" "${RESET:=}"

# Defensive defaults so an older blue-zone.config.sh still sources cleanly.
: "${BLUE_ZONE_ANDROID_ENABLED:=0}"
: "${BLUE_ZONE_ANDROID_ADB_PORT:=5555}"
: "${BLUE_ZONE_ANDROID_ABIS:=arm64-v8a}"
: "${BLUE_ZONE_ANDROID_MEMORY:=10g}"
: "${BLUE_ZONE_ANDROID_GRADLE_HEAP:=4g}"
: "${BLUE_ZONE_ANDROID_COMPOSE_FILE:=docker-compose.android.yml}"
: "${BLUE_ZONE_ANDROID_DIR:=${BLUE_ZONE_ROOT:-/tmp/blue-zone/project}/.android-sandbox}"
declare -p BLUE_ZONE_ANDROID_EGRESS_HOSTS >/dev/null 2>&1 || BLUE_ZONE_ANDROID_EGRESS_HOSTS=(
  dl.google.com
  maven.google.com
  repo.maven.apache.org
  services.gradle.org
  downloads.gradle.org
  plugins.gradle.org
  plugins-artifacts.gradle.org
  repo.reactnative.dev
  oss.sonatype.org
)

blue_zone_android_enabled() {
  [ "${BLUE_ZONE_ANDROID_ENABLED:-0}" = "1" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# blue_zone_android_check — 0 when the settings are safe to apply, 1 otherwise.
# ─────────────────────────────────────────────────────────────────────────────
blue_zone_android_check() {
  local bad=0 h abi

  case "$BLUE_ZONE_ANDROID_ADB_PORT" in
    ''|*[!0-9]*) echo -e "  ${RED}VIOLATION${RESET} - BLUE_ZONE_ANDROID_ADB_PORT '$BLUE_ZONE_ANDROID_ADB_PORT' is not a number."; bad=1 ;;
    *) if [ "$BLUE_ZONE_ANDROID_ADB_PORT" -lt 1024 ] || [ "$BLUE_ZONE_ANDROID_ADB_PORT" -gt 65535 ]; then
         echo -e "  ${RED}VIOLATION${RESET} - BLUE_ZONE_ANDROID_ADB_PORT must be 1024-65535 (emulator adb ports are 5555, 5557, ...)."
         bad=1
       elif [ $((BLUE_ZONE_ANDROID_ADB_PORT % 2)) -eq 0 ]; then
         # Even ports are emulator CONSOLES (5554, 5556, ...). The console can
         # reconfigure the emulator — including its networking — so refusing it
         # here is what keeps the relay an adb-only path.
         echo -e "  ${RED}VIOLATION${RESET} - BLUE_ZONE_ANDROID_ADB_PORT=$BLUE_ZONE_ANDROID_ADB_PORT is even: that is an emulator"
         echo    "              CONSOLE port, not its adb port. Use the console port + 1 (e.g. 5555)."
         bad=1
       fi ;;
  esac

  for abi in ${BLUE_ZONE_ANDROID_ABIS//,/ }; do
    case "$abi" in
      arm64-v8a|armeabi-v7a|x86|x86_64) ;;
      *) echo -e "  ${RED}VIOLATION${RESET} - BLUE_ZONE_ANDROID_ABIS: unknown ABI '$abi'."; bad=1 ;;
    esac
  done

  case "$BLUE_ZONE_ANDROID_MEMORY" in
    *[0-9]g|*[0-9]m) ;;
    *) echo -e "  ${RED}VIOLATION${RESET} - BLUE_ZONE_ANDROID_MEMORY '$BLUE_ZONE_ANDROID_MEMORY' must look like 10g or 8192m."; bad=1 ;;
  esac
  case "$BLUE_ZONE_ANDROID_GRADLE_HEAP" in
    *[0-9]g|*[0-9]m) ;;
    *) echo -e "  ${RED}VIOLATION${RESET} - BLUE_ZONE_ANDROID_GRADLE_HEAP '$BLUE_ZONE_ANDROID_GRADLE_HEAP' must look like 4g or 4096m."; bad=1 ;;
  esac

  # Egress hosts become exact-match lines in the proxy's regex filter. Anything
  # that is not a plain hostname could widen it, so refuse it outright.
  for h in ${BLUE_ZONE_ANDROID_EGRESS_HOSTS[@]+"${BLUE_ZONE_ANDROID_EGRESS_HOSTS[@]}"}; do
    case "$h" in
      ''|*[!A-Za-z0-9.-]*|.*|*.|*..*)
        echo -e "  ${RED}VIOLATION${RESET} - BLUE_ZONE_ANDROID_EGRESS_HOSTS: '$h' is not a plain hostname"
        echo    "              (no wildcards, schemes, ports or regex)."
        bad=1; continue ;;
    esac
    case "$h" in
      localhost|*.localhost|*.local|*.internal|*.lan|*.home|*.corp|host.docker.internal|[0-9]*.[0-9]*.[0-9]*.[0-9]*)
        echo -e "  ${RED}VIOLATION${RESET} - BLUE_ZONE_ANDROID_EGRESS_HOSTS: '$h' points at your machine or LAN."
        bad=1 ;;
    esac
  done

  return "$bad"
}

# ─────────────────────────────────────────────────────────────────────────────
# blue_zone_android_write <project_root> — generate the session filter (the
# base ai-proxy/filter + the Android hosts) and the compose overlay.
# ─────────────────────────────────────────────────────────────────────────────
blue_zone_android_write() {
  local project_root="$1"
  local dir="$BLUE_ZONE_ANDROID_DIR" h esc
  mkdir -p "$dir"

  {
    echo "# AUTO-GENERATED by lib/blue-zone-android.sh — regenerated every run."
    echo "# ai-proxy/filter + BLUE_ZONE_ANDROID_EGRESS_HOSTS. Edit those, not this."
    echo ""
    cat "$project_root/ai-proxy/filter"
    echo ""
    echo "# ── Android build (BLUE_ZONE_ANDROID_ENABLED=1) — exact hosts only ──"
    for h in ${BLUE_ZONE_ANDROID_EGRESS_HOSTS[@]+"${BLUE_ZONE_ANDROID_EGRESS_HOSTS[@]}"}; do
      esc="$(printf '%s' "$h" | sed 's/\./\\./g')"
      printf '^%s$\n' "$esc"
    done
  } > "$dir/filter"

  # Gradle ignores HTTP(S)_PROXY, so it gets the proxy as systemProp.* in
  # $GRADLE_USER_HOME/gradle.properties, which the wrapper, the client and the
  # daemon all read (and which wins over the project's own gradle.properties).
  # NOT JAVA_TOOL_OPTIONS: every JVM then prints "Picked up JAVA_TOOL_OPTIONS"
  # on stderr, and the Android Gradle plugin reads that line from the prefab
  # tool as a failure — the React Native native build dies with
  # "[CXX1210] No compatible library found".
  cat > "$dir/gradle.properties" <<PROPS
# AUTO-GENERATED by lib/blue-zone-android.sh — regenerated every run.
systemProp.https.proxyHost=egress-proxy
systemProp.https.proxyPort=8888
systemProp.http.proxyHost=egress-proxy
systemProp.http.proxyPort=8888
systemProp.http.nonProxyHosts=localhost|127.0.0.1|adb-relay
org.gradle.jvmargs=-Xmx$BLUE_ZONE_ANDROID_GRADLE_HEAP -XX:MaxMetaspaceSize=512m -Dfile.encoding=UTF-8
PROPS

  cat > "$project_root/$BLUE_ZONE_ANDROID_COMPOSE_FILE" <<YAML
# AUTO-GENERATED by ai-scripts/lib/blue-zone-android.sh from blue-zone.config.sh.
# Regenerated every run while BLUE_ZONE_ANDROID_ENABLED=1 — do NOT edit by hand.
# See docs/android.md.
services:
  claude-cli:
    build:
      context: .
      dockerfile: Dockerfile.ai-sandbox-android
    image: claude-code-android:latest
    # Android build tools exist for linux-x86_64 only. On Apple Silicon this
    # runs under Docker Desktop's Rosetta emulation.
    platform: linux/amd64
    environment:
      - BLUE_ZONE_ADB_TARGET=adb-relay:5555
      - ORG_GRADLE_PROJECT_reactNativeArchitectures=$BLUE_ZONE_ANDROID_ABIS
    volumes:
      - gradle-cache:/opt/gradle-home
      # Proxy + heap for every Gradle JVM; read-only so the session cannot
      # point Gradle somewhere else.
      - $dir/gradle.properties:/opt/gradle-home/gradle.properties:ro
    networks:
      - android
    depends_on:
      - adb-relay
    deploy:
      resources:
        limits:
          memory: $BLUE_ZONE_ANDROID_MEMORY

  egress-proxy:
    volumes:
      # Session allowlist WITH the Android hosts, mounted over the base filter.
      - $dir/filter:/etc/tinyproxy/filter:ro

  adb-relay:
    build:
      context: ./ai-adb-relay
      dockerfile: Dockerfile
    image: claude-adb-relay:latest
    environment:
      - RELAY_TARGET=host.docker.internal:$BLUE_ZONE_ANDROID_ADB_PORT
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - android
      - upstream
    deploy:
      resources:
        limits:
          memory: 32m

networks:
  # claude-cli <-> adb-relay only. No gateway.
  android:
    internal: true

volumes:
  # Gradle wrapper distributions + dependency cache, so builds after the first
  # are incremental. Clear with: docker volume rm <project>_gradle-cache
  gradle-cache:
YAML
}

blue_zone_android_summary() {
  local h
  echo -e "${BOLD}Android${RESET} (BLUE_ZONE_ANDROID_ENABLED=1):"
  echo -e "  ${CYAN}image${RESET}     claude-code-android:latest (linux/amd64 — Rosetta on Apple Silicon)"
  echo -e "  ${CYAN}emulator${RESET}  host.docker.internal:$BLUE_ZONE_ANDROID_ADB_PORT via adb-relay (adb only, no console)"
  echo -e "  ${CYAN}ABIs${RESET}      $BLUE_ZONE_ANDROID_ABIS     ${CYAN}memory${RESET} $BLUE_ZONE_ANDROID_MEMORY     ${CYAN}Gradle heap${RESET} $BLUE_ZONE_ANDROID_GRADLE_HEAP"
  echo -e "  ${CYAN}egress +${RESET}"
  for h in ${BLUE_ZONE_ANDROID_EGRESS_HOSTS[@]+"${BLUE_ZONE_ANDROID_EGRESS_HOSTS[@]}"}; do
    echo -e "            $h"
  done
  echo -e "  ${YELLOW}note${RESET}      the emulator has your Mac's network; adb shell can reach it."
  echo -e "            Start it with ./ai-scripts/android-emulator.sh start (airplane mode on)."
}

blue_zone_android_prompt_note() {
  cat <<NOTE
Android is enabled in this sandbox. The JDK, Android SDK and NDK are installed; the emulator runs on the user's machine and is reachable ONLY through adb at $BLUE_ZONE_ANDROID_ADB_PORT on the relay (adb target adb-relay:5555). Use the bz-android helper: 'bz-android connect' (adb + reverse Metro port), 'bz-android build' (debug APK), 'bz-android run' (Metro + install + launch), 'bz-android screenshot /tmp/s.png' (then read the PNG to see the screen), 'bz-android logs'. Builds are limited to ABIs $BLUE_ZONE_ANDROID_ABIS. Never try to reach the emulator console or the host any other way.
NOTE
}
