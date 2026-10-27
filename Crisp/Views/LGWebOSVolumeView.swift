import SwiftUI
import ApplicationServices

struct LGWebOSVolumeView: View {
    @ObservedObject var display: DisplayInfo
    @ObservedObject private var service = VolumeService.shared
    @State private var host = ""
    @State private var invalidHost = false

    var body: some View {
        if !display.isBuiltin {
            VStack(alignment: .leading, spacing: 6) {
                Text("LG webOS TV Controls").font(.body)
                HStack {
                    TextField("TV IP address", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("TV IP address")
                        .onSubmit { connect() }
                    Button("Connect") { connect() }
                        .disabled(host.isEmpty)
                }
                if invalidHost {
                    Text("Enter a private IPv4 address, such as 192.168.1.20.")
                        .font(.caption).foregroundStyle(.red)
                }
                if let controller = service.networkControllers[display.displayUUID] {
                    LGWebOSConnectionStatus(controller: controller)
                    LGWebOSDeviceView(controller: controller)
                    HStack {
                        Button("Pair Again") { controller.pairAgain() }
                        Button("Disconnect") {
                            service.configureNetwork(host: "", for: display)
                        }
                    }
                    Button("Enable Volume Keys") {
                        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                        BrightnessKeyService.shared.start()
                        if !AXIsProcessTrusted(),
                           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else {
                    Text("Connect on the same network, then approve pairing on the TV.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .onAppear { host = service.networkHost(for: display) }
        }
    }

    private func connect() {
        guard let address = LGWebOSProtocol.host(host) else { invalidHost = true; return }
        invalidHost = false
        host = address
        service.configureNetwork(host: address, for: display)
    }
}

private struct LGWebOSConnectionStatus: View {
    @ObservedObject var controller: LGWebOSVolumeController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: controller.status)
                .foregroundStyle(controller.ready ? .green : .secondary)
            if let warning = controller.pairingWarning {
                Text(verbatim: warning).foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}
