import XCTest
import Foundation
import Security

@MainActor
private final class TestWebOSSocket: LGWebOSSocket {
    var onSend: (([String: Any]) -> Void)?
    private var queued: [Data] = []
    private var waiting: CheckedContinuation<Data, Error>?
    private(set) var closed = false
    private(set) var sent: [[String: Any]] = []

    func push(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            XCTFail("Invalid mock frame")
            return
        }
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: data)
        } else { queued.append(data) }
    }

    func volume(_ level: Int) { push(["id": "volume", "type": "response", "payload": ["volume": level, "muted": false]]) }

    func send(_ data: Data) async throws {
        guard !closed else { throw URLError(.networkConnectionLost) }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        sent.append(object)
        if object["type"] as? String == "register" {
            push(["type": "registered", "payload": ["client-key": "test-key"]])
        } else if object["type"] as? String == "subscribe" { volume(12) }
        onSend?(object)
    }

    func receive() async throws -> Data {
        guard !closed else { throw URLError(.networkConnectionLost) }
        if !queued.isEmpty { return queued.removeFirst() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }

    func ping() async throws {}
    func close() {
        closed = true
        waiting?.resume(throwing: URLError(.networkConnectionLost))
        waiting = nil
    }
}

private struct TestWebOSKeyStore: LGWebOSKeyStore {
    var readError: OSStatus?
    var saveError: OSStatus?
    var deleteError: OSStatus?
    var readDelay: Duration = .zero
    var saveDelay: Duration = .zero
    func read(host: String) async throws -> String? {
        try await Task.sleep(for: readDelay)
        if let readError { throw LGWebOSKeychainError(status: readError) }
        return "saved-key"
    }
    func save(_ key: String, host: String) async throws {
        try await Task.sleep(for: saveDelay)
        if let saveError { throw LGWebOSKeychainError(status: saveError) }
    }
    func delete(host: String) async throws {
        if let deleteError { throw LGWebOSKeychainError(status: deleteError) }
    }
}

