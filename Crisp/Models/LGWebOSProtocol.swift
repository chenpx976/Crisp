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

    static func registration(key: String?) -> [String: Any] {
        var payload: [String: Any] = [
            "pairingType": "PROMPT", "forcePairing": false,
            "manifest": [
                "manifestVersion": 1, "appVersion": "1.0",
                "permissions": ["CONTROL_AUDIO", "READ_AUDIO_VOLUME"]
            ]
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
