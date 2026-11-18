# Android build & emulator (interactive sessions)

Optional and **off by default**. With `BLUE_ZONE_ANDROID_ENABLED=1`, the
interactive session (`./ai-scripts/start-cli.sh`) can build a React Native app's
Android debug APK, install it on an emulator, launch it, read its logs and take
screenshots. The headless / CI service (`run-headless.sh`) is not affected: it
keeps `network_mode: none` and the plain image.

## Why the emulator is on your Mac, not in the container

An Android emulator needs hardware virtualization. Docker Desktop on macOS runs
containers in a Linux VM that exposes no KVM, so an emulator inside a container
either refuses to start or is unusably slow. On Apple Silicon there is a second
problem: the Android SDK's build tools, NDK and CMake are published for
`linux-x86_64` only.

So the work is split:

| Where | What | Why |
|-------|------|-----|
| Container `claude-cli` (`Dockerfile.ai-sandbox-android`, **linux/amd64** under Rosetta) | JDK 17, Android SDK 35, build-tools 35.0.0, NDK 26.1, CMake 3.22, adb, Metro | The build needs only CPU, and the blue zone stays inside the sandbox |
| Your Mac | The emulator (arm64 system image, Hypervisor.framework) | Native speed; it's the only place it can run |
| Container `adb-relay` | `socat` forwarding **one** TCP port to `host.docker.internal:<adb port>` | `claude-cli` has no route to the host; this is the single, fixed path |

```
claude-cli ──[android, internal]──> adb-relay ──> host.docker.internal:5555 ──> emulator adbd
    │   ▲
    │   └── adb reverse tcp:8081 — the app's Metro requests come back to the container
    └──[egress, internal]──> egress-proxy ──> base allowlist + Android hosts (this run only)
```

## Prerequisites (once)

1. **Docker Desktop** → Settings → General: enable *Use Rosetta for x86_64/amd64
   emulation on Apple Silicon*. Settings → Resources: give the VM **at least
   12 GB** of memory (the session container is capped at
   `BLUE_ZONE_ANDROID_MEMORY`, default 10g).
2. **Android Studio** (or just the SDK) on the Mac, with *Android Emulator*,
   *Platform-Tools* and *Command-line Tools* installed. `ANDROID_HOME` defaults
   to `~/Library/Android/sdk`.
3. Create the dedicated AVD:

   ```bash
   ./ai-scripts/android-emulator.sh create
   ```

   This installs `system-images;android-35;google_apis;arm64-v8a` and creates the
   `bluezone` AVD. Don't sign in to any account on it.

## Every session

```bash
./ai-scripts/android-emulator.sh start          # boots, waits, airplane mode ON
BLUE_ZONE_ANDROID_ENABLED=1 ./ai-scripts/start-cli.sh
```

(Or set `BLUE_ZONE_ANDROID_ENABLED=1` in `blue-zone.config.sh`.) The first run
builds `claude-code-android:latest` (about 2.6 GB compressed, 9.4 GB on disk;
several minutes).

Inside the session, Claude uses `bz-android`:

| Command | Does |
|---------|------|
| `bz-android connect` | `adb connect adb-relay:5555`, waits for boot, `adb reverse tcp:8081 tcp:8081` |
| `bz-android prepare` | Adds a throwaway `android/app/debug.keystore`, and a placeholder `google-services.json` if the Google Services plugin is applied. Never overwrites anything. |
| `bz-android build` | `prepare` + `./gradlew assembleDebug` |
| `bz-android run` | `connect` + `prepare` + Metro in background + `react-native run-android --no-packager --active-arch-only` |
| `bz-android screenshot [file]` | `adb exec-out screencap -p` (Claude can then read the PNG) |
| `bz-android logs` | logcat: errors + `ReactNativeJS` |

**First connect:** the sandbox has its own adb key, so the emulator shows an
*Allow USB debugging?* prompt. Tick *Always allow from this computer* and accept.
The key lives in the `claude-home` volume, so you only do this once.

When you're done: `./ai-scripts/android-emulator.sh stop`. The emulator runs
with `-no-snapshot-save`, so the next boot starts clean.

## Red-zone files a debug build needs

