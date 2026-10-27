import Foundation
import Darwin

enum LGWakeOnLAN {
    static func packet(_ address: String) -> Data? {
        let compact = address.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        guard compact.count == 12, compact.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        let chars = Array(compact)
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: 12, by: 2) {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        guard bytes != Array(repeating: 0, count: 6), bytes[0] & 1 == 0 else { return nil }
        return Data(Array(repeating: UInt8(0xFF), count: 6) + Array(repeating: bytes, count: 16).flatMap { $0 })
    }

    static func send(mac: String, host: String) throws {
        guard let packet = packet(mac), LGWebOSProtocol.host(host) != nil else {
            throw LGWebOSDeviceError(message: "Invalid TV MAC or IP address")
        }
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(.EIO)
        }
        var sent = false
        for destination in ["255.255.255.255", host] {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(9).bigEndian
            guard inet_pton(AF_INET, destination, &address.sin_addr) == 1 else { continue }
            let count = packet.withUnsafeBytes { buffer in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, buffer.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            sent = sent || count == packet.count
        }
        guard sent else { throw POSIXError(.EIO) }
    }
}
