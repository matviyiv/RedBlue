# ─────────────────────────────────────────────────────────────────────────────
# adb relay — the ONE path from the sandbox to the Android emulator on your Mac.
#
# claude-cli sits on internal networks with no gateway, so it cannot reach the
# host on its own. This container is dual-homed (the internal `android` network
# and the `upstream` bridge) and forwards exactly one TCP port:
#
#     adb-relay:5555  ──>  host.docker.internal:$BLUE_ZONE_ANDROID_ADB_PORT
#
# The target is fixed when the container starts; nothing the session sends can
# change where it connects. The emulator's console port (5554), which can
# reconfigure the emulator and its networking, is deliberately NOT forwarded.
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:3.20

RUN apk add --no-cache socat \
 && adduser -S -D -H relay

USER relay

# Overridden by the generated compose overlay with the configured host port.
ENV RELAY_TARGET=host.docker.internal:5555
EXPOSE 5555

# exec so socat is PID 1 and receives SIGTERM on `docker compose rm -sf`.
ENTRYPOINT ["sh", "-c", "exec socat -d TCP-LISTEN:5555,fork,reuseaddr TCP:${RELAY_TARGET}"]
