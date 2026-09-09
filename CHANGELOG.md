# Changelog

## 0.4.1

- Release the entire popover and its window on close, including backing surfaces.
- Use an opaque AppKit panel and simpler control styles to reduce rendering overhead.

## 0.4.0

- Replaced the retained SwiftUI panel with native AppKit controls and reusable table cells.
- Create the panel only on demand; release its controls, subscriptions, and icons on close.
- Stop process polling when closed with no enabled custom levels. Continue monitoring saved adjustments so they apply when audio starts.
- Load app icons only for displayed rows as bounded 64-pixel bitmaps; discard the cache on close.
- Cache process ownership metadata and prune it as processes exit; stop retaining app bundles.
- Return freed heap pages after the panel closes, outside audio callbacks.
- Add panel lifetime and polling-policy regression tests plus a read-only resource profiling script.

## 0.3.0

- Volume-aware speaker menu bar icon, with mute/low/medium/high states and an output/percentage tooltip.
- Connected output picker with persistent favorites, transport icons, sample rate, and channel details.
- Independent system microphone selection and a Mac-microphone shortcut for Bluetooth output.
- Notification-driven device discovery with debounced updates and explicit listener cleanup.
- Revalidate device identities before switching, release mixer routes before changes, and preserve destination volume.
- Device routing and icon tests, including stale/reused IDs, no-op selection, and write failures.

## 0.2.0

- Apple Silicon release builds, with optional universal builds for Intel Macs.
- First-launch instructions and an in-app setup shortcut.
- Automated build, tests, packaging, Developer ID signing, notarization, and releases.
- Download-first README and dedicated contributor and signing guides.

## 0.1.0

- Native menu bar mixer with master and per-app volume, mute, search, and bypass.
- Public Core Audio process taps; no audio driver installation.
- Saved app levels, helper-process grouping, and output/sleep handling.
