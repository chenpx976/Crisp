import Foundation

struct LGWebOSControlRequest: Decodable {
    enum Command: String, Decodable {
        case connect = "webos.connect"
        case status = "webos.status"
        case volume = "webos.volume"
        case disconnect = "webos.disconnect"
    }
    let command: Command
    let display: UInt32
    let host: String?
    let volume: Double?
}

struct LGWebOSControlResponse: Encodable {
    let ok: Bool
    var status: String?
    var ready: Bool?
    var volume: Double?
    var error: String?
    var warning: String?
}
