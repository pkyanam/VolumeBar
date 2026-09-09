# Resource usage

VolumeBar 0.4 replaces the retained SwiftUI panel with an on-demand AppKit panel. When you close it, the controller, controls, subscriptions, and app-icon cache are released. The app stays in the menu bar and continues honoring your saved levels.

## Idle behavior

- **No enabled custom levels, panel closed:** no periodic process-discovery timer. Core Audio notifications update device/volume state.
- **Custom volume or mute enabled:** lightweight discovery continues once a second so levels apply when apps start playing. Audio buffers still run at the hardware callback rate.
- **Panel open:** app discovery runs once a second. Table cells are reused, process owners are cached, and only displayed rows request icons.
- **Bypassed or sleeping:** unnecessary app discovery stops. Device notifications stay registered; wake refreshes state.

Icons are flattened to 64×64 RGBA bitmaps. The model keeps at most 32 (about 512 KiB of pixel data) and drops the entire cache on close. Ownership metadata is pruned as processes exit. One coalesced, off-main-thread cleanup after closing asks malloc to return unused pages; it is skipped during active mixing. There are no machine-wide memory purges, background helpers, or automatic app restarts.

Version 0.4.1 also releases the entire popover/window and uses opaque content and simpler native control styles. The 0.4.0 CI binary retained more UI/framework memory than the local development binary (about 98 MiB RSS / 38 MiB footprint after use), which prompted this follow-up. Build-toolchain differences matter; release-binary measurements should take precedence over local development results.

## Measurements

Development measurements on the same Mac, macOS 26.6.2, September 9, 2026:

| State | RSS | Physical footprint |
| --- | ---: | ---: |
| 0.3.0, after using and closing the panel | 117 MiB | 41 MiB |
| 0.4.0, menu-bar launch before opening the panel | 42–44 MiB | 11 MiB |
| 0.4.0, after using and closing the panel | 83 MiB | 27 MiB |

The final closed-panel 0.4 development sample used 0.04 CPU seconds over 30 elapsed seconds (about 0.13% of one core); a prior 0.3 sample used about 1.9% of one core. These are observations on one machine, not universal limits. UI history, other system activity, macOS version, and active mixing affect results.

RSS includes resident shared framework mappings, so it is **not** the same as memory uniquely charged to this app. Physical footprint is the more useful measure of its memory-pressure cost. Both are reported to keep comparisons honest. The panel's first use loads AppKit/framework caches that macOS can retain; closing the UI does not return RSS to its cold-launch value. See Apple's [memory-footprint guidance](https://developer.apple.com/library/archive/technotes/tn2434/_index.html).

## Reproduce

Quit other copies of VolumeBar. Launch the version being measured, wait for it to settle, and leave the panel closed. To measure startup separately, launch with `--background` before opening any panel. For a normal-use comparison, open Applications, scroll/search, open Devices, then dismiss the popover before measuring.

```sh
./Scripts/profile.py "$(pgrep -x VolumeBar)" --seconds 30 \
  --output artifacts/profile.json
```

The script is read-only. It measures CPU time and RSS using `ps`, then records physical footprint with `vmmap`. It does not change audio, simulate system memory pressure, or terminate processes. Repeat after several open/close cycles and with a saved custom app level to check both UI cleanup and background mixing.

Tests cover the polling policy, settings accessibility, and repeated deallocation of loaded panel controllers. Live audio tests remain separate and opt-in; they generate their own quiet signal without capturing unrelated apps.
