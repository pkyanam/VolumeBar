import AppKit
import CoreAudio

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
    init(_ operation: String, _ status: OSStatus) {
        let bits = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((bits >> $0) & 0xff) }
        let code = bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(bytes: bytes, encoding: .ascii)! : "\(status)"
        message = "\(operation) (\(code))."
    }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: element)
    }
    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: UInt32 = kAudioObjectPropertyElementMain) throws -> T {
        var result = value
        var property = address(selector, scope, element)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0) }
        guard status == noErr else { throw AudioFailure("Read audio property", status) }
        return result
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &result)
        guard status == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }
    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var property = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size)) : []
    }
    static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: UInt32 = kAudioObjectPropertyElementMain) throws {
        var property = address(selector, scope, element)
        var copy = value
        let status = withUnsafePointer(to: &copy) { AudioObjectSetPropertyData(object, &property, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
        guard status == noErr else { throw AudioFailure("Change audio setting", status) }
    }
    static func writable(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, element: UInt32 = 0) -> Bool {
        var property = address(selector, kAudioObjectPropertyScopeOutput, element)
        var canSet: DarwinBoolean = false
        return AudioObjectHasProperty(object, &property) && AudioObjectIsPropertySettable(object, &property, &canSet) == noErr && canSet.boolValue
    }
    static func defaultOutput() -> AudioObjectID {
        (try? read(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))) ?? 0
    }
    static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, pointer) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func streamFormat(_ stream: AudioObjectID) throws -> AudioStreamBasicDescription {
        try read(stream, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
    }
    static func isFloatPCM(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32 &&
        format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
    }
}

struct OutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let channels: Int
    let sampleRate: Double
    static func current() -> OutputDevice? { make(HAL.defaultOutput()) }
    static func make(_ id: AudioObjectID) -> OutputDevice? {
        guard id != 0, let uid = HAL.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return .init(id: id, uid: uid, name: HAL.string(id, kAudioObjectPropertyName) ?? "Audio output", channels: HAL.channelCount(id, scope: kAudioObjectPropertyScopeOutput), sampleRate: (try? HAL.read(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0))) ?? 0)
    }
    var volumeElements: [UInt32] {
        if HAL.writable(id, kAudioDevicePropertyVolumeScalar) { return [0] }
        return (1...max(1, channels)).map(UInt32.init).filter { HAL.writable(id, kAudioDevicePropertyVolumeScalar, element: $0) }
    }
    var volume: Float? {
        let values = volumeElements.compactMap { try? HAL.read(id, kAudioDevicePropertyVolumeScalar, default: Float32(1), scope: kAudioObjectPropertyScopeOutput, element: $0) }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }
    var muted: Bool { ((try? HAL.read(id, kAudioDevicePropertyMute, default: UInt32(0), scope: kAudioObjectPropertyScopeOutput)) ?? 0) != 0 }
    func setVolume(_ value: Float) throws {
        let elements = volumeElements
        guard !elements.isEmpty else { throw AudioFailure("This output controls volume on the device itself") }
        for element in elements { try HAL.set(id, kAudioDevicePropertyVolumeScalar, min(1, max(0, value)), scope: kAudioObjectPropertyScopeOutput, element: element) }
    }
    func setMute(_ value: Bool) throws {
        try HAL.set(id, kAudioDevicePropertyMute, UInt32(value ? 1 : 0), scope: kAudioObjectPropertyScopeOutput)
    }
}

struct AudioClient: Equatable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let running: Bool
    let outputDevices: [AudioObjectID]
    static func all() -> [AudioClient] {
        HAL.objects(HAL.system, kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let pid = try? HAL.read(id, kAudioProcessPropertyPID, default: pid_t(0)), pid != getpid(), pid > 0 else { return nil }
            return .init(id: id, pid: pid, bundleID: HAL.string(id, kAudioProcessPropertyBundleID) ?? "", running: ((try? HAL.read(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0) != 0, outputDevices: HAL.objects(id, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput))
        }
    }
}
