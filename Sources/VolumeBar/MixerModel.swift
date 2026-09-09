import AppKit
import Combine
import CoreAudio

struct MixerApp: Identifiable, Equatable {
    static func == (lhs: MixerApp, rhs: MixerApp) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.clients == rhs.clients && lhs.isBackground == rhs.isBackground
    }
    let id: String
    var name: String
    var icon: NSImage?
    var clients: [AudioClient]
    var isBackground = false
    var running: Bool { clients.contains { $0.running } }
    var processIDs: [AudioObjectID] { clients.map(\.id).sorted() }
    var pids: String { clients.map { String($0.pid) }.joined(separator: ", ") }
}

@MainActor
final class MixerModel: ObservableObject {
    @Published var apps: [MixerApp] = []
    @Published var output: OutputDevice?
    @Published var masterVolume: Float = 1
    @Published var masterMuted = false
    @Published var canSetMaster = false
    @Published var enabled = true
    @Published var search = ""
    @Published var onlyPlaying = false
    @Published var includeBackground = false
    @Published var levels: [String: Float] = [:]
    @Published var activeIDs: Set<String> = []
    @Published var errors: [String: String] = [:]
    @Published var notice: String?
    private var iconCache: [String: NSImage] = [:]
    private var bundleCache: [URL: Bundle] = [:]
    private var sessions: [String: ProcessMixer] = [:]
    private var previousLevels: [String: Float] = [:]
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private var masterBeforeMute: Float = 0.5
    var isTesting = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.dictionary(forKey: "AppVolumes") as? [String: NSNumber] {
            levels = saved.mapValues { min(1, max(0, $0.floatValue)) }
        }
        enabled = defaults.object(forKey: "MixerEnabled") as? Bool ?? true
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = true; self?.stopAll() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = false; self?.errors = [:]; self?.refresh() }
        })
    }
    var visibleApps: [MixerApp] {
        apps.filter { (!$0.isBackground || includeBackground || !search.isEmpty) && (!onlyPlaying || $0.running) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.pids.contains(search)) }
    }
    var adjustedCount: Int { apps.filter { level($0.id) < 0.999 }.count }
    var playingCount: Int { apps.filter { $0.running && (!$0.isBackground || includeBackground) }.count }
    var statusText: String {
        if !enabled { return "Mixer bypassed" }
        if !errors.isEmpty { return "Some apps need attention" }
        return activeIDs.isEmpty ? (adjustedCount == 0 ? "All apps at original volume" : "Waiting for app audio") : "Mixing \(activeIDs.count) \(activeIDs.count == 1 ? "app" : "apps")"
    }
    func level(_ id: String) -> Float { levels[id] ?? 1 }
    func setLevel(_ id: String, _ volume: Float) {
        let value = min(1, max(0, volume))
        levels[id] = value
        errors[id] = nil
        sessions[id]?.setGain(value)
        defaults.set(levels, forKey: "AppVolumes")
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    func toggleMute(_ id: String) {
        if level(id) > 0.001 { previousLevels[id] = level(id); setLevel(id, 0) }
        else { setLevel(id, previousLevels[id] ?? 1) }
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "MixerEnabled")
        errors = [:]
        if value { reconcile() } else { stopAll() }
    }
    func restoreAll() {
        stopAll()
        levels = [:]
        previousLevels = [:]
        errors = [:]
        defaults.removeObject(forKey: "AppVolumes")
    }
    func retry() { errors = [:]; notice = nil; refresh() }
    func setMaster(_ volume: Float) {
        guard let output else { return }
        do {
            try output.setVolume(volume)
            if masterMuted && volume > 0 && HAL.writable(output.id, kAudioDevicePropertyMute) { try output.setMute(false) }
            masterVolume = volume
            masterMuted = output.muted
        } catch { notice = error.localizedDescription }
    }
    func toggleMasterMute() {
        guard let output else { return }
        do {
            if HAL.writable(output.id, kAudioDevicePropertyMute) {
                try output.setMute(!masterMuted)
                masterMuted = output.muted
            } else if masterVolume > 0 {
                masterBeforeMute = masterVolume; setMaster(0)
            } else { setMaster(masterBeforeMute) }
        } catch { notice = error.localizedDescription }
    }
    func openAudioPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    func openSoundSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }
    func refresh() {
        guard !sleeping, !isTesting else { return }
        let currentOutput = OutputDevice.current()
        if currentOutput != output {
            stopAll()
            output = currentOutput
            errors = [:]
        }
        if let output {
            let volume = output.volume
            if canSetMaster != (volume != nil) { canSetMaster = volume != nil }
            if masterVolume != (volume ?? 1) { masterVolume = volume ?? 1 }
            let muted = output.muted
            if masterMuted != muted { masterMuted = muted }
        } else if canSetMaster { canSetMaster = false }
        let discovered = discoverApps()
        if apps != discovered { apps = discovered }
        reconcile()
        for (id, session) in sessions {
            do { try session.activateWhenReady() }
            catch {
                errors[id] = error.localizedDescription
                session.stop(); sessions[id] = nil
                continue
            }
            let stats = session.stats
            if stats.invalidBuffers > 0 || (Date().timeIntervalSince(session.startedAt) > 5 && stats.callbacks == 0 && apps.first(where: { $0.id == id })?.running == true) {
                errors[id] = "Audio wasn't available. Allow VolumeBar in System Settings → Privacy & Security → Screen & System Audio Recording, then retry."
                session.stop()
                sessions[id] = nil
            }
        }
        updateActiveIDs()
    }
    private func reconcile() {
        guard enabled, !sleeping, !isTesting, let output else { stopAll(); return }
        let desired = apps.filter { level($0.id) < 0.999 && !$0.clients.isEmpty }
        let desiredIDs = Set(desired.map(\.id))
        for id in Array(sessions.keys) where !desiredIDs.contains(id) { sessions.removeValue(forKey: id)?.stop() }
        for app in desired {
            // Only control streams using the current default output. Other destinations remain untouched.
            let ids = app.clients.filter { $0.outputDevices.contains(output.id) || $0.outputDevices.isEmpty }.map(\.id).sorted()
            guard !ids.isEmpty else { sessions.removeValue(forKey: app.id)?.stop(); continue }
            if let session = sessions[app.id], session.processIDs != ids {
                session.stop(); sessions[app.id] = nil; errors[app.id] = nil
            }
            guard sessions[app.id] == nil, errors[app.id] == nil else { continue }
            // Don't initialize audio for an idle client until it actually plays.
            guard app.running else { continue }
            guard sessions.count < 24 else { errors[app.id] = "The prototype supports up to 24 adjusted apps at once."; continue }
            do { sessions[app.id] = try ProcessMixer(processIDs: ids, device: output, gain: level(app.id), name: app.name) }
            catch { errors[app.id] = error.localizedDescription }
        }
        updateActiveIDs()
    }
    private func updateActiveIDs() {
        let current = Set(sessions.filter { $0.value.isControlling }.keys)
        if current != activeIDs { activeIDs = current }
    }
    func stopAll() {
        pending?.cancel()
        for session in sessions.values { session.stop() }
        sessions = [:]
        if !activeIDs.isEmpty { activeIDs = [] }
    }
    func shutdown() {
        timer?.invalidate(); timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        stopAll()
    }
    private func cachedIcon(_ id: String, app: NSRunningApplication?, url: URL?) -> NSImage? {
        if let icon = iconCache[id] { return icon }
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? app?.icon
        iconCache[id] = icon
        return icon
    }
    private func discoverApps() -> [MixerApp] {
        var groups: [String: MixerApp] = [:]
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            let id = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
            groups[id] = MixerApp(id: id, name: app.localizedName ?? "App \(app.processIdentifier)", icon: cachedIcon(id, app: app, url: app.bundleURL), clients: [])
        }
        for client in AudioClient.all() {
            let runningApp = NSRunningApplication(processIdentifier: client.pid)
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(client.pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = length > 0 ? String(cString: pathBuffer) : ""
            var ownerURL: URL?
            if let appRange = path.range(of: ".app/") {
                ownerURL = URL(fileURLWithPath: String(path[..<appRange.lowerBound]) + ".app")
            }
            let ownerBundle = ownerURL.flatMap { url -> Bundle? in
                if let cached = bundleCache[url] { return cached }
                let bundle = Bundle(url: url)
                bundleCache[url] = bundle
                return bundle
            }
            let id = ownerBundle?.bundleIdentifier ?? runningApp?.bundleIdentifier ?? (client.bundleID.isEmpty ? "pid:\(client.pid)" : client.bundleID)
            if groups[id] == nil {
                let name = ownerBundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ownerBundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? runningApp?.localizedName ?? (path.isEmpty ? client.bundleID : URL(fileURLWithPath: path).lastPathComponent)
                groups[id] = MixerApp(id: id, name: name.isEmpty ? "Process \(client.pid)" : name, icon: cachedIcon(id, app: runningApp, url: ownerURL), clients: [], isBackground: ownerURL == nil)
            }
            groups[id]?.clients.append(client)
        }
        return groups.values.sorted {
            // Stable alphabetical rows: sliders must not move under the pointer when playback starts.
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
