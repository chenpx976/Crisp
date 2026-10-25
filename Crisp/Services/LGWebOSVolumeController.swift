import Foundation
import Combine

@MainActor
final class LGWebOSVolumeController: ObservableObject {
    @Published private(set) var status = String(localized: "Not connected")
    @Published private(set) var ready = false
    @Published private(set) var confirmedVolume: Double?
    @Published private(set) var pairingWarning: String?
    let host: String
    var onVolume: ((Double) -> Void)?
    var onReady: ((Bool) -> Void)?
    private let keyStore: any LGWebOSKeyStore
    private let makeSocket: @MainActor () -> any LGWebOSSocket
    private let retryDelay: Duration
    private let confirmationTimeout: Duration
    private var socket: (any LGWebOSSocket)?
    private var connectionID: UUID?
    private var generation = UUID()
    private var worker: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var writerID = UUID()
    private var settlement: Task<Void, Never>?
    private var keyTask: Task<Void, Never>?
    private var pending: Int?
    private var target: Int?
    private var revision = UUID()
    private var muted = false
    private var commandID = 0
    private var cachedKey: String?

    private enum ConnectionError: LocalizedError {
        case pairingRejected
        case requestFailed(String)
        var errorDescription: String? {
            switch self {
            case .pairingRejected: return String(localized: "TV rejected the request. Disconnect and pair again.")
            case .requestFailed(let detail): return detail
            }
        }
    }

    init(host: String, keyStore: any LGWebOSKeyStore = LGWebOSKeychainStore(),
         retryDelay: Duration = .seconds(5), confirmationTimeout: Duration = .seconds(2),
         makeSocket: (@MainActor () -> any LGWebOSSocket)? = nil) {
        self.host = host
        self.keyStore = keyStore
        self.retryDelay = retryDelay
        self.confirmationTimeout = confirmationTimeout
        self.makeSocket = makeSocket ?? { LGWebOSTransport(host: host) }
    }

    func connect() {
        disconnect()
        startConnection()
    }

