import XCTest
import Foundation

final class LGWebOSDeviceTests: XCTestCase {
    func testWakePacketLayoutAndInvalidAddresses() throws {
        let packet = try XCTUnwrap(LGWakeOnLAN.packet("00:11:22:33:44:55"))
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), Array(repeating: 255, count: 6))
        for offset in stride(from: 6, to: 102, by: 6) {
            XCTAssertEqual(Array(packet[offset..<offset + 6]), [0, 17, 34, 51, 68, 85])
        }
        XCTAssertEqual(packet, LGWakeOnLAN.packet("00-11-22-33-44-55"))
        for invalid in ["", "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff", "01:11:22:33:44:55", "00112233445", "00112233445566", "zz1122334455"] {
            XCTAssertNil(LGWakeOnLAN.packet(invalid), invalid)
        }
    }

    func testOLEDBrightnessDoesNotConfuseBlackLevelWithBacklight() {
        XCTAssertEqual(LGWebOSDeviceProtocol.oledBrightness(["settings": ["backlight": 40, "brightness": 50]]), 40)
        XCTAssertEqual(LGWebOSDeviceProtocol.oledBrightness(["settings": ["backlight": "0"]]), 0)
        XCTAssertEqual(LGWebOSDeviceProtocol.oledBrightness(["settings": ["backlight": "100"]]), 100)
        for value in [true, -1, 101, "bad", 3.5] as [Any] {
            XCTAssertNil(LGWebOSDeviceProtocol.oledBrightness(["settings": ["backlight": value]]))
        }
        XCTAssertNil(LGWebOSDeviceProtocol.oledBrightness(["settings": ["brightness": 50]]))
    }

    func testOnlyReportedHDMIInputsAreAcceptedAndAppsAreNotInputs() {
        let inputs = LGWebOSDeviceProtocol.inputs(["devices": [
            ["id": "HDMI_2", "label": "Mac", "connected": true],
            ["id": "HDMI_4", "label": "Console", "connected": false],
            ["id": "AV_1", "label": "AV"], ["id": "HDMI_9"]
        ]])
        XCTAssertEqual(inputs.map(\.id), ["HDMI_2", "HDMI_4"])
        XCTAssertEqual(inputs.first?.label, "Mac")
        XCTAssertEqual(inputs.first?.connected, true)
        XCTAssertEqual(LGWebOSDeviceProtocol.input(appID: "com.webos.app.hdmi2"), "HDMI_2")
        XCTAssertNil(LGWebOSDeviceProtocol.input(appID: "netflix"))
        XCTAssertNil(LGWebOSDeviceProtocol.input(appID: "com.webos.app.hdmi9"))
    }

    func testSleepRequiresOptInWakeAddressAndCurrentMacInput() {
        var preferences = LGWebOSDevicePreferences()
        XCTAssertFalse(preferences.powerSync)
        XCTAssertFalse(preferences.canSyncPower)
        preferences.extendedControls = true
        preferences.macInput = "HDMI_2"
        preferences.wakeMACs = ["00:11:22:33:44:55"]
        XCTAssertTrue(LGWebOSPowerPolicy.shouldSleep(enabled: true, preferences: preferences, currentInput: "HDMI_2"))
        XCTAssertFalse(LGWebOSPowerPolicy.shouldSleep(enabled: false, preferences: preferences, currentInput: "HDMI_2"))
        XCTAssertFalse(LGWebOSPowerPolicy.shouldSleep(enabled: true, preferences: preferences, currentInput: "HDMI_1"))
        XCTAssertFalse(LGWebOSPowerPolicy.shouldSleep(enabled: true, preferences: preferences, currentInput: nil))
        preferences.wakeMACs = []
        XCTAssertFalse(LGWebOSPowerPolicy.shouldSleep(enabled: true, preferences: preferences, currentInput: "HDMI_2"))
        preferences.wakeMACs = ["00:11:22:33:44:55"]
        preferences.extendedControls = false
        XCTAssertFalse(LGWebOSPowerPolicy.shouldSleep(enabled: true, preferences: preferences, currentInput: "HDMI_2"))
    }

    func testPreferencesDecodeSafelyAndInputNamesMatchShortcuts() throws {
        let preferences = try JSONDecoder().decode(LGWebOSDevicePreferences.self, from: Data("{}".utf8))
        XCTAssertFalse(preferences.powerSync)
        XCTAssertFalse(preferences.extendedControls)
        XCTAssertTrue(preferences.inputShortcuts.isEmpty)
        for value in ["hdmi2", "HDMI 2", "HDMI_2", " HDMI_2 "] {
            XCTAssertEqual(LGWebOSDeviceProtocol.input(userValue: value), "HDMI_2")
        }
        XCTAssertNil(LGWebOSDeviceProtocol.input(userValue: "HDMI_5"))
        XCTAssertNil(LGWebOSDeviceProtocol.input(userValue: "TV"))
    }

    func testPowerStateNamesAllowFirmwareSpacingVariations() {
        XCTAssertEqual(LGWebOSDeviceProtocol.powerName("Active Standby"), "activestandby")
        XCTAssertEqual(LGWebOSDeviceProtocol.powerName("ActiveStandby"), "activestandby")
        XCTAssertEqual(LGWebOSDeviceProtocol.powerName("Screen Off"), "screenoff")
        XCTAssertEqual(LGWebOSDeviceProtocol.powerName("ScreenOff"), "screenoff")
        XCTAssertEqual(LGWebOSDeviceProtocol.powerName(nil), "")
    }

    func testSignedSettingsProfileRequiresSeparateOptIn() throws {
        for registration in [LGWebOSProtocol.registration(key: nil, extended: true),
                             LGWebOSProtocol.registration(key: nil, settingsAccess: true)] {
            let payload = try XCTUnwrap(registration["payload"] as? [String: Any])
            let manifest = try XCTUnwrap(payload["manifest"] as? [String: Any])
            XCTAssertNil(manifest["signed"])
        }
        let registration = LGWebOSProtocol.registration(key: nil, extended: true, settingsAccess: true)
        let payload = try XCTUnwrap(registration["payload"] as? [String: Any])
        let manifest = try XCTUnwrap(payload["manifest"] as? [String: Any])
        let signed = try XCTUnwrap(manifest["signed"] as? [String: Any])
        XCTAssertTrue((signed["permissions"] as? [String] ?? []).contains("WRITE_SETTINGS"))
        XCTAssertEqual((manifest["signatures"] as? [[String: Any]])?.count, 1)
        XCTAssertFalse(LGWebOSDevicePreferences().signedSettingsAccess)
    }

    func testExtendedPairingRetainsAudioAndAddsOnlyRequestedDeviceCapabilities() throws {
        let registration = LGWebOSProtocol.registration(key: nil, extended: true)
        let payload = try XCTUnwrap(registration["payload"] as? [String: Any])
        let manifest = try XCTUnwrap(payload["manifest"] as? [String: Any])
        let permissions = try XCTUnwrap(manifest["permissions"] as? [String])
        XCTAssertTrue(permissions.contains("CONTROL_AUDIO"))
        XCTAssertTrue(permissions.contains("CONTROL_INPUT_TV"))
        XCTAssertTrue(permissions.contains("CONTROL_POWER"))
        XCTAssertTrue(permissions.contains("READ_SETTINGS"))
        XCTAssertFalse(permissions.contains("TEST_SECURE"))
        XCTAssertFalse(permissions.contains("CONTROL_MOUSE_AND_KEYBOARD"))
    }
}
