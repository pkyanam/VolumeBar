import AppKit
import Combine
import ServiceManagement

private let mixerAccent = NSColor(calibratedRed: 0.12, green: 0.68, blue: 0.55, alpha: 1)

private final class PanelSurface: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
}
private final class ActionButton: NSButton {
    var perform: (() -> Void)?
    init(_ title: String = "", action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        perform = action
        target = self; self.action = #selector(run)
        bezelStyle = .smallSquare; controlSize = .small; font = .systemFont(ofSize: 11)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { perform?() }
}
private final class ActionSlider: NSSlider {
    var perform: ((Float) -> Void)?
    init() {
        super.init(frame: .zero)
        minValue = 0; maxValue = 1; isContinuous = true
        target = self; action = #selector(run); controlSize = .small
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { perform?(floatValue) }
}
private final class ActionMenuItem: NSMenuItem {
    var perform: (() -> Void)?
    init(_ title: String, action: @escaping () -> Void) {
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        perform = action; target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { perform?() }
}
private func text(_ value: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = secondary ? .secondaryLabelColor : .labelColor
    field.lineBreakMode = .byTruncatingTail
    return field
}
private func symbol(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }

/// Constructed only when opened. AppKit table cells are reused; closing releases this controller.
@MainActor
final class MixerPanelController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let model: MixerModel
    private var subscriptions: Set<AnyCancellable> = []
    private var updateQueued = false
    private var apps: [MixerApp] = []
    private var outputs: [AudioEndpoint] = []
    private var inputs: [AudioEndpoint] = []
    private var devicesSelected = false
    private var optionsSelected = false
    private var optionControls: [NSView] = []
    private var backgroundOption: ActionButton?
    private var loginOption: ActionButton?
    private var onboarding = !UserDefaults.standard.bool(forKey: "OnboardingComplete")
    private let master = ActionSlider()
    private let masterValue = text("", size: 21, weight: .medium)
    private let outputButton = ActionButton(action: {})
    private let masterMute = ActionButton(action: {})
    private let status = text("", size: 11, secondary: true)
    private let notice = text("", size: 10, secondary: true)
    private let bypass = ActionButton("Mixer", action: {})
    private let section = NSSegmentedControl(labels: ["Applications", "Devices", "Options"], trackingMode: .selectOne, target: nil, action: nil)
    private let filter = NSSegmentedControl(labels: ["All apps", "Playing"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let count = text("", size: 11, secondary: true)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = text("", size: 12, secondary: true)
    private let microphoneLabel = text("Microphone", size: 12, weight: .semibold)
    private let microphone = NSPopUpButton(frame: .zero, pullsDown: false)
    private let inputTip = text("", size: 10, secondary: true)
    private let macMicrophone = ActionButton("Use Mac microphone", action: {})
    private var appControls: [NSView] = []
    private var deviceControls: [NSView] = []
    private var setupControls: [NSView] = []

    init(model: MixerModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let root = PanelSurface(frame: NSRect(x: 0, y: 0, width: 390, height: 630))
        root.wantsLayer = true
        view = root
        let logo = NSImageView(image: symbol("speaker.wave.2.fill") ?? NSImage())
        logo.contentTintColor = mixerAccent
        place(logo, 22, 24, 30, 30)
        place(text("VolumeBar", size: 19, weight: .semibold), 65, 20, 220, 25)
        place(text("A little balance for your Mac.", size: 11, secondary: true), 65, 47, 230, 16)
        let card = NSView(); card.wantsLayer = true
        card.layer?.backgroundColor = mixerAccent.withAlphaComponent(0.08).cgColor
        card.layer?.cornerRadius = 14
        place(card, 18, 78, 354, 112)
        place(text("Master volume", size: 13, weight: .semibold), 34, 94, 230, 18)
        outputButton.isBordered = false; outputButton.contentTintColor = mixerAccent
        outputButton.alignment = .left; outputButton.lineBreakMode = .byTruncatingTail
        outputButton.setAccessibilityLabel("Choose sound output")
        outputButton.perform = { [weak self] in self?.openDevices() }
        place(outputButton, 30, 115, 250, 20)
        masterValue.alignment = .right
        place(masterValue, 287, 99, 67, 27)
        masterMute.isBordered = false
        masterMute.perform = { [weak model] in model?.toggleMasterMute() }
        place(masterMute, 31, 145, 27, 24)
        master.setAccessibilityLabel("Master volume")
        master.perform = { [weak model] in model?.setMaster($0) }
        place(master, 70, 144, 281, 25)
        section.segmentStyle = .texturedSquare
        section.selectedSegment = 0; section.target = self; section.action = #selector(changeSection)
        place(section, 18, 205, 354, 26)
        search.placeholderString = "Find an app or process"; search.delegate = self
        search.stringValue = model.search; search.setAccessibilityLabel("Find an app or process")
        place(search, 18, 247, 354, 27)
        filter.segmentStyle = .texturedSquare
        filter.selectedSegment = model.onlyPlaying ? 1 : 0; filter.target = self; filter.action = #selector(changeFilter)
        place(filter, 18, 283, 230, 24)
        count.alignment = .right
        place(count, 254, 287, 116, 17)
        appControls = [search, filter, count]
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content")); column.width = 354
        table.addTableColumn(column); table.headerView = nil
        table.delegate = self; table.dataSource = self; table.backgroundColor = .clear
        table.selectionHighlightStyle = .none; table.intercellSpacing = NSSize(width: 0, height: 1)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        place(scroll, 18, 318, 354, 229)
        empty.alignment = .center
        place(empty, 30, 350, 330, 45)
        place(microphoneLabel, 24, 443, 120, 18)
        microphone.font = .systemFont(ofSize: 11); microphone.target = self; microphone.action = #selector(changeInput)
        microphone.setAccessibilityLabel("Choose microphone")
        place(microphone, 146, 437, 223, 28)
        inputTip.maximumNumberOfLines = 3; inputTip.lineBreakMode = .byWordWrapping
        place(inputTip, 24, 475, 340, 46)
        macMicrophone.perform = { [weak self] in
            guard let self, let device = self.inputs.first(where: { $0.kind == "Built-in" }) else { return }
            self.model.selectDevice(device, direction: .input)
        }
        place(macMicrophone, 22, 521, 165, 26)
        deviceControls = [microphoneLabel, microphone, inputTip, macMicrophone]
        buildSetup()
        buildOptions()
        notice.maximumNumberOfLines = 2; notice.lineBreakMode = .byWordWrapping
        place(notice, 22, 553, 310, 32)
        let dismiss = ActionButton("×", action: { [weak model] in model?.notice = nil })
        place(dismiss, 338, 553, 27, 24)
        dismiss.setAccessibilityLabel("Dismiss notice")
        dismiss.identifier = NSUserInterfaceItemIdentifier("dismissNotice")
        let separator = NSBox(); separator.boxType = .separator
        place(separator, 0, 590, 390, 1)
        place(status, 20, 604, 260, 18)
        bypass.setButtonType(.switch); bypass.setAccessibilityLabel("Enable app volume mixer")
        bypass.perform = { [weak self] in guard let self else { return }; self.model.setEnabled(self.bypass.state == .on) }
        place(bypass, 292, 599, 82, 26)
        model.objectWillChange.sink { [weak self] in self?.queueUpdate() }.store(in: &subscriptions)
        model.devices.objectWillChange.sink { [weak self] in self?.queueUpdate() }.store(in: &subscriptions)
        update()
    }
    private func place(_ child: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        child.frame = NSRect(x: x, y: y, width: w, height: h); view.addSubview(child)
    }
    private func buildSetup() {
        let title = text("Your sound, in three steps", size: 15, weight: .semibold)
        place(title, 28, 263, 334, 24)
        let steps = text("1. Play audio in an app.\n2. Open the mixer and adjust its slider.\n3. Allow System Audio Recording if macOS asks.\n\nAudio stays on your Mac. Switch Mixer off anytime to restore normal playback.", size: 12, secondary: true)
        steps.lineBreakMode = .byWordWrapping; steps.maximumNumberOfLines = 10
        place(steps, 28, 305, 334, 135)
        let permission = ActionButton("Audio permission…", action: { [weak model] in model?.openAudioPrivacy() })
        place(permission, 25, 458, 156, 28)
        let start = ActionButton("Open mixer", action: { [weak self] in self?.finishSetup() })
        place(start, 246, 458, 117, 28)
        setupControls = [title, steps, permission, start]
    }
    private func finishSetup() {
        UserDefaults.standard.set(true, forKey: "OnboardingComplete"); onboarding = false; update(forceReload: true)
    }
    private func openDevices() { devicesSelected = true; optionsSelected = false; section.selectedSegment = 1; finishSetup() }
    @objc private func changeSection() { devicesSelected = section.selectedSegment == 1; optionsSelected = section.selectedSegment == 2; update(forceReload: true) }
    @objc private func changeFilter() { model.onlyPlaying = filter.selectedSegment == 1; update(forceReload: true) }
    func controlTextDidChange(_ notification: Notification) { model.search = search.stringValue; update(forceReload: true) }
    @objc private func changeInput() {
        let index = microphone.indexOfSelectedItem
        guard inputs.indices.contains(index) else { return }
        model.selectDevice(inputs[index], direction: .input)
    }
    private func queueUpdate() {
        guard !updateQueued else { return }
        updateQueued = true
        DispatchQueue.main.async { [weak self] in self?.updateQueued = false; self?.update() }
    }
    private func update(forceReload: Bool = false) {
        backgroundOption?.state = model.includeBackground ? .on : .off
        loginOption?.title = SMAppService.mainApp.status == .enabled ? "Disable launch at login" : "Launch at login"
        master.floatValue = model.masterVolume; master.isEnabled = model.canSetMaster
        masterValue.stringValue = model.canSetMaster ? "\(Int((model.masterVolume * 100).rounded()))%" : "Fixed"
        outputButton.title = (model.output?.name ?? "Choose an output") + " ▾"
        masterMute.image = symbol(model.masterMuted || model.masterVolume < 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        masterMute.isEnabled = model.canSetMaster
        masterMute.setAccessibilityLabel(model.masterMuted ? "Unmute master volume" : "Mute master volume")
        master.toolTip = model.canSetMaster ? masterValue.stringValue : "Use your output device’s volume controls"
        bypass.state = model.enabled ? .on : .off; status.stringValue = model.statusText
        notice.stringValue = model.notice ?? ""; notice.toolTip = model.notice
        view.subviews.first { $0.identifier?.rawValue == "dismissNotice" }?.isHidden = model.notice == nil
        section.isHidden = onboarding
        setupControls.forEach { $0.isHidden = !onboarding }
        appControls.forEach { $0.isHidden = onboarding || devicesSelected || optionsSelected }
        deviceControls.forEach { $0.isHidden = onboarding || !devicesSelected }
        optionControls.forEach { $0.isHidden = onboarding || !optionsSelected }
        scroll.isHidden = onboarding || optionsSelected
        table.rowHeight = devicesSelected ? 68 : 76
        scroll.frame = NSRect(x: 18, y: devicesSelected ? 247 : 318, width: 354, height: devicesSelected ? 179 : 229)
        let newApps = model.visibleApps
        let newOutputs = model.devices.outputs.sorted {
            let a = model.favoriteOutputs.contains($0.uid), b = model.favoriteOutputs.contains($1.uid)
            return a != b ? a : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let changed = devicesSelected ? newOutputs.map(\.uid) != outputs.map(\.uid) : newApps.map(\.id) != apps.map(\.id)
        apps = newApps; outputs = newOutputs
        count.stringValue = "\(model.playingCount) playing"
        empty.isHidden = onboarding || optionsSelected || (devicesSelected ? !outputs.isEmpty : !apps.isEmpty)
        empty.stringValue = devicesSelected ? "No connected outputs" : (model.search.isEmpty ? "No matching apps playing" : "No matching apps")
        if inputs != model.devices.inputs {
            inputs = model.devices.inputs; microphone.removeAllItems()
            microphone.addItems(withTitles: inputs.map(\.name))
        }
        microphone.isEnabled = !inputs.isEmpty
        if let index = inputs.firstIndex(where: { $0.id == model.devices.inputID }) { microphone.selectItem(at: index) }
        else { microphone.select(nil) }
        let wireless = outputs.contains { $0.id == model.output?.id && $0.isWireless }
        inputTip.stringValue = wireless
            ? "A Bluetooth microphone can reduce playback quality. Select the Mac microphone to keep headphones for listening. Apps with their own device choice may ignore the system input."
            : "Changes the system input. Apps with their own device selection may keep using it. Favorites stay first; output devices keep their own volume."
        macMicrophone.isHidden = onboarding || !devicesSelected || !wireless || !inputs.contains { $0.kind == "Built-in" && $0.id != model.devices.inputID }
        if changed || forceReload { table.reloadData() }
        else {
            let range = table.rows(in: table.visibleRect)
            if range.location != NSNotFound {
                for row in range.location..<NSMaxRange(range) where row < numberOfRows(in: table) {
                    if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MixerCell { configure(cell, row: row) }
                }
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { devicesSelected ? outputs.count : apps.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier(devicesSelected ? "device" : "app")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? MixerCell ?? MixerCell()
        cell.identifier = id; configure(cell, row: row); return cell
    }
    private func configure(_ cell: MixerCell, row: Int) {
        if devicesSelected {
            let device = outputs[row]
            cell.setDevice(device, selected: model.output?.uid == device.uid, favorite: model.favoriteOutputs.contains(device.uid),
                select: { [weak model] in model?.selectDevice(device, direction: .output) },
                favoriteAction: { [weak model] in model?.toggleFavorite(device) })
        } else {
            let app = apps[row]
            cell.setApp(app, model: model)
        }
    }
    private func buildOptions() {
        func add(_ title: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, action: @escaping () -> Void) -> ActionButton {
            let button = ActionButton(title, action: action)
            place(button, x, y, w, 28); optionControls.append(button); return button
        }
        _ = add("Restore all app volumes", 22, 247, 180) { [weak model] in model?.restoreAll() }
        _ = add("Retry audio connections", 208, 247, 164) { [weak model] in model?.retry() }
        backgroundOption = add("Show background processes", 24, 285, 336) { [weak model] in model?.includeBackground.toggle() }
        backgroundOption?.setButtonType(.switch)
        _ = add("Sound settings…", 22, 325, 165) { [weak model] in model?.openSoundSettings() }
        _ = add("Audio recording permission…", 192, 325, 180) { [weak model] in model?.openAudioPrivacy() }
        loginOption = add("Launch at login", 22, 366, 180) { [weak model] in
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch { model?.notice = error.localizedDescription }
        }
        _ = add("Show setup tips", 208, 366, 164) { [weak self] in
            UserDefaults.standard.set(false, forKey: "OnboardingComplete"); self?.onboarding = true; self?.optionsSelected = false; self?.devicesSelected = false; self?.section.selectedSegment = 0; self?.update()
        }
        _ = add("About VolumeBar", 22, 407, 180) { NSApp.orderFrontStandardAboutPanel(options: [:]) }
        _ = add("Quit VolumeBar", 208, 407, 164) { NSApp.terminate(nil) }
        let note = text("Audio stays on your Mac. Switch Mixer off to restore original app audio while keeping your saved levels.", size: 11, secondary: true)
        note.maximumNumberOfLines = 3; note.lineBreakMode = .byWordWrapping
        place(note, 26, 465, 338, 60); optionControls.append(note)
    }

}

private final class MixerCell: NSTableCellView {
    override var isFlipped: Bool { true }
    private let icon = NSImageView()
    private let name = text("", size: 12, weight: .medium)
    private let detail = text("", size: 10, secondary: true)
    private let percent = text("", size: 11, secondary: true)
    private let slider = ActionSlider()
    private let primary = ActionButton(action: {})
    private let secondary = ActionButton(action: {})
    private let separator = NSBox()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for child in [icon, name, detail, percent, slider, primary, secondary, separator] { addSubview(child) }
        primary.isBordered = false; secondary.isBordered = false
        percent.alignment = .right; separator.boxType = .separator
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setApp(_ app: MixerApp, model: MixerModel) {
        name.stringValue = app.name + (app.running ? " •" : "")
        icon.image = model.icon(for: app) ?? symbol("waveform"); icon.contentTintColor = nil
        let level = model.level(app.id)
        percent.stringValue = "\(Int((level * 100).rounded()))%"
        name.toolTip = app.clients.isEmpty ? app.name : "\(app.name) · PID \(app.pids)"
        slider.floatValue = level; slider.setAccessibilityLabel("\(app.name) volume")
        slider.perform = { [weak model] in model?.setLevel(app.id, $0) }
        primary.image = symbol(level < 0.001 ? "speaker.slash.fill" : "speaker.wave.1.fill")
        primary.setAccessibilityLabel("\(level < 0.001 ? "Unmute" : "Mute") \(app.name)")
        primary.perform = { [weak model] in model?.toggleMute(app.id) }
        let error = model.errors[app.id]
        detail.stringValue = error != nil ? "Connection needs attention" : level >= 0.999 ? "" : !model.enabled ? "Saved · mixer bypassed" : model.activeIDs.contains(app.id) ? (level < 0.001 ? "Muted" : "Custom level") : "Applies when audio starts"
        detail.toolTip = error
        secondary.title = "Retry"; secondary.image = nil
        secondary.isHidden = error == nil
        secondary.perform = { [weak model] in model?.retry() }
        slider.isHidden = false; percent.isHidden = false
        primary.title = ""; primary.frame = NSRect(x: 44, y: 31, width: 23, height: 23)
        icon.frame = NSRect(x: 4, y: 12, width: 30, height: 30)
        name.frame = NSRect(x: 44, y: 8, width: 244, height: 18)
        percent.frame = NSRect(x: 292, y: 8, width: 47, height: 18)
        slider.frame = NSRect(x: 74, y: 31, width: 264, height: 23)
        detail.frame = NSRect(x: 44, y: 55, width: 240, height: 15)
        secondary.frame = NSRect(x: 291, y: 53, width: 48, height: 19)
        separator.frame = NSRect(x: 44, y: 75, width: 295, height: 1)
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Reset to 100%", action: { [weak model] in model?.setLevel(app.id, 1) }))
        if !app.clients.isEmpty { menu.addItem(withTitle: "Process IDs: \(app.pids)", action: nil, keyEquivalent: "") }
        self.menu = menu
    }
    func setDevice(_ device: AudioEndpoint, selected: Bool, favorite: Bool, select: @escaping () -> Void, favoriteAction: @escaping () -> Void) {
        icon.image = symbol(device.symbol); icon.contentTintColor = mixerAccent
        name.stringValue = ""; detail.stringValue = device.detail
        slider.isHidden = true; percent.isHidden = true; secondary.isHidden = false
        primary.title = (selected ? "✓  " : "") + device.name; primary.image = nil
        primary.alignment = .left; primary.lineBreakMode = .byTruncatingTail
        primary.setAccessibilityLabel("Use \(device.name) for sound output")
        primary.setAccessibilityValue(selected ? "Selected" : "Not selected"); primary.perform = select
        secondary.title = ""; secondary.image = symbol(favorite ? "star.fill" : "star")
        secondary.contentTintColor = favorite ? mixerAccent : .secondaryLabelColor
        secondary.setAccessibilityLabel("\(favorite ? "Unfavorite" : "Favorite") \(device.name)")
        secondary.perform = favoriteAction
        icon.frame = NSRect(x: 7, y: 17, width: 28, height: 28)
        primary.frame = NSRect(x: 43, y: 8, width: 264, height: 25)
        detail.frame = NSRect(x: 47, y: 36, width: 270, height: 18)
        secondary.frame = NSRect(x: 315, y: 17, width: 28, height: 28)
        separator.frame = NSRect(x: 45, y: 67, width: 294, height: 1)
        menu = nil
    }
}
