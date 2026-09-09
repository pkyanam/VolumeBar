import AppKit
import Combine
import CoreAudio

struct MixerApp: Identifiable, Equatable {
    static func == (lhs: MixerApp, rhs: MixerApp) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.clients == rhs.clients && lhs.isBackground == rhs.isBackground
    }
    let id: String
    var name: String
    var iconURL: URL?
    var clients: [AudioClient]
    var isBackground = false
    var running: Bool { clients.contains { $0.running } }
    var processIDs: [AudioObjectID] { clients.map(\.id).sorted() }
    var pids: String { clients.map { String($0.pid) }.joined(separator: ", ") }
}

@MainActor
final class MixerModel: ObservableObject {
    let devices = AudioDeviceCatalog()
    @Published var favoriteOutputs: Set<String> = []
    private var router = AudioDeviceRouter()
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
    private struct ClientOwner {
        let pid: pid_t
        let id: String
        let name: String
        let url: URL?
    }
    private var ownerCache: [AudioObjectID: ClientOwner] = [:]
    private(set) var panelVisible = false
    private var sessions: [String: ProcessMixer] = [:]
    private var previousLevels: [String: Float] = [:]
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private var masterBeforeMute: Float = 0.5
    var isTesting = false

    init(defaults: UserDefaults = .standard, testing: Bool = false) {
        self.defaults = defaults
        isTesting = testing
        favoriteOutputs = Set(defaults.stringArray(forKey: "FavoriteOutputs") ?? [])
        devices.onChange = { [weak self] in self?.refresh() }
        if let saved = defaults.dictionary(forKey: "AppVolumes") as? [String: NSNumber] {
            levels = saved.mapValues { min(1, max(0, $0.floatValue)) }
        }
        enabled = defaults.object(forKey: "MixerEnabled") as? Bool ?? true
        refresh()
        updatePolling()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = true; self?.stopAll(); self?.updatePolling() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = false; self?.errors = [:]; self?.devices.refresh(); self?.refresh(); self?.updatePolling() }
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
        updatePolling()
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
        if value { refresh() } else { stopAll() }
        updatePolling()
        releaseIdleMetadata()
    }
    func restoreAll() {
        stopAll()
        levels = [:]
        previousLevels = [:]
        errors = [:]
        defaults.removeObject(forKey: "AppVolumes")
        updatePolling()
        releaseIdleMetadata()
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
    func toggleFavorite(_ device: AudioEndpoint) {
        if favoriteOutputs.contains(device.uid) { favoriteOutputs.remove(device.uid) }
        else { favoriteOutputs.insert(device.uid) }
        defaults.set(favoriteOutputs.sorted(), forKey: "FavoriteOutputs")
    }
    func selectDevice(_ device: AudioEndpoint, direction: AudioDirection) {
        guard !isTesting else { return }
        do {
            try router.select(device, direction: direction) { self.stopAll() }
            errors = [:]
            notice = nil
        } catch { notice = error.localizedDescription }
        devices.refresh()
        refresh()
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
        if needsAppDiscovery {
            let discovered = discoverApps()
            if apps != discovered { apps = discovered }
        } else { releaseIdleMetadata() }
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
        devices.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        stopAll()
    }
    private var needsAppDiscovery: Bool {
        ResourcePolicy.needsPolling(panelVisible: panelVisible, enabled: enabled, levels: levels, sleeping: sleeping, testing: isTesting)
    }
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        if visible { refresh() }
        else { iconCache.removeAll(keepingCapacity: false); releaseIdleMetadata() }
        updatePolling()
    }
    private func updatePolling() {
        if !needsAppDiscovery { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { autoreleasepool { self?.refresh() } }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func releaseIdleMetadata() {
        guard !panelVisible, !needsAppDiscovery else { return }
        if !apps.isEmpty { apps = [] }
        ownerCache.removeAll(keepingCapacity: false)
        iconCache.removeAll(keepingCapacity: false)
    }
    // Only visible table cells request icons. Keep bounded, flattened 64px bitmaps,
    // not the original multi-resolution icon representations or bundle objects.
    func icon(for app: MixerApp) -> NSImage? {
        guard panelVisible, let url = app.iconURL else { return nil }
        if let cached = iconCache[app.id] { return cached }
        return autoreleasepool {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: NSSize(width: 32, height: 32))
            image.addRepresentation(rep)
            if iconCache.count >= 32 { iconCache.removeAll(keepingCapacity: true) }
            iconCache[app.id] = image
            return image
        }
    }
    private func discoverApps() -> [MixerApp] {
        var groups: [String: MixerApp] = [:]
        if panelVisible {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
                let id = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
                groups[id] = MixerApp(id: id, name: app.localizedName ?? "App \(app.processIdentifier)", iconURL: app.bundleURL, clients: [])
            }
        }
        let clients = AudioClient.all()
        let liveIDs = Set(clients.map(\.id))
        ownerCache = ownerCache.filter { liveIDs.contains($0.key) }
        for client in clients {
            let owner: ClientOwner
            if let cached = ownerCache[client.id], cached.pid == client.pid { owner = cached }
            else {
                let runningApp = NSRunningApplication(processIdentifier: client.pid)
                var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                let length = proc_pidpath(client.pid, &buffer, UInt32(buffer.count))
                let path = length > 0 ? String(cString: buffer) : ""
                let url = path.range(of: ".app/").map { URL(fileURLWithPath: String(path[..<$0.lowerBound]) + ".app") }
                let bundle = url.flatMap(Bundle.init(url:))
                let id = bundle?.bundleIdentifier ?? runningApp?.bundleIdentifier ?? (client.bundleID.isEmpty ? "pid:\(client.pid)" : client.bundleID)
                let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? runningApp?.localizedName ?? (path.isEmpty ? client.bundleID : URL(fileURLWithPath: path).lastPathComponent)
                owner = ClientOwner(pid: client.pid, id: id, name: name.isEmpty ? "Process \(client.pid)" : name, url: url)
                ownerCache[client.id] = owner
            }
            if groups[owner.id] == nil {
                groups[owner.id] = MixerApp(id: owner.id, name: owner.name, iconURL: owner.url, clients: [], isBackground: owner.url == nil)
            }
            groups[owner.id]?.clients.append(client)
        }
        return groups.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
