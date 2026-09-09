# Audio architecture

VolumeBar discovers regular apps plus Core Audio process objects once per second. It groups recognizable helper executables by their containing `.app`, preserves alphabetical row order, caches icons, and saves levels by app identity. Other audio clients remain searchable and can be displayed with the background-process option.

At 100%, an app stays on its original audio path. An adjusted, active app gets a private Core Audio process tap and aggregate output route bound to the current output. Physical input channels are disabled. The tap initially leaves the source unmuted and emits no duplicate playback. Once actual signal is observed, the tap switches to `mutedWhenTapped` and the renderer fades to the selected gain.

The realtime callback uses C and atomics: no allocation, locks, disk I/O, or Swift object access. It validates buffer layouts, handles interleaved and planar Float32 mono/stereo, applies 10 ms gain ramps, filters non-finite samples, and bounds output to ±1.

Swift performs lifecycle operations outside the callback. Routes stop on bypass, quit, sleep, app exit, and output changes. Private audio objects do not persist across app launches. If HAL refuses to remove a callback, its small C context is intentionally retained until process exit rather than risking a use-after-free.

No driver, kernel extension, privileged helper, microphone permission, default-device replacement, or audio-service restart is used. Audio is never saved or transmitted. Master volume uses the physical device's normal volume property and is independent of mixer bypass.

See Apple's [Core Audio taps sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).


## Device selection (0.3)

`AudioDeviceCatalog` listens to Core Audio device-list/default-device notifications and per-device format, volume, mute, and availability changes. Events coalesce over 80 ms. Device enumeration adds no polling timer or Bluetooth scans; the mixer reconciliation timer runs only while needed. Private VolumeBar aggregate routes are excluded. Shutdown removes listeners and cancels pending refreshes.

`AudioDeviceRouter` re-reads the selected HAL ID and checks its persistent UID and direction capability before writing the system default. Selecting the current device is a no-op. Input selection writes only the default-input property; output selection leaves the system alert output and destination volume alone. Existing mixer sessions stop before changes and reconcile against the observed output afterward, including failed switches. Format/default changes caused by external apps also rebuild routes through the existing reconciliation path.

Favorites store UIDs, not transient HAL IDs. They affect sorting only. AirPods are ordinary available Core Audio endpoints with the same controls as other Bluetooth headphones. No battery, ANC, or private Bluetooth APIs are used. Input selection does not open or capture a microphone.

The menu bar observes published master state and only redraws when its displayed label changes. Unit tests inject device reads/writes to exercise switching failures without changing test-machine hardware.


## Resource lifecycle (0.4)

The menu bar owns the audio model, but constructs `MixerPanelController` only when opening the popover. The panel uses AppKit controls and a reusable `NSTableView`, with coalesced model updates. Closing drops the content controller and all UI subscriptions. Starting in 0.4.1, the whole popover and window are released too; opaque content and nonanimated presentation avoid extra blur/transition rendering. Tests create and release loaded panels repeatedly to detect retention cycles.

`ResourcePolicy` enables the one-second app-discovery timer only while the panel is open or enabled custom volumes exist. A muted app still counts as a custom volume. Bypass, sleep, and isolated diagnostic mode suspend unnecessary work. Output/master notifications remain active even without polling. Saved custom volumes continue to be applied to newly playing clients while the panel is closed.

Only table cells request icons. The cache holds at most 32 flattened 64×64 RGBA images (about 512 KiB of pixel data) and is cleared on close. Process ownership metadata is cached by HAL process ID and PID, pruned as clients leave, and discarded when fully idle. Whole bundles and original icon representations are not retained by the model.

One coalesced cleanup after panel dismissal asks malloc to return unused pages on a utility queue; it is skipped when app mixing is active. There is no repeated memory-pressure simulation, machine-wide purge, or process restart. Shared AppKit/framework mappings may stay resident after first use; RSS and physical footprint must be reported separately.
