import Foundation

enum LGWebOSProtocol {
    /// Only literal private IPv4 addresses: no URL credentials, public hosts or DNS rebinding.
    static func host(_ input: String) -> String? {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return UInt8(part)
        }
        guard bytes.count == 4,
              bytes[0] == 10 || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 172 && (16...31).contains(bytes[1])) else { return nil }
        return bytes.map(String.init).joined(separator: ".")
    }

    static func registration(key: String?, extended: Bool = false, settingsAccess: Bool = false) -> [String: Any] {
        var permissions = ["CONTROL_AUDIO", "READ_AUDIO_VOLUME"]
        if extended {
            permissions += ["CONTROL_POWER", "READ_POWER_STATE", "READ_INPUT_DEVICE_LIST", "CONTROL_INPUT_TV",
                            "LAUNCH", "READ_RUNNING_APPS", "READ_NETWORK_STATE", "CONTROL_DISPLAY", "CONTROL_TV_SCREEN", "READ_SETTINGS", "WRITE_SETTINGS"]
        }
        var manifest: [String: Any] = ["manifestVersion": 1, "appVersion": "1.0", "permissions": permissions]
        if extended && settingsAccess { manifest.merge(LGWebOSSignedManifest.fields) { _, new in new } }
        var payload: [String: Any] = [
            "pairingType": "PROMPT", "forcePairing": false,
            "manifest": manifest
        ]
        if let key { payload["client-key"] = key }
        return ["id": "register", "type": "register", "payload": payload]
    }

    static func volume(_ payload: [String: Any]) -> (level: Double, muted: Bool)? {
        let status = payload["volumeStatus"] as? [String: Any] ?? payload
        guard let level = status["volume"] as? NSNumber,
              CFGetTypeID(level) != CFBooleanGetTypeID(), (0...100).contains(level.doubleValue) else { return nil }
        let muted = status["muteStatus"] as? Bool ?? status["muted"] as? Bool ?? false
        return (level.doubleValue, muted)
    }
}
