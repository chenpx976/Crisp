import Foundation

struct LGWebOSControlRequest: Decodable {
    enum Command: String, Decodable {
        case connect = "webos.connect"
        case status = "webos.status"
        case volume = "webos.volume"
        case disconnect = "webos.disconnect"
        case enable = "webos.enable"
        case enableSettings = "webos.enable-settings"
        case refresh = "webos.refresh"
        case brightness = "webos.brightness"
        case input = "webos.input"
        case wake = "webos.wake"
        case standby = "webos.standby"
        case config = "webos.config"
    }
    let command: Command
    let display: UInt32
    let host: String?
    let volume: Double?
    let brightness: Int?
    let input: String?
    let powerSync: Bool?
    let macInput: String?
    let macAddress: String?
    let switchOnWake: Bool?
}

struct LGWebOSControlResponse: Encodable {
    let ok: Bool
    var status: String?
    var ready: Bool?
    var volume: Double?
    var error: String?
    var warning: String?
    var device: LGWebOSDeviceState?
    var preferences: LGWebOSDevicePreferences?
    var deviceError: String?
}
