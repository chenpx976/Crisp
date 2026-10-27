import Foundation

extension LGWebOSVolumeController {
    func saveDevicePreferences() { devicePreferences.save(host: host) }

    func enableDeviceControls() {
        devicePreferences.extendedControls = true
        saveDevicePreferences()
        pairAgain()
    }

    func enableSettingsAccess() {
        devicePreferences.signedSettingsAccess = true
        saveDevicePreferences()
        pairAgain()
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return object
    }

    func readCurrentInput(timeout: Duration = .seconds(3)) async throws -> String? {
        let payload = try object(await call("com.webos.applicationManager/getForegroundAppInfo", timeout: timeout))
        let input = LGWebOSDeviceProtocol.input(appID: payload["appId"] as? String ?? "")
        deviceState.currentInput = input
        return input
    }

    func readOLEDBrightness() async throws -> Int {
        let data = try await call("settings/getSystemSettings", payload: ["category": "picture", "keys": ["backlight"]])
        guard let value = LGWebOSDeviceProtocol.oledBrightness(try object(data)) else {
            throw LGWebOSDeviceError(message: String(localized: "TV did not provide OLED pixel brightness."))
        }
        deviceState.oledBrightness = value
        return value
    }

    func setOLEDBrightness(_ value: Int) async throws {
        guard (0...100).contains(value) else { throw LGWebOSDeviceError(message: "Brightness must be between 0 and 100") }
        _ = try await call("settings/setSystemSettings", payload: ["category": "picture", "settings": ["backlight": value]])
        let actual = try await readOLEDBrightness()
        guard actual == value else {
            throw LGWebOSDeviceError(message: String(localized: "TV did not confirm the requested OLED brightness."))
        }
    }

    func switchTVInput(_ input: String) async throws {
        if deviceState.inputs.isEmpty { try await readTVInputs() }
        guard LGWebOSDeviceProtocol.isHDMI(input), deviceState.inputs.contains(where: { $0.id == input }) else {
            throw LGWebOSDeviceError(message: "Choose an HDMI input reported by the TV")
        }
        _ = try await call("tv/switchInput", payload: ["inputId": input])
        for _ in 0..<8 {
            try Task.checkCancellation()
            if try await readCurrentInput() == input { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LGWebOSDeviceError(message: String(localized: "TV input change was not confirmed."))
    }

    func readTVInputs() async throws {
        let payload = try object(await call("tv/getExternalInputList"))
        deviceState.inputs = LGWebOSDeviceProtocol.inputs(payload)
    }

    func refreshDeviceState() async {
        guard ready, devicePreferences.extendedControls else { return }
        var failures: [String] = []
        do {
            try await readTVInputs()
            let current = try await readCurrentInput()
            if devicePreferences.macInput.isEmpty, let current,
               deviceState.inputs.filter({ $0.connected }).map(\.id) == [current] {
                devicePreferences.macInput = current
                saveDevicePreferences()
            }
        } catch { failures.append(String(localized: "HDMI control") + ": " + error.localizedDescription) }
        do { _ = try await readOLEDBrightness() }
        catch { deviceState.oledBrightness = nil; failures.append(String(localized: "OLED brightness") + ": " + error.localizedDescription) }
        do {
            let payload = try object(await call("com.webos.service.tvpower/power/getPowerState"))
            deviceState.power = payload["state"] as? String
        } catch { failures.append(String(localized: "Power control") + ": " + error.localizedDescription) }
        if devicePreferences.wakeMACs.isEmpty {
            do {
                let payload = try object(await call("com.webos.service.connectionmanager/getinfo"))
                let addresses = ["wiredInfo", "wifiInfo"].compactMap { key -> String? in
                    guard let info = payload[key] as? [String: Any], let address = info["macAddress"] as? String,
                          LGWakeOnLAN.packet(address) != nil else { return nil }
                    return address
                }
                devicePreferences.wakeMACs = Array(Set(addresses)).sorted()
                saveDevicePreferences()
            } catch { failures.append(String(localized: "Network wake") + ": " + error.localizedDescription) }
        }
        deviceError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func sleepTVIfOnMacInput() async throws {
        guard devicePreferences.canSyncPower else {
            throw LGWebOSDeviceError(message: String(localized: "Set the Mac HDMI input and TV MAC address first."))
        }
        let current = try await readCurrentInput(timeout: .milliseconds(800))
        guard LGWebOSPowerPolicy.shouldSleep(enabled: true, preferences: devicePreferences, currentInput: current) else { return }
        _ = try await call("system/turnOff", timeout: .milliseconds(800))
    }

    func wakeTV() async throws {
        guard devicePreferences.canSyncPower else {
            throw LGWebOSDeviceError(message: String(localized: "Set the Mac HDMI input and TV MAC address first."))
        }
        for _ in 0..<3 {
            try Task.checkCancellation()
            for address in devicePreferences.wakeMACs { try sendWakePacket(address, host) }
            try await Task.sleep(for: .milliseconds(150))
        }
        if !ready { connect() }
        let deadline = ContinuousClock.now + .seconds(30)
        var nextPacket = ContinuousClock.now + .seconds(2)
        var nextScreenRequest = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            // Some TVs ignore magic packets while still transitioning into standby.
            // Keep retrying after that transition, rather than only at wake start.
            if ContinuousClock.now >= nextPacket {
                for address in devicePreferences.wakeMACs { try sendWakePacket(address, host) }
                nextPacket = ContinuousClock.now + .seconds(2)
            }
            if ready {
                let payload: [String: Any]
                do { payload = try object(await call("com.webos.service.tvpower/power/getPowerState", timeout: .seconds(2))) }
                catch is URLError {
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
                deviceState.power = payload["state"] as? String
                let power = LGWebOSDeviceProtocol.powerName(deviceState.power)
                if power == "active" {
                    await refreshDeviceState()
                    if devicePreferences.switchOnWake { try await switchTVInput(devicePreferences.macInput) }
                    return
                }
                if ["screenoff", "activestandby"].contains(power), ContinuousClock.now >= nextScreenRequest {
                    // Network-active standby may accept screen-on even if WOL is
                    // disabled. Failure here must not prevent later magic packets.
                    _ = try? await call("com.webos.service.tvpower/power/turnOnScreen", timeout: .seconds(1))
                    nextScreenRequest = ContinuousClock.now + .seconds(2)
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LGWebOSDeviceError(message: String(localized: "TV did not wake. Enable network wake on the TV."))
    }
}
