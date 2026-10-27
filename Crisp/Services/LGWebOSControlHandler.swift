import Foundation

@MainActor
enum LGWebOSControlHandler {
    /// Uses Crisp's existing same-user, 0600 control socket and frame limits.
    static func reply(to data: Data, displays: [DisplayInfo]) async -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String, command.hasPrefix("webos.") else { return nil }
        guard let request = try? JSONDecoder().decode(LGWebOSControlRequest.self, from: data) else {
            return encode(.init(ok: false, error: "invalid webOS request"))
        }
        let display = displays.first(where: { $0.displayID == request.display && !$0.isBuiltin })
        let service = VolumeService.shared
        switch request.command {
        case .connect:
            guard let display, let input = request.host, let host = LGWebOSProtocol.host(input) else {
                return encode(.init(ok: false, error: "an external display and private IPv4 host are required"))
            }
            service.configureNetwork(host: host, for: display)
        case .disconnect:
            guard let display else { return encode(.init(ok: false, error: "external display not found")) }
            service.configureNetwork(host: "", for: display)
        default: break
        }
        let live = display.flatMap { service.networkControllers[$0.displayUUID] }
        let host = LGWebOSPowerService.shared.host(for: request.display)
        let temporary = live == nil && request.command == .wake && host != nil
        let controller = live ?? (temporary ? host.map { LGWebOSVolumeController(host: $0) } : nil)
        defer { if temporary { controller?.disconnect() } }
        do {
            switch request.command {
            case .volume:
                guard let display, let value = request.volume, value.isFinite, (0...100).contains(value), controller?.ready == true else {
                    throw LGWebOSDeviceError(message: "TV is not connected or volume is outside 0...100")
                }
                service.setVolume(value, for: display)
            case .enable:
                guard let controller else { throw LGWebOSDeviceError(message: "TV is not configured") }
                controller.enableDeviceControls()
            case .enableSettings:
                guard let controller else { throw LGWebOSDeviceError(message: "TV is not configured") }
                controller.enableSettingsAccess()
            case .refresh:
                guard let controller else { throw LGWebOSDeviceError(message: "TV is not configured") }
                await controller.refreshDeviceState()
            case .brightness:
                guard let controller, let value = request.brightness else { throw LGWebOSDeviceError(message: "Missing brightness") }
                try await controller.setOLEDBrightness(value)
            case .input:
                guard let input = request.input else { throw LGWebOSDeviceError(message: "Missing input") }
                if let controller { try await controller.switchTVInput(input) }
                else if let host { try await LGWebOSPowerService.shared.switchInput(host: host, input: input) }
                else { throw LGWebOSDeviceError(message: "TV is not configured") }
            case .wake:
                guard let controller else { throw LGWebOSDeviceError(message: "TV is not configured") }
                try await controller.wakeTV()
            case .standby:
                guard let controller else { throw LGWebOSDeviceError(message: "TV is not configured") }
                try await controller.sleepTVIfOnMacInput()
            case .config:
                guard let controller else { throw LGWebOSDeviceError(message: "TV is not configured") }
                var preferences = controller.devicePreferences
                if let input = request.macInput {
                    guard input.isEmpty || controller.deviceState.inputs.contains(where: { $0.id == input }) else {
                        throw LGWebOSDeviceError(message: "Unknown Mac HDMI input")
                    }
                    preferences.macInput = input
                }
                if let address = request.macAddress {
                    guard LGWakeOnLAN.packet(address) != nil else { throw LGWebOSDeviceError(message: "Invalid MAC address") }
                    preferences.wakeMACs = [address]
                }
                if let value = request.powerSync { preferences.powerSync = value }
                if let value = request.switchOnWake { preferences.switchOnWake = value }
                guard !preferences.powerSync || preferences.extendedControls && preferences.canSyncPower else {
                    throw LGWebOSDeviceError(message: "Set the Mac HDMI input and TV MAC address before enabling power sync")
                }
                controller.devicePreferences = preferences
                controller.saveDevicePreferences()
            case .status, .connect, .disconnect: break
            }
        } catch { return encode(.init(ok: false, error: error.localizedDescription)) }
        return encode(.init(ok: true, status: controller?.status ?? (host == nil ? "Not configured" : "TV is offline"),
                            ready: controller?.ready ?? false, volume: controller?.confirmedVolume,
                            warning: controller?.pairingWarning, device: controller?.deviceState,
                            preferences: controller?.devicePreferences ?? host.map(LGWebOSDevicePreferences.load),
                            deviceError: controller?.deviceError))
    }

    private static func encode(_ response: LGWebOSControlResponse) -> Data {
        (try? CrispControlModel.encode(response)) ?? CrispControlModel.encode(.failure("response encoding failed"))
    }
}
