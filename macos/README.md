# Arctis Settings for macOS (prototype)

A native SwiftUI app for the Arctis 7+ USB dongle, with Core Audio routing,
software EQ, microphone effects, and the Linux project's shared RVC inference
engine. Headset settings require macOS 13+; ChatMix process taps require macOS
14.2+. Both Apple Silicon and Intel builds are produced by CI.

## Build and open

Requires Xcode Command Line Tools, Python 3 for bundle metadata, and a current
Rust toolchain for the AI helper. From the repository root:

```sh
sh macos/build.sh
sh macos/build-voice.sh
open "macos/build/Arctis Settings.app"
```

`build.sh` builds the app and CLI; `build-voice.sh` adds the shared Rust inference
helper. `package.sh` runs both. The build targets the local CPU architecture and
is ad-hoc signed, not notarized. No third-party libraries are required for the
Swift app. AI conversion additionally needs ONNX Runtime and model files at
runtime; the AI Models tab provides setup and import/download controls.

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

## Features and use

### Headset

Connect the dongle and turn on the headset. Choose values and click Apply for
sidetone, microphone gain, mute LED brightness, hardware EQ or inactivity timeout.
**Apply all settings** applies a complete draft and remembers it for optional
restoration. **Save to headset** sends the flash-save command for settings already
applied; it does not apply unsent choices. No settings are read back by this model.

Profiles can be named, imported/exported as JSON, linked to an application, and
applied from the menu bar. Application switching and reconnect restoration are
opt-in. Only a successfully applied complete profile is eligible for automatic
restoration. Individual-section changes do not replace that complete profile.
Launch at login uses macOS Login Items. Pairing has an explicit confirmation.

### ChatMix and software EQ

Choose an output, select the applications belonging to Chat, and enable routing.
Other applications use Media. macOS requests system-audio capture permission.
The physical dial controls both channel gains, or disable “Follow the dial” to
use the software balance slider. Each channel has independent 10/15-band EQ and
saved presets. Stop routing to return applications to their normal audio paths.

The implementation uses private Core Audio taps, private aggregate devices, and
AVAudioEngine. It does not change the system default output. Audio is processed
locally and not recorded by ChatMix. Changing chat-app selection recreates taps;
new processes are detected every three seconds. Output disconnection stops
routing. A crash/exit releases the private taps and their muting behavior.

### Microphone and voice effects

Install [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole#installation-instructions),
then choose a physical microphone and BlackHole as the virtual output. Select
BlackHole as the microphone in Discord, Zoom or another receiving app. The app
never installs a system driver automatically.

Available processing: Apple voice-processing noise suppression, high-pass filter,
noise gate, compressor, makeup gain, pitch, delay, reverb, distortion, and a
modulated multi-voice chorus. Stop processing before changing settings; successful
settings are retained for the next session. Processing always starts explicitly.
Device configuration changes stop processing so the user can review the route.

**Platform difference:** noise suppression and conventional effects use Apple's
Audio Units, not Linux's RNNoise/LADSPA plugins. They provide corresponding
functions but are not acoustically identical, and some advanced Linux controls
have different equivalents. Media/chat routing uses per-app capture rather than
two public PipeWire sinks. Apps sharing a process/bundle identifier cannot always
be separated, and protected audio may be unavailable to capture.

### AI voice conversion

1. In AI Models, choose a Python 3 interpreter and install dependencies into the
   app's private environment (downloads PyTorch, NumPy, ONNX, ONNX Runtime and
   ONNXScript). Nothing is installed until the user confirms.
2. Download base models. ContentVec and RMVPE come from the upstream model release
   and are checked against its SHA-256 manifest before use.
3. Import an RVC v2 `.onnx` model, or import a trusted `.pth` checkpoint and export
   it to ONNX. The bundled exporter validates its output against PyTorch.
   The synthesizer must include the exporter's `sample_rate` metadata.
4. Optionally import a same-stem `.index` file for retrieval. Configure pitch,
   formants, envelope blend, input drive, limiter and pitch smoothing. CPU is the
   default; Core ML can be requested with CPU fallback. An ONNX Runtime library
   exposing API 22 or later is required (the UI also accepts a manually selected
   dylib).
5. Enable AI conversion in Microphone and start processing. Live conversion runs
   in a separate Rust process using the exact shared Linux inference/DSP sources.
   If it falls behind, the app stops instead of accumulating unlimited latency.

Hugging Face browsing supports model search, file listing and downloads. Optional
read tokens are stored in macOS Keychain and stripped from cross-host CDN
redirects. Private/gated models still require the user's account to have access.
Model files can be moved to Trash. ZIP model bundles are not imported automatically;
extract them and import their PTH/ONNX/index files.

For calibration, record a 10-second sample from the system default microphone
(start with a second of silence), render it through the selected voice, and
compare original/converted recordings. Existing PCM16 or float32 WAV files can
also be rendered. The offline helper uses the shared noise-floor calibration
and flushes its look-ahead buffers to preserve the end of speech. Recordings and
model files stay under `~/Library/Application Support/Arctis Settings/Models`.

### Command line

The app bundle includes `Contents/MacOS/arctis-cli`:

```sh
"macos/build/Arctis Settings.app/Contents/MacOS/arctis-cli" status
"macos/build/Arctis Settings.app/Contents/MacOS/arctis-cli" profiles
"macos/build/Arctis Settings.app/Contents/MacOS/arctis-cli" apply-profile "My profile"
```

Also supports `save`, `pair`, and `stop-pairing`. Audio routing is controlled by
the graphical app; the CLI is for headset status and settings.

## Verification and remaining acceptance work

Automated checks: HID report encoding/status parsing, malformed profile rejection,
profile persistence, EQ resampling, bounded audio ring wrap/overflow/underrun
behavior with address/undefined-behavior sanitizers, and the shared Rust inference
unit tests. Both Swift architectures compile. CI builds/tests the native helper
on each architecture and verifies the app archive/signatures/checksums.

The earlier settings build was verified against the connected 1038:220e dongle
(connection, battery and charging events). The expanded audio paths still require
live acceptance testing with system-audio and microphone permissions, a connected
headset, BlackHole and a real voice model. The seven upstream model-backed tests
remain ignored unless the corresponding models/runtime/test audio are provided.
Compilation and unit tests do not establish audio quality, dropout behavior,
flash persistence, or successful live AI conversion. This remains an experimental
port, not a claim of verified, exact Linux parity.

```sh
sh macos/test.sh
cargo test --locked --manifest-path macos/voice-engine/Cargo.toml
sh macos/test.sh --hardware  # optional connected-headset check
```

## Transport details

Uses IOHID APIs directly, opening vendor usage pages 0xFFC0 and 0xFF00 without
exclusive access. Commands use 0xFFC0. macOS output payloads are 64 bytes without
Linux's synthetic leading report-ID zero. Incoming reports begin with the command
byte. Definitions: `daemon/device-configs/arctis_7_plus.yaml` and
`base_arctis_7_plus.yaml`.

The Destiny 2 PID 0x2236 is included but untested. Other headset families and
multiple connected dongles are not supported by this macOS frontend. Battery
reporting is in 25% steps. USB command success means the OS accepted the transfer,
not that settings were read back. Reconnection retries every five seconds.
