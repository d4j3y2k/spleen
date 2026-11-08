import Foundation
import CryptoKit

/// Exact reviewed payloads only. No automatic credentials or open-ended allowance.
public struct AttentionTrialManifest: Codable {
    public let configuration: DecisionsTrialConfiguration
    public let approvedBodyHashes: [String]
    public init(configuration: DecisionsTrialConfiguration, bodies: [Data]) {
        self.configuration = configuration
        approvedBodyHashes = bodies.map(Self.fingerprint)
    }
    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func permits(_ body: Data) -> Bool {
        !approvedBodyHashes.isEmpty && approvedBodyHashes.count <= 20 &&
        approvedBodyHashes.contains(Self.fingerprint(body))
    }
}
public final class ReviewedAttentionTransport: DecisionsTransport {
    private let manifest: AttentionTrialManifest
    private let underlying: DecisionsTransport
    public init(manifest: AttentionTrialManifest, underlying: DecisionsTransport) {
        self.manifest = manifest; self.underlying = underlying
    }
    public func send(body: Data, completion: @escaping (Result<Data, Error>) -> Void) -> (() -> Void) {
        guard manifest.permits(body) else { completion(.failure(DecisionsTrialError.invalidConfiguration)); return {} }
        return underlying.send(body: body, completion: completion)
    }
}
