import Foundation
import SpleenCore

/// Standing opt-in for assessment on open. Stores the key file's path, never the key.
struct AutomaticAttentionConsent: Codable {
    var enabled: Bool
    let id: String
    let dailyLimit: Int
    let credentialPath: String
    let scope: String
    static let scopeName = "visible-codex-on-open-v1"
    static let defaultDailyLimit = 100
    static func location(_ directory: URL) -> URL { directory.appendingPathComponent("assessment-on-open.json") }
    static func ledgerDirectory(_ directory: URL) -> URL { directory.appendingPathComponent("assessment-ledgers", isDirectory: true) }
    func save(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self), url = Self.location(directory)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// Ledgers are named by scope, not by consent, so pausing and turning assessment back on
    /// (a new consent ID) continues today's count instead of starting a fresh allowance.
    func transport(in directory: URL) throws -> DecisionsTransport {
        guard enabled, scope == Self.scopeName, credentialPath.hasPrefix("/") else { throw DecisionsTrialError.invalidConfiguration }
        let credential = try attentionCredential(at: URL(fileURLWithPath: credentialPath))
        return try DailyDecisionsTransport(credential: credential, directory: Self.ledgerDirectory(directory),
                                           consentID: Self.scopeName, dailyLimit: dailyLimit, requestTimeout: 5)
    }
    static func load(from directory: URL) throws -> AutomaticAttentionConsent? {
        let url = location(directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count < 8192 else { throw DecisionsTrialError.invalidConfiguration }
        let consent = try JSONDecoder().decode(Self.self, from: data)
        guard consent.scope == scopeName, consent.credentialPath.hasPrefix("/"), (1...100).contains(consent.dailyLimit) else {
            throw DecisionsTrialError.invalidConfiguration
        }
        return consent.enabled ? consent : nil
    }
}
