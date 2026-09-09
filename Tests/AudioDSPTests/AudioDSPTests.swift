import XCTest
import CoreAudio
@testable import AudioDSP

final class AudioDSPTests: XCTestCase {
    private func render(_ state: OpaquePointer, input: [Float], channels: UInt32 = 2) -> [Float] {
        var samples = input
        var output = [Float](repeating: 99, count: input.count)
        samples.withUnsafeMutableBytes { src in
            output.withUnsafeMutableBytes { dst in
                var inputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(src.count), mData: src.baseAddress))
                var outputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(dst.count), mData: dst.baseAddress))
                var timestamp = AudioTimeStamp()
                XCTAssertEqual(VBRenderCallback(0, &timestamp, &inputList, &timestamp, &outputList, &timestamp, UnsafeMutableRawPointer(state)), 0)
            }
        }
        return output
    }
    func testExactAttenuationAndStereoSeparation() {
        let state = VBRenderCreate(0.25, 48000, 2)!
        defer { VBRenderDestroy(state) }
        let output = render(state, input: [0.8, -0.4, -0.2, 0.6])
        for (actual, expected) in zip(output, [Float(0.2), -0.1, -0.05, 0.15]) { XCTAssertEqual(actual, expected, accuracy: 0.000001) }
        let stats = VBRenderGetStats(state)
        XCTAssertEqual(stats.callbacks, 1)
        XCTAssertEqual(stats.invalidBuffers, 0)
        XCTAssertEqual(stats.outputPeak, 0.2, accuracy: 0.000001)
    }
    func testMuteRampsToSilenceWithoutClicks() {
        let state = VBRenderCreate(1, 48000, 2)!
        defer { VBRenderDestroy(state) }
        VBRenderSetGain(state, 0)
        let output = render(state, input: [Float](repeating: 1, count: 1200))
        XCTAssertGreaterThan(output[0], 0.99)
        XCTAssertEqual(output[1000], 0, accuracy: 0.00001)
        for frame in 1..<600 {
            XCTAssertLessThanOrEqual(abs(output[frame * 2] - output[(frame - 1) * 2]), 0.0021)
            XCTAssertEqual(output[frame * 2], output[frame * 2 + 1])
        }
    }
    func testInvalidSamplesAndGainNeverEscapeBounds() {
        let state = VBRenderCreate(8, 48000, 1)!
        defer { VBRenderDestroy(state) }
        let output = render(state, input: [.nan, .infinity, -.infinity, 2, -2], channels: 1)
        XCTAssertEqual(output, [0, 0, 0, 1, -1])
        VBRenderSetGain(state, -.infinity)
        XCTAssertEqual(VBRenderGetStats(state).gain, 1)
        VBRenderSetGain(state, -1)
        XCTAssertEqual(VBRenderGetStats(state).gain, 0)
    }
    func testInvalidLayoutIsSilencedAndReported() {
        let state = VBRenderCreate(1, 48000, 2)!
        defer { VBRenderDestroy(state) }
        XCTAssertEqual(render(state, input: [0.4, 0.3], channels: 1), [0, 0])
        XCTAssertEqual(VBRenderGetStats(state).invalidBuffers, 1)
    }
    func testPlanarInputToInterleavedOutput() {
        let state = VBRenderCreate(0.5, 48000, 2)!
        defer { VBRenderDestroy(state) }
        let inputList = AudioBufferList.allocate(maximumBuffers: 2)
        defer { inputList.unsafeMutablePointer.deallocate() }
        var left: [Float] = [0.2, 0.4]
        var right: [Float] = [-0.6, -0.8]
        var output = [Float](repeating: 0, count: 4)
        left.withUnsafeMutableBytes { l in
            right.withUnsafeMutableBytes { r in
                output.withUnsafeMutableBytes { out in
                    inputList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
                    inputList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
                    var outputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(out.count), mData: out.baseAddress))
                    var t = AudioTimeStamp()
                    _ = VBRenderCallback(0, &t, inputList.unsafePointer, &t, &outputList, &t, UnsafeMutableRawPointer(state))
                }
            }
        }
        XCTAssertEqual(output, [0.1, -0.3, 0.2, -0.4])
    }
    func testRejectsUnsupportedFormatsAtCreation() {
        XCTAssertNil(VBRenderCreate(1, 0, 2))
        XCTAssertNil(VBRenderCreate(1, 48000, 8))
    }
}