final class LGWebOSVolumeControllerTests: XCTestCase {
    @MainActor
    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    @MainActor
    func testDevicePermissionErrorAndTimeoutDoNotDisconnectAudio() async throws {
        let socket = TestWebOSSocket()
        let controller = LGWebOSVolumeController(host: "test", keyStore: TestWebOSKeyStore(), makeSocket: { socket })
        controller.connect()
        defer { controller.disconnect() }
        await eventually { controller.ready }
        socket.onSend = { object in
            guard let id = object["id"] as? String, id.hasPrefix("device-") else { return }
            socket.push(["type": "error", "id": id, "error": "403 permission denied"])
        }
        do {
            _ = try await controller.call("settings/getSystemSettings")
            XCTFail("Permission failure must be returned")
        } catch { XCTAssertTrue(error.localizedDescription.contains("403")) }
        XCTAssertTrue(controller.ready)
        XCTAssertFalse(socket.closed)
        socket.onSend = nil
        do {
            _ = try await controller.call("settings/getSystemSettings", timeout: .milliseconds(20))
            XCTFail("Unanswered call must time out")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertTrue(controller.ready)
        socket.volume(17)
        await eventually { controller.confirmedVolume == 17 }
    }

    @MainActor
    func testDeviceCancellationAndDisconnectResumePendingCalls() async throws {
        let socket = TestWebOSSocket()
        let controller = LGWebOSVolumeController(host: "test", keyStore: TestWebOSKeyStore(), makeSocket: { socket })
        controller.connect()
        await eventually { controller.ready }
        let cancelled = Task { try await controller.call("test/cancel") }
        await eventually { socket.sent.contains { $0["uri"] as? String == "ssap://test/cancel" } }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(controller.ready)
        let pending = Task { try await controller.call("test/disconnect") }
        await eventually { socket.sent.contains { $0["uri"] as? String == "ssap://test/disconnect" } }
        controller.disconnect()
        do { _ = try await pending.value; XCTFail("Must fail after disconnect") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
    }

    @MainActor
    func testDeviceResponsesAreMatchedByIDAndLateResponsesAreIgnored() async throws {
        let socket = TestWebOSSocket()
        let controller = LGWebOSVolumeController(host: "test", keyStore: TestWebOSKeyStore(), makeSocket: { socket })
        controller.connect()
        defer { controller.disconnect() }
        await eventually { controller.ready }
        let first = Task { try await controller.call("test/first") }
        let second = Task { try await controller.call("test/second") }
        await eventually { socket.sent.filter { ($0["id"] as? String)?.hasPrefix("device-") == true }.count == 2 }
        for uri in ["ssap://test/second", "ssap://test/first"] {
            let frame = try XCTUnwrap(socket.sent.first { $0["uri"] as? String == uri })
            socket.push(["type": "response", "id": try XCTUnwrap(frame["id"]), "payload": ["value": uri]])
        }
        let firstResult = try JSONSerialization.jsonObject(with: await first.value) as? [String: String]
        let secondResult = try JSONSerialization.jsonObject(with: await second.value) as? [String: String]
        XCTAssertEqual(firstResult?["value"], "ssap://test/first")
        XCTAssertEqual(secondResult?["value"], "ssap://test/second")
        socket.push(["type": "error", "id": "device-expired", "error": "late error"])
        socket.volume(19)
        await eventually { controller.confirmedVolume == 19 }
        XCTAssertTrue(controller.ready)
    }

    @MainActor
    func testOLEDWriteUsesBacklightAndRequiresActualReadBack() async throws {
        let socket = TestWebOSSocket()
        let controller = LGWebOSVolumeController(host: "test", keyStore: TestWebOSKeyStore(), makeSocket: { socket })
        controller.connect()
        defer { controller.disconnect() }
        await eventually { controller.ready }
        var actual = 40
        var ignoreWrite = false
        socket.onSend = { frame in
            guard let id = frame["id"] as? String, id.hasPrefix("device-") else { return }
            if frame["uri"] as? String == "ssap://settings/setSystemSettings" {
                let payload = frame["payload"] as? [String: Any]
                let settings = payload?["settings"] as? [String: Int]
                XCTAssertNil(settings?["brightness"])
                if !ignoreWrite { actual = settings?["backlight"] ?? -1 }
                socket.push(["type": "response", "id": id, "payload": ["returnValue": true]])
            } else {
                socket.push(["type": "response", "id": id, "payload": ["settings": ["backlight": actual]]])
            }
        }
        try await controller.setOLEDBrightness(39)
        XCTAssertEqual(controller.deviceState.oledBrightness, 39)
        ignoreWrite = true
        do { try await controller.setOLEDBrightness(38); XCTFail("Must not claim an unconfirmed write") }
        catch { XCTAssertEqual(controller.deviceState.oledBrightness, 39) }
        let count = socket.sent.count
        do { try await controller.setOLEDBrightness(101); XCTFail("Must reject invalid brightness") } catch {}
        XCTAssertEqual(socket.sent.count, count)
        XCTAssertTrue(controller.ready)
    }

    @MainActor
    func testInputSwitchLoadsTVInputsAndChecksForegroundApp() async throws {
        let socket = TestWebOSSocket()
        let controller = LGWebOSVolumeController(host: "test", keyStore: TestWebOSKeyStore(), makeSocket: { socket })
        controller.connect()
        defer { controller.disconnect() }
        await eventually { controller.ready }
        var foreground = "com.webos.app.hdmi1"
        socket.onSend = { frame in
            guard let id = frame["id"] as? String, id.hasPrefix("device-") else { return }
            var payload: [String: Any] = ["returnValue": true]
            switch frame["uri"] as? String {
            case "ssap://tv/getExternalInputList": payload["devices"] = [["id": "HDMI_2", "label": "Console"]]
            case "ssap://tv/switchInput": foreground = "com.webos.app.hdmi2"
            default: payload["appId"] = foreground
            }
            socket.push(["type": "response", "id": id, "payload": payload])
        }
        try await controller.switchTVInput("HDMI_2")
        XCTAssertEqual(controller.deviceState.currentInput, "HDMI_2")
        let count = socket.sent.count
        do { try await controller.switchTVInput("HDMI_4"); XCTFail("Must reject an input absent from TV list") } catch {}
        XCTAssertEqual(socket.sent.count, count)
    }

    @MainActor
    func testStandbySkipsOtherHDMIAndTVAppsThenAllowsMacInput() async throws {
        let socket = TestWebOSSocket()
        let controller = LGWebOSVolumeController(host: "test", keyStore: TestWebOSKeyStore(), makeSocket: { socket })
        controller.connect()
        defer { controller.disconnect() }
        await eventually { controller.ready }
        controller.devicePreferences.extendedControls = true
        controller.devicePreferences.macInput = "HDMI_2"
        controller.devicePreferences.wakeMACs = ["00:11:22:33:44:55"]
        var foreground = "com.webos.app.hdmi1"
        socket.onSend = { frame in
            guard let id = frame["id"] as? String, id.hasPrefix("device-") else { return }
            socket.push(["type": "response", "id": id, "payload": ["returnValue": true, "appId": foreground]])
        }
        try await controller.sleepTVIfOnMacInput()
        foreground = "netflix"
        try await controller.sleepTVIfOnMacInput()
        XCTAssertFalse(socket.sent.contains { $0["uri"] as? String == "ssap://system/turnOff" })
        foreground = "com.webos.app.hdmi2"
        try await controller.sleepTVIfOnMacInput()
        XCTAssertEqual(socket.sent.filter { $0["uri"] as? String == "ssap://system/turnOff" }.count, 1)
    }

    @MainActor
    func testWakeRetriesPacketsAfterStandbyTransitionAndConfirmsActiveState() async throws {
        let socket = TestWebOSSocket()
        var packets = 0
        let controller = LGWebOSVolumeController(host: "test", keyStore: TestWebOSKeyStore(),
                                                sendWakePacket: { _, _ in packets += 1 }, makeSocket: { socket })
        controller.connect()
        defer { controller.disconnect() }
        await eventually { controller.ready }
        controller.devicePreferences.macInput = "HDMI_2"
        controller.devicePreferences.wakeMACs = ["00:11:22:33:44:55"]
        controller.devicePreferences.switchOnWake = false
        socket.onSend = { frame in
            guard let id = frame["id"] as? String, id.hasPrefix("device-") else { return }
            let state = packets >= 4 ? "Active" : "Active Standby"
            socket.push(["type": "response", "id": id, "payload": ["returnValue": true, "state": state]])
        }
        try await controller.wakeTV()
        XCTAssertGreaterThanOrEqual(packets, 4)
        XCTAssertEqual(controller.deviceState.power, "Active")
        XCTAssertTrue(socket.sent.contains { $0["uri"] as? String == "ssap://com.webos.service.tvpower/power/turnOnScreen" })
    }

    @MainActor
    func testDelayedReadBackDoesNotRollBackLatestTarget() async {
        let socket = TestWebOSSocket()
        let controller = LGWebOSVolumeController(host: "test", keyStore: TestWebOSKeyStore(), makeSocket: { socket })
        var displayed: [Double] = []
        controller.onVolume = { displayed.append($0) }
        controller.connect()
        defer { controller.disconnect() }
        await eventually { controller.ready }
        controller.setVolume(20)
        try? await Task.sleep(for: .milliseconds(120)) // Exceed the old 80ms rollback.
        controller.setVolume(25)
        socket.volume(20) // A delayed response for the previous key press.
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(displayed, [12])
        XCTAssertEqual(controller.confirmedVolume, 20)
        socket.volume(25)
        await eventually { displayed.last == 25 }
        XCTAssertEqual(displayed, [12, 25])
    }

    @MainActor
    func testUnconfirmedTargetSettlesToActualVolumeAfterTimeout() async {
        let socket = TestWebOSSocket()
        let controller = LGWebOSVolumeController(host: "test", keyStore: TestWebOSKeyStore(),
                                                confirmationTimeout: .milliseconds(100), makeSocket: { socket })
        var displayed: [Double] = []
        controller.onVolume = { displayed.append($0) }
        controller.connect()
        defer { controller.disconnect() }
        await eventually { controller.ready }
        controller.setVolume(20)
        await eventually { controller.status == String(localized: "TV did not confirm the requested volume.") }
        XCTAssertEqual(displayed, [12, 12])
        XCTAssertTrue(controller.ready)
        socket.volume(18) // Once timed out, external changes must continue to sync.
        await eventually { displayed.last == 18 }
    }

    @MainActor
    func testCommandFailureReconnectsWithoutFreshPairing() async {
        let first = TestWebOSSocket()
        let second = TestWebOSSocket()
        var attempts = 0
        let controller = LGWebOSVolumeController(host: "test", keyStore: TestWebOSKeyStore(),
                                                retryDelay: .milliseconds(10), makeSocket: {
            attempts += 1
            return attempts == 1 ? first : second
        })
        first.onSend = { object in
            if object["uri"] as? String == "ssap://audio/setVolume" {
                first.push(["id": object["id"] as? String ?? "command", "type": "error", "error": "500 temporary failure"])
            }
        }
        controller.connect()
        defer { controller.disconnect(); first.onSend = nil }
        await eventually { controller.ready }
        controller.setVolume(20)
        await eventually { attempts == 2 && controller.ready }
        XCTAssertTrue(first.closed)
        let payload = second.sent.first?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["client-key"] as? String, "test-key")
    }

    @MainActor
    func testSubscriptionFailureAlsoRetries() async {
        let first = TestWebOSSocket()
        let second = TestWebOSSocket()
        var attempts = 0
        let controller = LGWebOSVolumeController(host: "test", keyStore: TestWebOSKeyStore(),
                                                retryDelay: .milliseconds(10), makeSocket: {
            attempts += 1
            return attempts == 1 ? first : second
        })
        controller.connect()
        defer { controller.disconnect() }
        await eventually { controller.ready }
        first.push(["id": "volume", "type": "response", "payload": ["returnValue": false, "errorText": "busy"]])
        await eventually { attempts == 2 && controller.ready }
    }

    @MainActor
    func testRegistrationRejectionStopsRetries() async {
        let socket = TestWebOSSocket()
        var attempts = 0
        socket.onSend = { object in
            if object["type"] as? String == "register" {
                // Processed after registration but still identified as a registration error.
                socket.push(["id": "register", "type": "error", "error": "403 denied"])
            }
        }
        let controller = LGWebOSVolumeController(host: "test", keyStore: TestWebOSKeyStore(),
                                                retryDelay: .milliseconds(10), makeSocket: { attempts += 1; return socket })
        controller.connect()
        defer { controller.disconnect(); socket.onSend = nil }
        await eventually { socket.closed }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.ready)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(controller.status, String(localized: "TV rejected the request. Disconnect and pair again."))
    }

