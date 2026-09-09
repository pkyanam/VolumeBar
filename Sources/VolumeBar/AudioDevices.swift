import AppKit
import CoreAudio

// Discovery uses HAL notifications, never Bluetooth scans or a battery polling process.
enum AudioDirection {
    case output, input
    var scope: AudioObjectPropertyScope { self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput }
    var selector: AudioObjectPropertySelector { self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice }
}

struct AudioEndpoint: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    let outputChannels: Int
    let inputChannels: Int
    let sampleRate: Double
    let canOutput: Bool
    let canInput: Bool

    var isWireless: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
    var kind: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "Display"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        default: return "Audio device"
        }
    }
    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return outputChannels > 0 ? "laptopcomputer" : "mic.fill"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        default: return "hifispeaker.fill"
        }
    }
    var detail: String {
        let rate = sampleRate > 0 ? String(format: " · %g kHz", sampleRate / 1000) : ""
        return "\(kind)\(rate) · \(outputChannels) ch"
    }
    func supports(_ direction: AudioDirection) -> Bool { direction == .output ? canOutput : canInput }
    static func read(_ id: AudioObjectID) -> AudioEndpoint? {
        guard let uid = HAL.string(id, kAudioDevicePropertyDeviceUID),
              !uid.hasPrefix("com.volumebar.private."),
              ((try? HAL.read(id, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0))) ?? 0) != 0,
              ((try? HAL.read(id, kAudioDevicePropertyIsHidden, default: UInt32(0))) ?? 0) == 0 else { return nil }
        let outputs = HAL.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
        let inputs = HAL.channelCount(id, scope: kAudioObjectPropertyScopeInput)
        func eligible(_ scope: AudioObjectPropertyScope, _ channels: Int) -> Bool {
            channels > 0 && ((try? HAL.read(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, default: UInt32(0), scope: scope)) ?? 0) != 0
        }
        return .init(id: id, uid: uid, name: HAL.string(id, kAudioObjectPropertyName) ?? "Audio device",
                     transport: (try? HAL.read(id, kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0,
                     outputChannels: outputs, inputChannels: inputs,
                     sampleRate: (try? HAL.read(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0))) ?? 0,
                     canOutput: eligible(kAudioObjectPropertyScopeOutput, outputs), canInput: eligible(kAudioObjectPropertyScopeInput, inputs))
    }
}

// Revalidate both the HAL ID and persistent UID at click time: IDs can be reused after unplugging.
struct AudioDeviceRouter {
    var read: (AudioObjectID) -> AudioEndpoint? = AudioEndpoint.read
    var current: (AudioDirection) -> AudioObjectID = { direction in
        (try? HAL.read(HAL.system, direction.selector, default: AudioObjectID(0))) ?? 0
    }
    var write: (AudioDirection, AudioObjectID) throws -> Void = { direction, id in
        try HAL.set(HAL.system, direction.selector, id)
    }
    func select(_ endpoint: AudioEndpoint, direction: AudioDirection, beforeChange: () -> Void) throws {
        guard let live = read(endpoint.id), live.uid == endpoint.uid, live.supports(direction) else {
            throw AudioFailure("This device is no longer available. Choose a connected device.")
        }
        guard current(direction) != live.id else { return }
        beforeChange()
        try write(direction, live.id)
    }
}

@MainActor
final class AudioDeviceCatalog: ObservableObject {
    @Published private(set) var devices: [AudioEndpoint] = []
    @Published private(set) var inputID: AudioObjectID = 0
    var onChange: (() -> Void)?
    private struct Listener {
        let id: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var listeners: [Listener] = []
    private var observedIDs: Set<AudioObjectID> = []
    private var pending: DispatchWorkItem?
    private var stopped = false

    init() {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            listen(HAL.system, HAL.address(selector))
        }
        refresh()
    }
    var outputs: [AudioEndpoint] { devices.filter(\.canOutput) }
    var inputs: [AudioEndpoint] { devices.filter(\.canInput) }
    var input: AudioEndpoint? { inputs.first { $0.id == inputID } }
    func refresh() {
        guard !stopped else { return }
        let ids = Set(HAL.objects(HAL.system, kAudioHardwarePropertyDevices).filter {
            !(HAL.string($0, kAudioDevicePropertyDeviceUID) ?? "").hasPrefix("com.volumebar.private.")
        })
        if ids != observedIDs {
            removeListeners { $0.id != HAL.system }
            for id in ids {
                for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyName] {
                    listen(id, HAL.address(selector))
                }
                for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
                    listen(id, HAL.address(kAudioDevicePropertyStreamConfiguration, scope))
                }
                // Listen to all volume channels, including hardware with no master element.
                for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                    listen(id, HAL.address(selector, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementWildcard))
                }
            }
            observedIDs = ids
        }
        let snapshot = ids.compactMap(AudioEndpoint.read).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if snapshot != devices { devices = snapshot }
        let current = (try? HAL.read(HAL.system, kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(0))) ?? 0
        if current != inputID { inputID = current }
    }
    private func listen(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr {
            listeners.append(.init(id: id, address: address, block: block))
        }
    }
    private func scheduleRefresh() {
        guard !stopped else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.refresh(); self.onChange?()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
    private func removeListeners(where predicate: (Listener) -> Bool) {
        for var listener in listeners.filter(predicate) {
            AudioObjectRemovePropertyListenerBlock(listener.id, &listener.address, .main, listener.block)
        }
        listeners.removeAll(where: predicate)
    }
    func stop() {
        stopped = true
        pending?.cancel(); pending = nil
        onChange = nil
        removeListeners { _ in true }
    }
}

struct VolumeIndicator: Equatable {
    let symbol: String
    let description: String
    init(volume: Float, muted: Bool, available: Bool, adjustable: Bool) {
        if !available { symbol = "speaker.badge.exclamationmark"; description = "No audio output" }
        else if muted || (adjustable && volume <= 0.001) { symbol = "speaker.slash.fill"; description = "Muted" }
        else if !adjustable { symbol = "speaker.wave.2.fill"; description = "Device-controlled volume" }
        else {
            symbol = volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            description = "\(Int((min(1, max(0, volume)) * 100).rounded()))%"
        }
    }
}
