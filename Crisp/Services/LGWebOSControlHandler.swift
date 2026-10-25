import Foundation

@MainActor
enum LGWebOSControlHandler {
    /// Uses Crisp's existing same-user, 0600 control socket and frame limits.
    static func reply(to data: Data, displays: [DisplayInfo]) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String, command.hasPrefix("webos.") else { return nil }
        guard let request = try? JSONDecoder().decode(LGWebOSControlRequest.self, from: data) else {
            return encode(.init(ok: false, error: "invalid webOS request"))
        }
        guard let display = displays.first(where: { $0.displayID == request.display && !$0.isBuiltin }) else {
            return encode(.init(ok: false, error: "external display not found"))
        }
        let service = VolumeService.shared
        switch request.command {
        case .connect:
            guard let input = request.host, let host = LGWebOSProtocol.host(input) else {
                return encode(.init(ok: false, error: "a private IPv4 host is required"))
            }
            service.configureNetwork(host: host, for: display)
        case .disconnect:
            service.configureNetwork(host: "", for: display)
        case .volume:
            guard let value = request.volume, value.isFinite, (0...100).contains(value) else {
                return encode(.init(ok: false, error: "volume must be between 0 and 100"))
            }
            guard service.networkControllers[display.displayUUID]?.ready == true else {
                return encode(.init(ok: false, error: "TV is not connected"))
            }
            service.setVolume(value, for: display)
        case .status: break
        }
        let controller = service.networkControllers[display.displayUUID]
        return encode(.init(ok: true, status: controller?.status ?? "Not configured",
                            ready: controller?.ready ?? false, volume: controller?.confirmedVolume))
    }

    private static func encode(_ response: LGWebOSControlResponse) -> Data {
        (try? CrispControlModel.encode(response)) ?? CrispControlModel.encode(.failure("response encoding failed"))
    }
}
