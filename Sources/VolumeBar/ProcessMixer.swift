import Foundation
import CoreAudio
import AudioDSP

// All lifecycle operations are serialized by MixerModel on the main thread.
// The C callback owns only atomic controls and its private DSP state.
final class ProcessMixer {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var renderState: OpaquePointer?
    private var tapDescription: CATapDescription?
    private var desiredGain: Float = 1
    private var shouldControl = true
    private(set) var isControlling = false
    private(set) var processIDs: [AudioObjectID]
    private(set) var device: OutputDevice
    private(set) var startedAt = Date()
    var stats: VBRenderStats { VBRenderGetStats(renderState) }

    init(processIDs: [AudioObjectID], device: OutputDevice, gain: Float, name: String, muteSource: Bool = true) throws {
        self.processIDs = processIDs.sorted()
        self.desiredGain = gain
        self.shouldControl = muteSource
        self.device = device
        do { try start(gain: gain, name: name, muteSource: muteSource) }
        catch { stop(); throw error }
    }
    private func start(gain: Float, name: String, muteSource: Bool) throws {
        guard !processIDs.isEmpty else { throw AudioFailure("Waiting for this app to open an audio stream") }
        guard (1...2).contains(device.channels) else { throw AudioFailure("Per-app mixing currently supports mono and stereo outputs") }
        let streams = HAL.objects(device.id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard !streams.isEmpty else { throw AudioFailure("No output stream is available") }
        for stream in streams {
            guard HAL.isFloatPCM(try HAL.streamFormat(stream)) else { throw AudioFailure("This output's audio format isn't supported yet") }
        }
        // Bind to the current output's stream so we don't reroute an app's other destinations.
        let description = CATapDescription(processes: processIDs, deviceUID: device.uid, stream: 0)
        description.name = "VolumeBar · \(name)"
        description.uuid = UUID()
        description.isPrivate = true
        // Validate capture before ever suppressing the source. Denied/protected audio stays audible.
        description.muteBehavior = .unmuted
        tapDescription = description
        try check(AudioHardwareCreateProcessTap(description, &tap), "Create app audio tap")
        let format = try HAL.read(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        guard HAL.isFloatPCM(format), Int(format.mChannelsPerFrame) == device.channels else {
            throw AudioFailure("The app and output have incompatible audio formats")
        }
        let definition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolumeBar · \(name)",
            kAudioAggregateDeviceUIDKey: "com.volumebar.private.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: device.uid,
                kAudioSubDeviceInputChannelsKey: 0,
                kAudioSubDeviceOutputChannelsKey: device.channels
            ]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        try check(AudioHardwareCreateAggregateDevice(definition as CFDictionary, &aggregate), "Create private audio route")
        // Reject unexpected layouts before muting the source or starting any callback.
        guard HAL.channelCount(aggregate, scope: kAudioObjectPropertyScopeInput) == device.channels,
              HAL.channelCount(aggregate, scope: kAudioObjectPropertyScopeOutput) == device.channels else {
            throw AudioFailure("This device exposes an unsupported audio layout; normal audio is preserved")
        }
        for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
            for stream in HAL.objects(aggregate, kAudioDevicePropertyStreams, scope: scope) {
                let streamFormat = try HAL.streamFormat(stream)
                guard HAL.isFloatPCM(streamFormat), abs(streamFormat.mSampleRate - format.mSampleRate) < 1 else {
                    throw AudioFailure("This device needs audio format conversion that isn't supported yet")
                }
            }
        }
        guard let state = VBRenderCreate(muteSource ? 0 : gain, format.mSampleRate, format.mChannelsPerFrame) else { throw AudioFailure("Couldn't prepare the audio processor") }
        renderState = state
        try check(AudioDeviceCreateIOProcID(aggregate, VBRenderCallback, UnsafeMutableRawPointer(state), &ioProc), "Prepare audio playback")
        try check(AudioDeviceStart(aggregate, ioProc), "Start app mixing — allow System Audio Recording in System Settings if requested")
        startedAt = Date()
    }
    func setGain(_ gain: Float) {
        desiredGain = gain
        if isControlling || !shouldControl { VBRenderSetGain(renderState, gain) }
    }
    func activateWhenReady() throws {
        guard shouldControl, !isControlling, stats.signalBuffers > 0, let tapDescription else { return }
        tapDescription.muteBehavior = .mutedWhenTapped
        try HAL.set(tap, kAudioTapPropertyDescription, tapDescription)
        isControlling = true
        VBRenderSetGain(renderState, desiredGain)
    }
    func stop() {
        var callbackDestroyed = true
        if let ioProc, aggregate != 0 {
            AudioDeviceStop(aggregate, ioProc)
            callbackDestroyed = AudioDeviceDestroyIOProcID(aggregate, ioProc) == noErr
        }
        ioProc = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        // In the exceptional case HAL refuses to remove a callback, retain its tiny C context
        // until process exit instead of risking a use-after-free on the audio thread.
        if let renderState, callbackDestroyed { VBRenderDestroy(renderState) }
        isControlling = false
        tapDescription = nil
        renderState = nil
    }
    deinit { stop() }
    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AudioFailure(operation, status) }
    }
}
