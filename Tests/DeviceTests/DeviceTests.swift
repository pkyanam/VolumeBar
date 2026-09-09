import XCTest
import CoreAudio
@testable import VolumeBar

final class DeviceTests: XCTestCase {
    private func device(id: UInt32 = 42, uid: String = "headphones", output: Bool = true, input: Bool = true) -> AudioEndpoint {
        .init(id: id, uid: uid, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth,
              outputChannels: 2, inputChannels: 1, sampleRate: 48000, canOutput: output, canInput: input)
    }
    func testDisconnectedOrReusedIDCannotChangeRoute() {
        for snapshot in [nil, device(uid: "different-device"), device(output: false)] as [AudioEndpoint?] {
            let router = AudioDeviceRouter(read: { _ in snapshot }, current: { _ in 1 }, write: { _, _ in XCTFail("Must not write") })
            XCTAssertThrowsError(try router.select(device(), direction: .output) { XCTFail("Must not tear down working audio") })
        }
    }
    func testSelectingCurrentDeviceDoesNotInterruptPlayback() throws {
        let router = AudioDeviceRouter(read: { _ in self.device() }, current: { _ in 42 }, write: { _, _ in XCTFail("Must not write") })
        try router.select(device(), direction: .output) { XCTFail("Must not stop playback") }
    }
    func testRoutesAreReleasedBeforeChangingDevice() throws {
        var events: [String] = []
        let router = AudioDeviceRouter(read: { _ in self.device() }, current: { _ in 1 }, write: { direction, id in
            XCTAssertEqual(direction, .output); XCTAssertEqual(id, 42); events.append("change")
        })
        try router.select(device(), direction: .output) { events.append("release") }
        XCTAssertEqual(events, ["release", "change"])
    }
    func testInputSelectionNeverWritesOutput() throws {
        let router = AudioDeviceRouter(read: { _ in self.device(output: false) }, current: { _ in 1 }, write: { direction, _ in
            XCTAssertEqual(direction.selector, kAudioHardwarePropertyDefaultInputDevice)
        })
        try router.select(device(output: false), direction: .input) {}
    }
    func testWriteFailureIsReported() {
        let router = AudioDeviceRouter(read: { _ in self.device() }, current: { _ in 1 }, write: { _, _ in throw AudioFailure("Disconnected") })
        XCTAssertThrowsError(try router.select(device(), direction: .output) {}) { XCTAssertEqual($0.localizedDescription, "Disconnected") }
    }
    func testVolumeIndicatorStates() {
        func indicator(_ volume: Float, _ muted: Bool = false) -> VolumeIndicator {
            .init(volume: volume, muted: muted, available: true, adjustable: true)
        }
        XCTAssertEqual(indicator(0).symbol, "speaker.slash.fill")
        XCTAssertEqual(indicator(1, true).symbol, "speaker.slash.fill")
        XCTAssertEqual(indicator(0.2).symbol, "speaker.wave.1.fill")
        XCTAssertEqual(indicator(0.5).symbol, "speaker.wave.2.fill")
        XCTAssertEqual(indicator(1).symbol, "speaker.wave.3.fill")
        XCTAssertEqual(indicator(0.5).description, "50%")
        XCTAssertEqual(VolumeIndicator(volume: 0, muted: false, available: true, adjustable: false).description, "Device-controlled volume")
        XCTAssertEqual(VolumeIndicator(volume: 1, muted: false, available: false, adjustable: false).description, "No audio output")
    }
}
