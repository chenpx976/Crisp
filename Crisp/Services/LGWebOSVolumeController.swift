import Foundation
import Combine
import Security
import CryptoKit

/// LG TVs use a private CA. Accept only LG's known TV/issuer certificates,
/// scoped to the explicit private IP, rather than disabling TLS validation globally.
private final class LGWebOSTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              LGWebOSProtocol.host(challenge.protectionSpace.host) != nil,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let known = Set([
            "e2bd6464d3f51c1b95b7697d9d6773c33d9412eba0299c568c34937d3fe68aa0",
            "11c5b1c5907750abb9da2a6665ccce2bb288a583f45a3339e71f87bf2f808552"
        ])
        let anchors = chain.filter { certificate in
            let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            return known.contains(digest.map { String(format: "%02x", $0) }.joined())
        }
        // LG's certificate names do not match private IPs. Validate its chain
        // against the pinned anchors using X.509 rather than hostname policy.
        // Finding a known certificate in an otherwise invalid chain is insufficient.
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        let matches = !anchors.isEmpty && SecTrustEvaluateWithError(trust, nil)
        completionHandler(matches ? .useCredential : .cancelAuthenticationChallenge,
                          matches ? URLCredential(trust: trust) : nil)
    }
}

@MainActor
final class LGWebOSVolumeController: ObservableObject {
    @Published private(set) var status = String(localized: "Not connected")
    @Published private(set) var ready = false
    /// Last subscribed TV read-back; never the slider's optimistic target.
    @Published private(set) var confirmedVolume: Double?
    let host: String
    var onVolume: ((Double) -> Void)?
    var onReady: ((Bool) -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var worker: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var pending: Int?
    private var muted = false
    private var lastLevel = 0.0
    private var commandID = 0
    private var writing = false
    private var rejected = false

    init(host: String) { self.host = host }

    func connect() {
        disconnect()
        rejected = false
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await self.runConnection() } catch {
                    guard !Task.isCancelled else { return }
                    self.status = String(localized: "Connection lost. Retrying in 5 seconds.")
                        + " " + error.localizedDescription
                }
                self.setReady(false)
                self.socket?.cancel(with: .goingAway, reason: nil)
                self.session?.invalidateAndCancel()
                if self.rejected { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    func disconnect() {
        worker?.cancel()
        worker = nil
        writer?.cancel()
        writer = nil
        pending = nil
        writing = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        setReady(false)
        status = String(localized: "Not connected")
    }

    private func setReady(_ value: Bool) {
        ready = value
        if !value { confirmedVolume = nil }
        onReady?(value)
    }

    func pairAgain() {
        disconnect()
        SecItemDelete(keyQuery as CFDictionary)
        connect()
    }

    private func runConnection() async throws {
        guard let url = URL(string: "wss://\(host):3001") else { return }
        status = String(localized: "Connecting. Accept the request on your TV.")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: LGWebOSTrust(), delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        // Timeout a stalled handshake or an unanswered pairing prompt, but not a live subscription.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, !self.ready else { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        let heartbeat = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                let timeout = Task {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    socket.cancel(with: .goingAway, reason: nil)
                }
                socket.sendPing { error in
                    timeout.cancel()
                    if error != nil { socket.cancel(with: .goingAway, reason: nil) }
                }
            }
        }
        defer { heartbeat.cancel() }
        try await send(LGWebOSProtocol.registration(key: readKey()), on: socket)
        while !Task.isCancelled {
            let message = try await socket.receive()
            try Task.checkCancellation()
            let data: Data
            switch message {
            case .string(let value): data = Data(value.utf8)
            case .data(let value): data = value
            @unknown default: continue
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let payload = json["payload"] as? [String: Any] ?? [:]
            if json["type"] as? String == "error" || payload["returnValue"] as? Bool == false {
                status = String(localized: "TV rejected the request. Disconnect and pair again.")
                setReady(false)
                // Do not repeatedly prompt after the user rejects pairing.
                rejected = true
                return
            }
            if json["type"] as? String == "registered" {
                if let key = payload["client-key"] as? String { saveKey(key) }
                try await send(["id": "volume", "type": "subscribe", "uri": "ssap://audio/getVolume"], on: socket)
            } else if json["id"] as? String == "volume", let volume = LGWebOSProtocol.volume(payload) {
                lastLevel = volume.level
                muted = volume.muted
                confirmedVolume = muted ? 0 : lastLevel
                status = String(localized: "Connected")
                setReady(true)
                if !writing && pending == nil { onVolume?(muted ? 0 : lastLevel) }
            }
        }
    }

    /// Latest slider value wins. Writes are paced independently of the DDC bus.
    func setVolume(_ value: Double) {
        guard ready else { return }
        pending = Int(max(0, min(100, value)).rounded())
        guard writer == nil else { return }
        writer = Task { [weak self] in
            guard let self else { return }
            defer { self.writer = nil; self.writing = false }
            while let level = self.pending, let socket = self.socket, !Task.isCancelled {
                self.pending = nil
                self.writing = true
                do {
                    if self.muted && level > 0 {
                        try await self.request("audio/setMute", payload: ["mute": false], on: socket)
                    }
                    try await self.request("audio/setVolume", payload: ["volume": level], on: socket)
                    try await Task.sleep(for: .milliseconds(80))
                } catch {
                    guard !Task.isCancelled else { return }
                    self.setReady(false)
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
            if self.ready { self.onVolume?(self.muted ? 0 : self.lastLevel) }
        }
    }

    private func request(_ uri: String, payload: [String: Any], on socket: URLSessionWebSocketTask) async throws {
        commandID += 1
        try await send(["id": "command-\(commandID)", "type": "request", "uri": "ssap://\(uri)", "payload": payload],
                       on: socket)
    }

    private func send(_ message: [String: Any], on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.crisp.webos", kSecAttrAccount as String: host]
    }

    private func readKey() -> String? {
        var query = keyQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveKey(_ key: String) {
        let data = Data(key.utf8)
        let result = SecItemUpdate(keyQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var query = keyQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(query as CFDictionary, nil)
        }
    }
}
