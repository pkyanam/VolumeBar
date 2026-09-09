import AppKit
import AVFoundation
import AudioDSP
import CoreAudio

// Explicit opt-in diagnostics. Never reads or records another app's audio.
enum Diagnostics {
    static func printSnapshot() {
        let device = OutputDevice.current()
        let result: [String: Any] = [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "output": device.map { ["id": $0.id, "name": $0.name, "uid": $0.uid, "channels": $0.channels, "sampleRate": $0.sampleRate, "volume": $0.volume as Any] } ?? [:],
            "audioClients": AudioClient.all().map { ["id": $0.id, "pid": $0.pid, "bundleID": $0.bundleID, "running": $0.running, "devices": $0.outputDevices] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), let string = String(data: data, encoding: .utf8) { print(string) }
    }
    static func playTestTone() {
        let engine = AVAudioEngine()
        let format = engine.outputNode.inputFormat(forBus: 0)
        var phase = 0.0
        let step = 2 * Double.pi * 440 / format.sampleRate
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let sample = Float(sin(phase) * 0.003) // Quiet -50 dBFS test signal.
                phase += step
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for channel in 0..<Int(buffer.mNumberChannels) { data[frame * Int(buffer.mNumberChannels) + channel] = sample }
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            RunLoop.current.run(until: Date().addingTimeInterval(45))
            engine.stop()
        } catch { print("Test tone failed: \(error)") }
    }
    @MainActor
    static func runIntegrationTest(model: MixerModel) async {
        let reportPath: String
        if let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > index + 1 { reportPath = CommandLine.arguments[index + 1] }
        else { reportPath = NSTemporaryDirectory() + "VolumeBar-self-test.json" }
        var report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "os": ProcessInfo.processInfo.operatingSystemVersionString]
        var measurements: [[String: Any]] = []
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--test-tone"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        var mixer: ProcessMixer?
        let originalOutput = HAL.defaultOutput()
        let originalVolume = OutputDevice.current()?.volume
        do {
            guard let output = OutputDevice.current() else { throw AudioFailure("No output device") }
            report["device"] = output.name
            try child.run()
            var client: AudioClient?
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 100_000_000)
                client = AudioClient.all().first { $0.pid == child.processIdentifier && $0.running }
                if client != nil { break }
            }
            guard let client else { throw AudioFailure("Test tone did not register with Core Audio") }
            // First read is unmuted, with no replay, so permission prompts cannot silence the source.
            mixer = try ProcessMixer(processIDs: [client.id], device: output, gain: 0, name: "Self-test permission check", muteSource: false)
            var permissionReady = false
            for _ in 0..<150 {
                try await Task.sleep(nanoseconds: 200_000_000)
                if mixer!.stats.inputPeak > 0.0001 { permissionReady = true; break }
            }
            guard permissionReady else { throw AudioFailure("System audio permission not granted, or the tap received no signal. Allow VolumeBar in Privacy & Security → Screen & System Audio Recording and rerun the test.") }
            mixer?.stop(); mixer = nil
            for cycle in 0..<3 {
                mixer = try ProcessMixer(processIDs: [client.id], device: output, gain: 0.5, name: "Self-test")
                for _ in 0..<50 {
                    try await Task.sleep(nanoseconds: 20_000_000)
                    try mixer?.activateWhenReady()
                    if mixer?.isControlling == true { break }
                }
                guard mixer?.isControlling == true else { throw AudioFailure("Could not safely activate app mixing") }
                for gain: Float in [0.5, 0.25, 0, 1] {
                    mixer?.setGain(gain)
                    try await Task.sleep(nanoseconds: 350_000_000)
                    let stats = mixer!.stats
                    let ratio = stats.inputPeak > 0 ? stats.outputPeak / stats.inputPeak : -1
                    measurements.append(["cycle": cycle, "requestedGain": gain, "measuredGain": ratio, "inputPeak": stats.inputPeak, "outputPeak": stats.outputPeak, "callbacks": stats.callbacks, "invalidBuffers": stats.invalidBuffers])
                    guard stats.callbacks > 0, stats.invalidBuffers == 0, stats.inputPeak > 0.0001, abs(ratio - gain) < 0.01 else {
                        throw AudioFailure("Live audio gain verification failed at \(gain): \(ratio)")
                    }
                }
                mixer?.stop(); mixer = nil
            }
            // Verify the source is still producing normal audio after teardown.
            mixer = try ProcessMixer(processIDs: [client.id], device: output, gain: 0, name: "Self-test restore check", muteSource: false)
            try await Task.sleep(nanoseconds: 400_000_000)
            guard mixer!.stats.inputPeak > 0.0001 else { throw AudioFailure("Source audio didn't resume after teardown") }
            mixer?.stop(); mixer = nil
            guard HAL.defaultOutput() == originalOutput, OutputDevice.current()?.volume == originalVolume else { throw AudioFailure("Output settings changed during testing") }
            report["result"] = "PASS"
            report["checks"] = ["Live per-process capture", "50%, 25%, mute, and unity gain", "Three complete create/start/stop/destroy cycles", "Source resumes after teardown", "Default output and master volume unchanged"]
        } catch {
            report["result"] = "FAIL"
            report["error"] = error.localizedDescription
        }
        mixer?.stop()
        if child.isRunning { child.terminate() }
        report["measurements"] = measurements
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
        NSApp.terminate(nil)
    }
}
