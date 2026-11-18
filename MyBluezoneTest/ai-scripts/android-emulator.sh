#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# android-emulator.sh — run the blue-zone Android emulator ON YOUR MAC.
#
# Docker Desktop on macOS has no KVM, so the emulator cannot run inside the
# sandbox. It runs natively here (Apple Silicon: arm64 system image, hardware
# accelerated by Hypervisor.framework) and the session reaches ONLY its adb port,
# through the adb-relay container. See docs/android.md.
#
# Usage:
#   ./ai-scripts/android-emulator.sh create    install the system image, create the AVD
#   ./ai-scripts/android-emulator.sh start     boot it (airplane mode on) and wait
#           [--online]                         keep the emulator's network on
#   ./ai-scripts/android-emulator.sh stop      shut it down
#   ./ai-scripts/android-emulator.sh status
#
# Needs the Android SDK (Android Studio installs it at ~/Library/Android/sdk)
# with the emulator, platform-tools and cmdline-tools packages.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../blue-zone.config.sh
source "$SCRIPT_DIR/../blue-zone.config.sh"
# shellcheck source=lib/blue-zone-android.sh
source "$SCRIPT_DIR/lib/blue-zone-android.sh"

: "${BLUE_ZONE_ANDROID_AVD:=bluezone}"
: "${BLUE_ZONE_ANDROID_SYSTEM_IMAGE:=system-images;android-35;google_apis;arm64-v8a}"
: "${BLUE_ZONE_ANDROID_DEVICE:=pixel_7}"

CONSOLE_PORT=$((BLUE_ZONE_ANDROID_ADB_PORT - 1))
SERIAL="emulator-$CONSOLE_PORT"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
EMULATOR="$SDK/emulator/emulator"
ADB="$SDK/platform-tools/adb"
SDKMANAGER="$SDK/cmdline-tools/latest/bin/sdkmanager"
AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager"

say()  { printf '\033[0;36m[emulator]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[emulator]\033[0m %s\n' "$*" >&2; exit 1; }

need() { [ -x "$1" ] || die "$1 not found — install it with Android Studio's SDK Manager ($2)."; }

cmd_create() {
  need "$SDKMANAGER" "Android SDK Command-line Tools"
  need "$AVDMANAGER" "Android SDK Command-line Tools"
  if "$EMULATOR" -list-avds 2>/dev/null | grep -qx "$BLUE_ZONE_ANDROID_AVD"; then
    say "AVD '$BLUE_ZONE_ANDROID_AVD' already exists."
    return
  fi
  say "installing $BLUE_ZONE_ANDROID_SYSTEM_IMAGE ..."
  yes | "$SDKMANAGER" --install emulator platform-tools "$BLUE_ZONE_ANDROID_SYSTEM_IMAGE" >/dev/null
  say "creating AVD '$BLUE_ZONE_ANDROID_AVD' ($BLUE_ZONE_ANDROID_DEVICE) ..."
  echo no | "$AVDMANAGER" create avd -n "$BLUE_ZONE_ANDROID_AVD" \
    -k "$BLUE_ZONE_ANDROID_SYSTEM_IMAGE" -d "$BLUE_ZONE_ANDROID_DEVICE" >/dev/null
  say "done. A dedicated AVD: do not sign in to any Google account on it."
}

cmd_start() {
  local online=0
  [ "${1:-}" = "--online" ] && online=1
  need "$EMULATOR" "Android Emulator"
  need "$ADB" "Android SDK Platform-Tools"
  "$EMULATOR" -list-avds | grep -qx "$BLUE_ZONE_ANDROID_AVD" \
    || die "no AVD '$BLUE_ZONE_ANDROID_AVD' — run: $0 create"

  if "$ADB" devices | grep -q "^$SERIAL"; then
    say "$SERIAL already running."
  else
    say "booting '$BLUE_ZONE_ANDROID_AVD' on console $CONSOLE_PORT / adb $BLUE_ZONE_ANDROID_ADB_PORT ..."
    # -no-snapshot-save: every session starts from the same clean state, so
    # nothing a previous session left on the device survives a restart.
    nohup "$EMULATOR" -avd "$BLUE_ZONE_ANDROID_AVD" -port "$CONSOLE_PORT" \
      -no-snapshot-save -no-boot-anim >/tmp/bluezone-emulator.log 2>&1 &
  fi

  "$ADB" -s "$SERIAL" wait-for-device
  until [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
    sleep 2
  done

  if [ "$online" -eq 0 ]; then
    # A guard against accidents, NOT a boundary: the session has adb shell and
    # can turn this back on. Debug builds do not need it — Metro is reached
    # through adb reverse, which does not use the device's network.
    "$ADB" -s "$SERIAL" shell cmd connectivity airplane-mode enable >/dev/null 2>&1 || true
    "$ADB" -s "$SERIAL" shell svc wifi disable >/dev/null 2>&1 || true
    "$ADB" -s "$SERIAL" shell svc data disable >/dev/null 2>&1 || true
    say "airplane mode ON (pass --online if the app must reach the network)."
  else
    say "network left ON — the session can use the emulator to reach the internet."
  fi

  say "ready: $SERIAL. In the session: bz-android connect"
  say "First connect only: accept the 'Allow USB debugging?' prompt on the emulator"
  say "screen (tick 'Always allow') — the sandbox has its own adb key."
}

cmd_stop() {
  need "$ADB" "Android SDK Platform-Tools"
  "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 && say "stopped $SERIAL." || say "$SERIAL is not running."
}

cmd_status() {
  say "SDK:  $SDK"
  say "AVD:  $BLUE_ZONE_ANDROID_AVD ($BLUE_ZONE_ANDROID_SYSTEM_IMAGE)"
  say "port: console $CONSOLE_PORT (not forwarded), adb $BLUE_ZONE_ANDROID_ADB_PORT (forwarded by adb-relay)"
  [ -x "$ADB" ] && "$ADB" devices -l
}

case "${1:-}" in
  create) cmd_create ;;
  start)  shift; cmd_start "$@" ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
