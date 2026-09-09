import SwiftUI
import ServiceManagement

struct MixerView: View {
    @ObservedObject var model: MixerModel
    @AppStorage("OnboardingComplete") private var onboardingComplete = false
    @State private var showingDevices = false
    private let accent = Color(red: 0.12, green: 0.68, blue: 0.55)
    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 12) {
                masterCard
                if !onboardingComplete {
                    onboardingCard.frame(maxHeight: .infinity)
                } else {
                Picker("Mixer section", selection: $showingDevices) {
                    Text("Applications").tag(false)
                    Text("Devices").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                if showingDevices {
                    DevicesView(model: model, catalog: model.devices)
                } else {
                appsHeader
                if model.apps.isEmpty {
                    emptyState("No apps yet", detail: "Open an app to set its volume.")
                } else if model.visibleApps.isEmpty {
                    emptyState(model.search.isEmpty ? "Nothing playing right now" : "No matching apps", detail: model.search.isEmpty ? "Switch to All apps to set levels ahead of time." : "Try another app name or process ID.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.visibleApps) { app in
                                appRow(app)
                                if app.id != model.visibleApps.last?.id { Divider().padding(.leading, 48) }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(maxHeight: .infinity)
                    .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                }
                }
                }
                if let notice = model.notice {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(notice).font(.caption)
                        Spacer(minLength: 0)
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
            footer
        }
        .frame(width: 390, height: 630)
        .tint(accent)
        .background(.regularMaterial)
    }
    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your sound, in three steps").font(.system(size: 13, weight: .semibold))
            Text("1. Play audio in an app.\n2. Open the mixer and adjust its app slider.\n3. Allow System Audio Recording if macOS asks.")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            Text("Audio stays on your Mac. Switch Mixer off anytime to restore normal playback.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Button("Audio permission…") { model.openAudioPrivacy() }.buttonStyle(.link)
                Spacer()
                Button("Open mixer") { onboardingComplete = true }.buttonStyle(.borderedProminent).controlSize(.small)
            }.font(.system(size: 11))
        }
        .padding(12)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("VolumeBar").font(.system(size: 19, weight: .semibold, design: .rounded))
                Text("A little balance for your Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Restore all app volumes") { model.restoreAll() }
                Button("Retry audio connections") { model.retry() }
                Toggle("Show background processes", isOn: $model.includeBackground)
                Divider()
                Button("Sound settings…") { model.openSoundSettings() }
                Button("Audio recording permission…") { model.openAudioPrivacy() }
                Button(SMAppService.mainApp.status == .enabled ? "Disable launch at login" : "Launch at login") {
                    do {
                        if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                        else { try SMAppService.mainApp.register() }
                    } catch { model.notice = error.localizedDescription }
                }
                Divider()
                Button("Show setup tips") { onboardingComplete = false }
                Button("About VolumeBar") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "VolumeBar", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development", .credits: NSAttributedString(string: "Individual app volume for macOS 14.4 and later.\nAudio stays on your Mac and is never recorded to disk.")])
                }
                Button("Quit VolumeBar") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 19)).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("VolumeBar settings")
        }
        .padding(18)
    }
    private var masterCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "hifispeaker.fill").foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Master volume").font(.system(size: 13, weight: .semibold))
                    Button {
                        onboardingComplete = true
                        showingDevices = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(model.output?.name ?? "Choose an output").lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }.font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(accent)
                        .accessibilityLabel("Choose sound output")
                }
                Spacer()
                Text(model.canSetMaster ? "\(Int((model.masterVolume * 100).rounded()))%" : "Fixed")
                    .font(.system(size: 21, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(model.masterMuted ? .secondary : .primary)
            }
            HStack(spacing: 12) {
                Button { model.toggleMasterMute() } label: {
                    Image(systemName: model.masterMuted || model.masterVolume < 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 22)
                }
                .buttonStyle(.plain)
                .disabled(!model.canSetMaster)
                .accessibilityLabel(model.masterMuted ? "Unmute master volume" : "Mute master volume")
                Slider(value: Binding(get: { model.masterVolume }, set: model.setMaster), in: 0...1)
                    .disabled(!model.canSetMaster)
                    .accessibilityLabel("Master volume")
                    .accessibilityValue("\(Int((model.masterVolume * 100).rounded())) percent")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).font(.system(size: 12))
            }
            if !model.canSetMaster {
                Text("Use your output device’s own volume controls.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.12), lineWidth: 1))
    }
    private var appsHeader: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Applications").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.playingCount) playing").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find an app or process", text: $model.search)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .accessibilityLabel("Find an app or process")
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            Picker("Show applications", selection: $model.onlyPlaying) {
                Text("All apps").tag(false)
                Text("Playing").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
    private func appRow(_ app: MixerApp) -> some View {
        let level = model.level(app.id)
        let active = model.activeIDs.contains(app.id)
        let error = model.errors[app.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if let icon = app.icon { Image(nsImage: icon).resizable() }
                    else { Image(systemName: "waveform").resizable().scaledToFit().padding(5).foregroundStyle(.secondary) }
                }.frame(width: 30, height: 30).padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            .help(app.clients.isEmpty ? app.name : "\(app.name) · PID \(app.pids)")
                        if app.running { Circle().fill(accent).frame(width: 5, height: 5).accessibilityLabel("Playing") }
                        Spacer(minLength: 3)
                        Text("\(Int((level * 100).rounded()))%")
                            .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    HStack(spacing: 8) {
                        Button { model.toggleMute(app.id) } label: {
                            Image(systemName: level < 0.001 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                                .foregroundStyle(level < 0.001 ? accent : .secondary)
                                .frame(width: 15, height: 18)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(level < 0.001 ? "Unmute" : "Mute") \(app.name)")
                        Slider(value: Binding(get: { model.level(app.id) }, set: { model.setLevel(app.id, $0) }), in: 0...1)
                            .controlSize(.small)
                            .accessibilityLabel("\(app.name) volume")
                            .accessibilityValue("\(Int(level * 100)) percent")
                    }
                    if error != nil || level < 0.999 {
                        HStack(spacing: 4) {
                            if error != nil { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                            Text(error != nil ? "Connection needs attention" : !model.enabled ? "Saved · mixer bypassed" : active ? (level < 0.001 ? "Muted" : "Custom level") : app.running ? "Waiting for audio access…" : "Applies when audio starts")
                                .foregroundStyle(error != nil ? Color.orange : Color.secondary)
                            Spacer()
                            if error != nil { Button("Retry") { model.retry() }.buttonStyle(.plain).foregroundStyle(accent) }
                        }.font(.system(size: 10)).help(error ?? "Volume is remembered for this app.")
                    }
                }
            }
        }
        .padding(.vertical, 13)
        .contextMenu {
            Button("Reset to 100%") { model.setLevel(app.id, 1) }
            if !app.clients.isEmpty { Text("Process IDs: \(app.pids)") }
            if let error { Text(error) }
        }
    }
    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(accent.opacity(0.7))
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
    }
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Circle().fill(!model.enabled ? Color.secondary : model.errors.isEmpty ? accent : .orange).frame(width: 6, height: 6)
                Text(model.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Mixer", isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                    .help("Bypass to immediately restore normal app audio. Your levels stay saved.")
                    .accessibilityLabel("Enable app volume mixer")
            }.padding(.horizontal, 18).padding(.vertical, 12)
        }
    }
}
