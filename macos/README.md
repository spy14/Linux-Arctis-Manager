# Arctis Settings for macOS (prototype)

A standalone SwiftUI settings app for the Arctis 7+ USB dongle. The Linux app is unchanged. Requires macOS 13+ and Xcode Command Line Tools to build; no Python, Rust, Homebrew or third-party libraries are needed.

## Build and open

From the repository root:

```sh
sh macos/build.sh
open "macos/build/Arctis Settings.app"
```

The build targets the local CPU architecture and is ad-hoc signed for local use, not notarized for distribution. You can copy the resulting app to Applications.

## GitHub Actions builds and releases

`Build macOS app` (`.github/workflows/build-macos.yaml`) runs for changes to the
macOS app, version or relevant workflows, and can also be started from the
Actions tab with **Run workflow**. It tests and packages separately on Apple
Silicon (`macos-15`) and Intel (`macos-15-intel`). No headset or Apple credentials
are needed. Download the `macos-arm64` or `macos-x86_64` workflow artifact and
extract the app ZIP inside it.

When Linux CI is enabled (or in the upstream repository), pushing a `v*` version tag invokes the same build from the existing
`Release (draft)` workflow. Both app ZIPs and their `.sha256` checksum files are
attached to that draft alongside the Linux packages. The existing release
publication/approval process still applies. Manually running `Release (draft)`
remains COPR-only; use `Build macOS app` for a manual macOS build.

### Enable macOS-only builds on a fork

1. Commit and push the `macos/` directory and workflow changes to your fork.
   Put the workflows on the fork's default branch for the **Run workflow** button
   to appear (or merge your working branch into that default branch).
2. Open the fork's **Actions** tab and enable workflows if GitHub prompts you.
   Under **Settings → Actions → General**, ensure GitHub Actions and the
   `actions/*` actions used here are allowed.
3. Select **Build macOS app → Run workflow**, choose the branch containing the
   app, and start it. Download `macos-arm64` or `macos-x86_64` from the completed
   run's **Artifacts** section. A normal push changing macOS files also builds.
4. For a release, tag a committed version containing these workflows:

   ```sh
   git tag mac-v0.1.0
   git push origin mac-v0.1.0
   ```

   Use a fresh version tag each time. **Release macOS (draft)** builds both
   architectures and creates a draft in the fork's **Releases** page. Review
   it and click **Publish release** when ready. It needs no COPR or Apple secrets;
   its release job requests `contents: write` through the normal `GITHUB_TOKEN`.
   Re-running can replace draft assets but refuses to modify published releases.

Linux build, test, audit and COPR jobs are skipped by default on forks. Their
workflow entries may still appear as skipped, but no runners are started for
those jobs. To restore them later, set the repository Actions variable
`ENABLE_LINUX_CI` to `true` under **Settings → Secrets and variables → Actions →
Variables**. The upstream `elegos/Linux-Arctis-Manager` keeps its existing behavior.
The macOS release uses an Ubuntu runner only to upload assets; it builds no Linux
packages and does not run Linux tests.

Release downloads are named `Arctis-Settings-<version>-macos-<arch>.zip`.
Tag builds use the tag version (without `mac-v` or `v`); other builds use `VERSION`.
The numeric version is written to the app's standard bundle version fields,
and `LAMReleaseVersion` preserves the full prerelease version.

These downloads are **ad-hoc signed, not Apple-notarized**. Gatekeeper may block
an Internet-downloaded app; users who trust the build may need macOS's
**System Settings → Privacy & Security → Open Anyway** flow. Developer ID signing
and notarization are not configured in this workflow. They require an Apple
Developer membership, signing certificate and notarization credentials.

To reproduce CI locally:

```sh
sh macos/test.sh
sh macos/package.sh
# Optional version override:
APP_VERSION=3.0.0-beta2 sh macos/package.sh
```

Packages are written to `macos/build/release/`. GitHub-hosted tests cover command
encoding and status parsing; they cannot verify physical headset behavior.

## Use

Connect the dongle and turn on the headset. Choose values and click the corresponding Apply button. **Save to headset** sends the flash-save command for settings already applied; it does not apply unsent choices. Nothing is applied automatically on launch or reconnection.

The controls cover sidetone, microphone gain, mute LED brightness, ten-band hardware EQ (±12 dB, 0.5 dB steps), and inactivity timeout. Local choices are retained, but the headset does not expose readback for these settings. Initial values are draft choices, not detected device settings. Battery reporting is in 25% steps.

ChatMix routing, software audio effects, firmware updates and pairing are outside this prototype.

## Verification

On the connected 1038:220e dongle, verified HID enumeration, successful status query, connection events, 50% battery and discharging status. The SwiftUI app was opened and visually inspected. Setting payloads are unit-tested against the repository definitions; audible effects and flash persistence still need user testing. No settings were changed during verification.

```sh
xcrun swiftc -module-cache-path macos/build/module-cache macos/Sources/Headset.swift macos/Tests/main.swift -o macos/build/tests
macos/build/tests
# Optional: requires connected, powered-on headset and USB access.
macos/build/tests --hardware
```

## Transport details

Uses Apple's IOHID APIs directly, opening vendor usage pages 0xFFC0 and 0xFF00 without exclusive access. Commands use 0xFFC0. macOS output payloads are 64 bytes, without Linux's synthetic leading report-ID zero. Live incoming reports likewise begin with the command byte. Device definitions: `daemon/device-configs/arctis_7_plus.yaml` and `base_arctis_7_plus.yaml`.

The Destiny 2 PID 0x2236 is included but untested. Multiple connected dongles are not supported. USB command success means the OS accepted the transfer, not that settings were read back. Reconnect uses a five-second retry timer; the refresh button reconnects immediately.
