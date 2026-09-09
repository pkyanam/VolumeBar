import AppKit
import SwiftUI
import Combine

@main
struct VolumeBarMain {
    static func main() {
        if CommandLine.arguments.contains("--version") {
            print("VolumeBar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
            return
        }
        if CommandLine.arguments.contains("--diagnose") { Diagnostics.printSnapshot(); return }
        if CommandLine.arguments.contains("--test-tone") { Diagnostics.playTestTone(); return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var model: MixerModel!
    private var lastVolumeLabel: String?
    private var volumeObservation: AnyCancellable?
    private var signalSources: [DispatchSourceSignal] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let testing = CommandLine.arguments.contains("--self-test")
        model = MixerModel(defaults: testing ? UserDefaults(suiteName: "com.volumebar.prototype.selftest")! : .standard)
        if testing { model.isTesting = true; model.stopAll() }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.toolTip = "VolumeBar — app volume mixer"
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        volumeObservation = Publishers.CombineLatest4(model.$masterVolume, model.$masterMuted, model.$output, model.$canSetMaster)
            .sink { [weak self] values in
                self?.updateVolumeIcon(volume: values.0, muted: values.1, output: values.2, adjustable: values.3)
            }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 390, height: 630)
        popover.contentViewController = NSHostingController(rootView: MixerView(model: model))
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
        if testing {
            Task { await Diagnostics.runIntegrationTest(model: model) }
        } else if !UserDefaults.standard.bool(forKey: "HasLaunched") || CommandLine.arguments.contains("--show") {
            UserDefaults.standard.set(true, forKey: "HasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPopover() }
        }
    }
    private func updateVolumeIcon(volume: Float, muted: Bool, output: OutputDevice?, adjustable: Bool) {
        let indicator = VolumeIndicator(volume: volume, muted: muted, available: output != nil, adjustable: adjustable)
        let label = "VolumeBar — \(indicator.description)\(output.map { " · \($0.name)" } ?? "")"
        guard label != lastVolumeLabel, let button = item.button else { return }
        lastVolumeLabel = label
        let image = NSImage(systemSymbolName: indicator.symbol, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: label)
        image?.isTemplate = true
        button.image = image
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPopover(); return true }
    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open VolumeBar", action: #selector(openMixer), keyEquivalent: "").target = self
            menu.addItem(withTitle: model.enabled ? "Bypass app mixer" : "Enable app mixer", action: #selector(toggleMixer), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit VolumeBar", action: #selector(quitApp), keyEquivalent: "q").target = self
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }
    @objc private func openMixer() { showPopover() }
    @objc private func toggleMixer() { model.setEnabled(!model.enabled) }
    @objc private func quitApp() { NSApp.terminate(nil) }
    private func showPopover() {
        guard let button = item.button else { return }
        model.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
}
