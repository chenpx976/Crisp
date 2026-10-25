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

/// Injectable transport keeps controller regressions independent of real TVs.
@MainActor
protocol LGWebOSSocket: AnyObject {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func ping() async throws
    func close()
}

@MainActor
final class LGWebOSTransport: LGWebOSSocket {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask

    init(host: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: LGWebOSTrust(), delegateQueue: nil)
        socket = session.webSocketTask(with: URL(string: "wss://\(host):3001")!)
        socket.resume()
    }

    func send(_ data: Data) async throws {
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func receive() async throws -> Data {
        switch try await socket.receive() {
        case .string(let string): return Data(string.utf8)
        case .data(let data): return data
        @unknown default: throw URLError(.cannotParseResponse)
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func close() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
