import XCTest

final class LGWebOSProtocolTests: XCTestCase {
    func testPrivateAddressValidation() {
        for address in ["10.0.0.2", "172.16.0.2", "172.31.255.2", "192.168.1.2"] {
            XCTAssertEqual(LGWebOSProtocol.host(address), address)
        }
        XCTAssertEqual(LGWebOSProtocol.host(" 192.168.001.20\n"), "192.168.1.20")
        for address in ["8.8.8.8", "127.0.0.1", "172.32.0.1", "172.15.0.1", "192.168.1.256",
                        "192.168.1", "192.168..1", "tv.local", "192.168.1.2:3001", "user@192.168.1.2"] {
            XCTAssertNil(LGWebOSProtocol.host(address), address)
        }
    }

    func testOldAndNewFirmwareVolume() {
        let old = LGWebOSProtocol.volume(["volume": 15, "muted": true])
        XCTAssertEqual(old?.level, 15)
        XCTAssertEqual(old?.muted, true)
        let modern = LGWebOSProtocol.volume(["volumeStatus": ["volume": 42, "muteStatus": false]])
        XCTAssertEqual(modern?.level, 42)
        XCTAssertEqual(modern?.muted, false)
        XCTAssertNil(LGWebOSProtocol.volume([:]))
        XCTAssertNil(LGWebOSProtocol.volume(["volume": true]))
        XCTAssertNil(LGWebOSProtocol.volume(["volume": -1]))
        XCTAssertNil(LGWebOSProtocol.volume(["volume": 101]))
    }

    func testPairingOnlyRequestsAudioAccessAndReusesKey() throws {
        let fresh = LGWebOSProtocol.registration(key: nil)
        let payload = try XCTUnwrap(fresh["payload"] as? [String: Any])
        XCTAssertNil(payload["client-key"])
        XCTAssertEqual(payload["pairingType"] as? String, "PROMPT")
        let manifest = try XCTUnwrap(payload["manifest"] as? [String: Any])
        XCTAssertEqual(manifest["permissions"] as? [String], ["CONTROL_AUDIO", "READ_AUDIO_VOLUME"])
        let saved = LGWebOSProtocol.registration(key: "test-key")
        XCTAssertEqual((saved["payload"] as? [String: Any])?["client-key"] as? String, "test-key")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: saved))
    }
}
