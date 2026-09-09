import SwiftUI

struct DevicesView: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var catalog: AudioDeviceCatalog
    private let accent = Color(red: 0.12, green: 0.68, blue: 0.55)
    private var sortedOutputs: [AudioEndpoint] {
        catalog.outputs.sorted {
            let first = model.favoriteOutputs.contains($0.uid), second = model.favoriteOutputs.contains($1.uid)
            return first != second ? first : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Sound output").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(catalog.outputs.count) connected").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(sortedOutputs) { device in
                        HStack(spacing: 8) {
                            Button { model.selectDevice(device, direction: .output) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: device.symbol).font(.system(size: 20)).foregroundStyle(accent).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(device.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(device.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 2)
                                    if model.output?.uid == device.uid {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                                    }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Use \(device.name) for sound output")
                                .accessibilityValue(model.output?.uid == device.uid ? "Selected" : "Not selected")
                            Button { model.toggleFavorite(device) } label: {
                                Image(systemName: model.favoriteOutputs.contains(device.uid) ? "star.fill" : "star")
                                    .foregroundStyle(model.favoriteOutputs.contains(device.uid) ? accent : .secondary)
                                    .frame(width: 24, height: 30)
                            }.buttonStyle(.plain)
                                .accessibilityLabel("\(model.favoriteOutputs.contains(device.uid) ? "Unfavorite" : "Favorite") \(device.name)")
                        }.padding(12)
                        if device.id != sortedOutputs.last?.id { Divider().padding(.leading, 50) }
                    }
                    if catalog.outputs.isEmpty {
                        Text("Connect headphones, speakers, or an audio interface to choose an output.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
                    }
                }.background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Microphone", systemImage: "mic.fill").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Menu {
                            ForEach(catalog.inputs) { device in
                                Button {
                                    model.selectDevice(device, direction: .input)
                                } label: {
                                    if device.id == catalog.inputID { Label(device.name, systemImage: "checkmark") }
                                    else { Text(device.name) }
                                }
                            }
                            if catalog.inputs.isEmpty { Text("No connected microphones") }
                        } label: {
                            Text(catalog.input?.name ?? "Unavailable").font(.system(size: 11)).lineLimit(1)
                        }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Choose microphone")
                    }
                    Text("Changes the system input. Apps with their own device selection may keep using it.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if catalog.outputs.contains(where: { $0.id == model.output?.id && $0.isWireless }) {
                        Text("Using a Bluetooth microphone can reduce playback quality. Choose your Mac’s microphone here to keep the headset for listening.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if let builtIn = catalog.inputs.first(where: { $0.kind == "Built-in" }), builtIn.id != catalog.inputID {
                            Button("Use Mac microphone") { model.selectDevice(builtIn, direction: .input) }
                                .controlSize(.small)
                        }
                    }
                }.padding(12).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                Text("Favorites stay at the top. Selecting an output keeps that device’s current volume. Choose your microphone separately.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.vertical, 2)
        }
    }
}
