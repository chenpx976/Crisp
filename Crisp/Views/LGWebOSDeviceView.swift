import SwiftUI

struct LGWebOSDeviceView: View {
    @ObservedObject var controller: LGWebOSVolumeController
    @State private var brightness = 50.0
    @State private var dragging = false
    @State private var busy = false
    @State private var macAddress = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !controller.devicePreferences.extendedControls {
                Button("Enable OLED, HDMI and Power Controls") { controller.enableDeviceControls() }
                Text("Approve the expanded pairing request on the TV.").font(.caption).foregroundStyle(.secondary)
            } else {
                if !controller.devicePreferences.signedSettingsAccess {
                    Button("Authorize OLED Writes") { controller.enableSettingsAccess() }
                    Text("LG's signed remote profile also requests TV app and notification access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("OLED pixel brightness (TV)")
                    Spacer()
                    Text(controller.deviceState.oledBrightness.map { "\($0)%" } ?? "—")
                }
                Slider(value: $brightness, in: 0...100) { editing in
                    dragging = editing
                    if !editing { run { try await controller.setOLEDBrightness(Int(brightness.rounded())) } }
                }
                .accessibilityLabel("OLED pixel brightness (TV)")
                .disabled(busy || controller.deviceState.oledBrightness == nil || !controller.ready)
                .onChange(of: controller.deviceState.oledBrightness) { _, value in
                    if let value, !dragging { brightness = Double(value) }
                }
                Text("Changes OLED pixel brightness in the TV, separately from software dimming.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Refresh TV Controls") { run { await controller.refreshDeviceState() } }
                    .disabled(busy || !controller.ready)
                if let error = controller.deviceError {
                    Text(verbatim: error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text("HDMI Quick Switch").font(.headline)
                ForEach(controller.deviceState.inputs) { input in
                    HStack {
                        Text(verbatim: input.label)
                        Spacer()
                        Button(input.id.replacingOccurrences(of: "_", with: " ")) {
                            run { try await controller.switchTVInput(input.id) }
                        }
                        .disabled(busy || !controller.ready)
                    }
                    ShortcutRecorderRow(label: input.id, shortcut: Binding(
                        get: { controller.devicePreferences.inputShortcuts[input.id] },
                        set: { value in
                            SettingsService.shared.assignStaticShortcut(value) { shortcut in
                                controller.devicePreferences.inputShortcuts[input.id] = shortcut
                                controller.saveDevicePreferences()
                            }
                        }
                    ), leadingInset: 0)
                }
                Picker("Mac HDMI Input", selection: Binding(
                    get: { controller.devicePreferences.macInput },
                    set: { controller.devicePreferences.macInput = $0; controller.saveDevicePreferences() }
                )) {
                    Text("Choose Mac Input").tag("")
                    ForEach(controller.deviceState.inputs) { input in Text(verbatim: input.label).tag(input.id) }
                }
                HStack {
                    TextField("TV MAC address", text: $macAddress)
                    Button("Save MAC") {
                        if LGWakeOnLAN.packet(macAddress) != nil {
                            controller.devicePreferences.wakeMACs = [macAddress]
                            controller.saveDevicePreferences()
                            controller.deviceError = nil
                        } else { controller.deviceError = String(localized: "Enter a valid TV MAC address.") }
                    }
                }
                Text("Enable network wake / Turn on via Wi-Fi on the TV before using power sync.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Sync TV with Mac Sleep and Wake", isOn: preference(\.powerSync))
                    .disabled(!controller.devicePreferences.canSyncPower)
                Toggle("Switch to Mac HDMI on Wake", isOn: preference(\.switchOnWake))
                HStack {
                    Button("Wake TV") { run { try await controller.wakeTV() } }
                    Button("TV Standby") { run { try await controller.sleepTVIfOnMacInput() } }
                }
                .disabled(busy || !controller.devicePreferences.canSyncPower)
                Text("Standby only applies while the TV is on the selected Mac HDMI input.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            brightness = Double(controller.deviceState.oledBrightness ?? 50)
            macAddress = controller.devicePreferences.wakeMACs.first ?? ""
        }
        .onChange(of: controller.devicePreferences.wakeMACs) { _, addresses in macAddress = addresses.first ?? "" }
    }

    private func preference(_ path: WritableKeyPath<LGWebOSDevicePreferences, Bool>) -> Binding<Bool> {
        Binding(get: { controller.devicePreferences[keyPath: path] }, set: {
            controller.devicePreferences[keyPath: path] = $0
            controller.saveDevicePreferences()
        })
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        controller.deviceError = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() }
            catch { controller.deviceError = error.localizedDescription }
        }
    }
}
