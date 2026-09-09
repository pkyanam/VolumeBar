# Development

## Requirements

- macOS 14.4+, Xcode 16.4 or later (CI pins Xcode 26.3 on `macos-15`).
- `gh` only for repository/release management.
- No third-party Swift dependencies or globally installed build tools.

Open `Package.swift` in Xcode or use `make install`. Local installs go into `~/Applications`; no administrator access is needed. First use may request System Audio Recording permission. Rebuilding an ad-hoc signature can cause another permission prompt.

## Layout

```text
Sources/VolumeBar/    AppKit panel and lifecycle, audio routing, diagnostics
Sources/AudioDSP/     Allocation-free C render callback and atomic gain controls
Tests/AudioDSPTests/  DSP correctness and buffer safety tests
Resources/           Info.plist and application icon
Scripts/             Build, verify, package, install, signing, and self-test
.github/workflows/   CI and trusted release jobs
docs/                Developer, signing, distribution, and audio guides
version.env          User-facing version and local build number
```

## Commands

```sh
make check
make install
CONFIGURATION=debug ./Scripts/build.sh
./dist/VolumeBar.app/Contents/MacOS/VolumeBar --version
./dist/VolumeBar.app/Contents/MacOS/VolumeBar --diagnose
```

`--diagnose` reads your local audio-device and process inventory. Do not post its full output publicly without reviewing it.

## Intel and universal builds

```sh
ARCH=universal ./Scripts/build.sh
ARCH=universal ./Scripts/package.sh
# Or just Intel:
ARCH=x86_64 ./Scripts/build.sh
```

`make install` automatically selects the host architecture. Release packaging defaults to arm64. Build and package with the same `ARCH` value; verification rejects an unexpected architecture.

## Audio verification

`swift test -j 2` verifies DSP attenuation, stereo separation, planar/interleaved buffers, mute ramps, malformed layouts, and output bounds. CI does not depend on an audio device or a macOS permission dialog.

For a live, opt-in test, quit VolumeBar and run `./Scripts/self-test.sh`. A separate process generates a quiet −50 dBFS tone. The app validates live tap/playback-buffer gain at 50%, 25%, zero, and unity over three start/stop cycles. It checks source continuity after teardown and that master volume/default output remain unchanged. The test exits automatically and writes `artifacts/integration-test.json`. It does not capture other apps. These are digital buffer measurements, not acoustic measurements.

Test output-device switching, sleep/wake, and protected media manually on a machine where audio interruptions are acceptable. Do not restart `coreaudiod` or change a user's default output as a troubleshooting shortcut.

## Versions

Edit `version.env` and `CHANGELOG.md`. The bundler applies version metadata to a fresh app, rather than editing source resources in place. CI uses its run number as the build number. Stable release tags must exactly match `v$VERSION`.

## Before a pull request

Run `make check`, explain changed behavior, and list verification performed. Keep credential material outside the checkout. The repository ignores signing files, local diagnostics, build output, and environment files.

Resource regression checks and repeatable profiling: [Performance](performance.md).