The blue zone strips `*.keystore` and `google-services.json`. Without them a
React Native debug build fails. `bz-android prepare` generates stand-ins:

- **debug.keystore**: generated in the image with the standard, public Android
  debug credentials. It isn't your keystore and can't sign a release.
- **google-services.json**: a placeholder with your `applicationId` (plus any
  `applicationIdSuffix`) and dummy values. It's enough for the Gradle plugin, but
  Firebase calls fail at runtime.

Both match red-zone rules, so `sync-back.sh` never copies them into your repo.

## Network

While Android is on, the session's egress proxy gets
`BLUE_ZONE_ANDROID_EGRESS_HOSTS` appended (exact-host lines, generated into
`$BLUE_ZONE_ROOT/.android-sandbox/filter`; `ai-proxy/filter` itself is not
edited):

```
dl.google.com  maven.google.com  repo.maven.apache.org
services.gradle.org  downloads.gradle.org  plugins.gradle.org
plugins-artifacts.gradle.org  repo.reactnative.dev  oss.sonatype.org
```

Gradle ignores `HTTPS_PROXY`, so the overlay sets `JAVA_TOOL_OPTIONS` with the
proxy for every JVM (Gradle, its daemon, sdkmanager). If your project uses
another repository (JitPack, a vendor's Maven), add its hostname to the list.
A private registry with credentials is a red-zone decision, so don't add it
casually.

## Security model and the risk you accept

What stays true with Android on:

- `adb-relay` connects to **one** host port, fixed at start. The session can't
  retarget it, and the emulator **console** (even ports, e.g. 5554, which can
  reconfigure the emulator) is refused by `blue_zone_android_check` and isn't
  forwarded.
- `claude-cli` still has no route to your LAN or the internet except through the
  proxy allowlist. The `android` network is internal.
- The headless service is unchanged.

**What changes, and you should decide consciously:**

- **The emulator has your Mac's network, and the session has `adb shell` on
  it.** In principle the session could push data onto the emulator and send it
  on from there, past the proxy allowlist. `android-emulator.sh start` turns on
  airplane mode, and debug builds don't need the device network (Metro goes over
  `adb reverse`). But the session could turn airplane mode off, so this guards
  against accidents. It isn't a boundary. `ai-scripts/CLAUDE.md` tells Claude not
  to touch it.
- The session can install and run arbitrary APKs on that emulator. Keep the AVD
  dedicated to the sandbox, with no accounts and no personal data.
- `adb-relay` sits on the `upstream` bridge in order to reach
  `host.docker.internal`. It runs only `socat` to a fixed target.

If those trade-offs aren't acceptable for a project, leave Android off. The
session can still build the APK if you add only the egress hosts, and you can
install it yourself.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `adb could not reach the emulator` | Is it running (`android-emulator.sh status`)? Is `BLUE_ZONE_ANDROID_ADB_PORT` its adb port (console + 1)? |
| `unauthorized` | Accept the debugging prompt on the emulator screen. |
| Device flips to `offline` | Your Mac's own adb server and the sandbox's are both attached. Run `adb kill-server` on the Mac (Android Studio restarts it later). |
| `403 Filtered` / `Received status code 403 from server: Filtered` in Gradle | A repository host isn't on `BLUE_ZONE_ANDROID_EGRESS_HOSTS`. |
| `429 Too Many Requests` from Maven Central | Rate limiting on the network you're on. Retry; the `gradle-cache` volume keeps what was fetched. |
| Gradle killed / exit 137 | Raise Docker Desktop's VM memory and `BLUE_ZONE_ANDROID_MEMORY`. |
| Very slow first build | Expected: cold cache plus Rosetta. Later builds are incremental. |

## Status of this feature

Verified in a Linux x86_64 container (see the PR for the run log):

- the image builds;
- `bz-android build` on a fresh React Native 0.76.5 app produces a debug APK
  through tinyproxy using the generated allowlist, with the keystore and
  `google-services.json` stripped;
- the compose overlay merges as intended;
- `adb-relay` forwards one port, and a client on the internal network can't
  reach the console port or the host.

**Not verified (needs a Mac):** Rosetta build performance, the emulator side
(`android-emulator.sh`), the adb authorization prompt, two adb servers attached
to one emulator, and `bz-android run` end to end.
