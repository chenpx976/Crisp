import Foundation

struct LGWebOSInput: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let connected: Bool
}

struct LGWebOSDeviceState: Codable, Equatable {
    var oledBrightness: Int?
    var inputs: [LGWebOSInput] = []
    var currentInput: String?
    var power: String?
}

struct LGWebOSDevicePreferences: Codable, Equatable {
    var extendedControls = false
    var signedSettingsAccess = false
    var macInput = ""
    var wakeMACs: [String] = []
    var powerSync = false
    var switchOnWake = true
    var inputShortcuts: [String: KeyboardShortcut] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case extendedControls, signedSettingsAccess, macInput, wakeMACs, powerSync, switchOnWake, inputShortcuts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        extendedControls = try container.decodeIfPresent(Bool.self, forKey: .extendedControls) ?? false
        signedSettingsAccess = try container.decodeIfPresent(Bool.self, forKey: .signedSettingsAccess) ?? false
        macInput = try container.decodeIfPresent(String.self, forKey: .macInput) ?? ""
        wakeMACs = try container.decodeIfPresent([String].self, forKey: .wakeMACs) ?? []
        powerSync = try container.decodeIfPresent(Bool.self, forKey: .powerSync) ?? false
        switchOnWake = try container.decodeIfPresent(Bool.self, forKey: .switchOnWake) ?? true
        inputShortcuts = try container.decodeIfPresent([String: KeyboardShortcut].self, forKey: .inputShortcuts) ?? [:]
    }


    static func load(host: String) -> Self {
        guard let data = UserDefaults.standard.data(forKey: "crisp.webos.device.\(host)"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func save(host: String) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "crisp.webos.device.\(host)")
        }
    }

    var canSyncPower: Bool { LGWebOSDeviceProtocol.isHDMI(macInput) && wakeMACs.contains { LGWakeOnLAN.packet($0) != nil } }
}

enum LGWebOSDeviceProtocol {
    static func powerName(_ raw: String?) -> String {
        (raw ?? "").lowercased().filter(\.isLetter)
    }
    static func input(userValue: String) -> String? {
        let normalized = userValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        for index in 1...4 where normalized == "HDMI\(index)" { return "HDMI_\(index)" }
        return nil
    }

    static func isHDMI(_ id: String) -> Bool { ["HDMI_1", "HDMI_2", "HDMI_3", "HDMI_4"].contains(id) }
    static func input(appID: String) -> String? {
        for index in 1...4 where appID.lowercased() == "com.webos.app.hdmi\(index)" { return "HDMI_\(index)" }
        return nil
    }
    static func inputs(_ payload: [String: Any]) -> [LGWebOSInput] {
        (payload["devices"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String, isHDMI(id) else { return nil }
            return LGWebOSInput(id: id, label: $0["label"] as? String ?? id, connected: $0["connected"] as? Bool ?? false)
        }
    }
    static func oledBrightness(_ payload: [String: Any]) -> Int? {
        guard let settings = payload["settings"] as? [String: Any] else { return nil }
        if let value = settings["backlight"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            return (0...100).contains(value.doubleValue) && value.doubleValue.rounded() == value.doubleValue ? value.intValue : nil
        }
        if let string = settings["backlight"] as? String, let value = Int(string), (0...100).contains(value) { return value }
        return nil
    }
}

struct LGWebOSDeviceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