    private func startConnection() {
        let generation = generation
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let key = try await self.keyStore.read(host: self.host)
                guard self.isCurrent(generation) else { return }
                self.cachedKey = key
            } catch {
                guard self.isCurrent(generation) else { return }
                self.status = String(localized: "Unable to read TV pairing. Check Keychain access.")
                self.pairingWarning = error.localizedDescription
                return // Do not silently start a fresh pairing after a denied key read.
            }
            while self.isCurrent(generation) {
                let socket = self.makeSocket()
                self.socket = socket
                let connectionID = UUID()
                self.connectionID = connectionID
                var retry = true
                do { try await self.runConnection(socket, generation: generation, connectionID: connectionID) }
                catch {
                    guard self.isCurrent(generation) else { return }
                    if case ConnectionError.pairingRejected = error {
                        self.status = error.localizedDescription
                        retry = false
                    } else {
                        self.status = String(localized: "Connection lost. Retrying in 5 seconds.")
                            + " " + error.localizedDescription
                    }
                }
                guard self.isCurrent(generation) else { return }
                self.cancelWrites()
                self.setReady(false)
                socket.close()
                self.socket = nil
                self.connectionID = nil
                guard retry else { return }
                do { try await Task.sleep(for: self.retryDelay) } catch { return }
            }
        }
    }

    private func isCurrent(_ generation: UUID) -> Bool { self.generation == generation && !Task.isCancelled }

    func disconnect() {
        generation = UUID()
        worker?.cancel()
        worker = nil
        keyTask?.cancel()
        keyTask = nil
        cancelWrites()
        socket?.close()
        socket = nil
        connectionID = nil
        cachedKey = nil
        pairingWarning = nil
        setReady(false)
        status = String(localized: "Not connected")
    }

    private func cancelWrites() {
        writerID = UUID()
        writer?.cancel()
        writer = nil
        settlement?.cancel()
        settlement = nil
        pending = nil
        target = nil
    }

    private func setReady(_ value: Bool) {
        ready = value
        if !value { confirmedVolume = nil }
        onReady?(value)
    }

    func pairAgain() {
        disconnect()
        let generation = generation
        keyTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.keyStore.delete(host: self.host)
                guard self.isCurrent(generation) else { return }
                self.keyTask = nil
                self.startConnection()
            } catch {
                guard self.isCurrent(generation) else { return }
                self.status = String(localized: "Unable to remove TV pairing. Check Keychain access.")
                self.pairingWarning = error.localizedDescription
            }
        }
    }

    private func persistKey(_ key: String, generation: UUID) {
        cachedKey = key // Reconnect this session even if persistence is unavailable.
        keyTask?.cancel()
        keyTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.keyStore.save(key, host: self.host)
                guard self.isCurrent(generation) else { return }
                self.pairingWarning = nil
            } catch {
                guard self.isCurrent(generation) else { return }
                self.pairingWarning = String(localized: "TV pairing could not be saved. Pair again after restarting.")
                    + " " + error.localizedDescription
            }
        }
    }

    private func runConnection(_ socket: any LGWebOSSocket, generation: UUID, connectionID: UUID) async throws {
        status = String(localized: "Connecting. Accept the request on your TV.")
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, self.connectionID == connectionID, !self.ready else { return }
            socket.close()
        }
        defer { watchdog.cancel() }
        let heartbeat = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                let timeout = Task {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    socket.close()
                }
                do { try await socket.ping() } catch { socket.close() }
                timeout.cancel()
            }
        }
        defer { heartbeat.cancel() }
        try await send(LGWebOSProtocol.registration(key: cachedKey), on: socket)
        var registered = false
        while isCurrent(generation) {
            let data = try await socket.receive()
            guard isCurrent(generation), self.connectionID == connectionID else { throw CancellationError() }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let payload = json["payload"] as? [String: Any] ?? [:]
            if json["type"] as? String == "error" || payload["returnValue"] as? Bool == false {
                // Only registration rejection is terminal. Command/subscription failures
                // reconnect with the existing key rather than asking for fresh pairing.
                if !registered || json["id"] as? String == "register" { throw ConnectionError.pairingRejected }
                let detail = json["error"] as? String ?? payload["errorText"] as? String ?? "TV request failed"
                throw ConnectionError.requestFailed(detail)
            }
            if json["type"] as? String == "registered" {
                registered = true
                if let key = payload["client-key"] as? String { persistKey(key, generation: generation) }
                try await send(["id": "volume", "type": "subscribe", "uri": "ssap://audio/getVolume"], on: socket)
            } else if json["id"] as? String == "volume", let volume = LGWebOSProtocol.volume(payload) {
                muted = volume.muted
                let level = muted ? 0 : volume.level
                confirmedVolume = level
                status = String(localized: "Connected")
                setReady(true)
                if let target, abs(level - Double(target)) < 0.5 {
                    self.target = nil
                    settlement?.cancel()
                    settlement = nil
                }
                if target == nil { onVolume?(level) }
            }
        }
    }

    /// Keep the optimistic target until matching TV read-back or a bounded timeout.
    /// Pacing is independent of confirmation: continuous key presses still coalesce.
    func setVolume(_ value: Double) {
        guard ready, value.isFinite, let connectionID, let socket else { return }
        let level = Int(max(0, min(100, value)).rounded())
        pending = level
        target = level
        revision = UUID()
        let revision = revision
        settlement?.cancel()
        settlement = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.confirmationTimeout) } catch { return }
            guard self.connectionID == connectionID, self.revision == revision, self.target != nil else { return }
            self.target = nil
            self.status = String(localized: "TV did not confirm the requested volume.")
            if let level = self.confirmedVolume { self.onVolume?(level) }
        }
        guard writer == nil else { return }
        writerID = UUID()
        let writerID = writerID
        writer = Task { [weak self] in
            guard let self else { return }
            defer { if self.writerID == writerID { self.writer = nil } }
            while self.connectionID == connectionID, let level = self.pending, !Task.isCancelled {
                self.pending = nil
                do {
                    if self.muted && level > 0 {
                        try await self.request("audio/setMute", payload: ["mute": false], on: socket)
                    }
                    try await self.request("audio/setVolume", payload: ["volume": level], on: socket)
                    try await Task.sleep(for: .milliseconds(80))
                } catch {
                    guard self.connectionID == connectionID, !Task.isCancelled else { return }
                    socket.close() // The reader owns reconnect and state cleanup.
                    return
                }
            }
        }
    }

    private func request(_ uri: String, payload: [String: Any], on socket: any LGWebOSSocket) async throws {
        commandID += 1
        try await send(["id": "command-\(commandID)", "type": "request", "uri": "ssap://\(uri)", "payload": payload],
                       on: socket)
    }

    private func send(_ message: [String: Any], on socket: any LGWebOSSocket) async throws {
        try await socket.send(JSONSerialization.data(withJSONObject: message))
    }
}
