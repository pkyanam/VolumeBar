# Audio architecture

VolumeBar discovers regular apps plus Core Audio process objects once per second. It groups recognizable helper executables by their containing `.app`, preserves alphabetical row order, caches icons, and saves levels by app identity. Other audio clients remain searchable and can be displayed with the background-process option.

At 100%, an app stays on its original audio path. An adjusted, active app gets a private Core Audio process tap and aggregate output route bound to the current output. Physical input channels are disabled. The tap initially leaves the source unmuted and emits no duplicate playback. Once actual signal is observed, the tap switches to `mutedWhenTapped` and the renderer fades to the selected gain.

The realtime callback uses C and atomics: no allocation, locks, disk I/O, or Swift object access. It validates buffer layouts, handles interleaved and planar Float32 mono/stereo, applies 10 ms gain ramps, filters non-finite samples, and bounds output to ±1.

Swift performs lifecycle operations outside the callback. Routes stop on bypass, quit, sleep, app exit, and output changes. Private audio objects do not persist across app launches. If HAL refuses to remove a callback, its small C context is intentionally retained until process exit rather than risking a use-after-free.

No driver, kernel extension, privileged helper, microphone permission, default-device replacement, or audio-service restart is used. Audio is never saved or transmitted. Master volume uses the physical device's normal volume property and is independent of mixer bypass.

See Apple's [Core Audio taps sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