    @MainActor
    func testKeySaveFailureRemainsVisibleWhileConnected() async {
        let socket = TestWebOSSocket()
        let keys = TestWebOSKeyStore(saveError: errSecAuthFailed, saveDelay: .milliseconds(100))
        let controller = LGWebOSVolumeController(host: "test", keyStore: keys, makeSocket: { socket })
        controller.connect()
        defer { controller.disconnect() }
        await eventually { controller.ready } // Subscription must not wait on Keychain's prompt.
        XCTAssertNil(controller.pairingWarning)
        await eventually { controller.pairingWarning != nil }
        socket.volume(13)
        await eventually { controller.confirmedVolume == 13 }
        XCTAssertNotNil(controller.pairingWarning)
        XCTAssertTrue(controller.ready)
    }

    @MainActor
    func testKeyReadFailureDoesNotSilentlyPairAgain() async {
        let socket = TestWebOSSocket()
        var attempts = 0
        let controller = LGWebOSVolumeController(host: "test", keyStore: TestWebOSKeyStore(readError: errSecAuthFailed),
                                                makeSocket: { attempts += 1; return socket })
        controller.connect()
        defer { controller.disconnect() }
        await eventually { controller.pairingWarning != nil }
        XCTAssertEqual(attempts, 0)
        XCTAssertFalse(controller.ready)
    }

    @MainActor
    func testKeyDeleteFailureDoesNotPretendToRepair() async {
        let socket = TestWebOSSocket()
        var attempts = 0
        let controller = LGWebOSVolumeController(host: "test", keyStore: TestWebOSKeyStore(deleteError: errSecAuthFailed),
                                                makeSocket: { attempts += 1; return socket })
        controller.pairAgain()
        defer { controller.disconnect() }
        await eventually { controller.pairingWarning != nil }
        XCTAssertEqual(attempts, 0)
        XCTAssertFalse(controller.ready)
    }

    @MainActor
    func testDisconnectCancelsPendingConfirmationAndKeyRead() async {
        let socket = TestWebOSSocket()
        var attempts = 0
        let controller = LGWebOSVolumeController(host: "test", keyStore: TestWebOSKeyStore(readDelay: .milliseconds(100)),
                                                makeSocket: { attempts += 1; return socket })
        controller.connect()
        controller.disconnect()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(attempts, 0)
        XCTAssertFalse(controller.ready)
        XCTAssertNil(controller.pairingWarning)
    }
}
