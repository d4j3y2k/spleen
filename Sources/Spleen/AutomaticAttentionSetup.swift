import Foundation
import SpleenCore

/// Standing opt-in for assessment on open. Stores the key file's path, never the key.
struct AutomaticAttentionConsent: Codable {
    var enabled: Bool
    let id: String
    let dailyLimit: Int
    let credentialPath: String
    let scope: String
    /// What the user agreed to send. v2 raised a request from 6,000 to 20,000 bytes, so a
    /// v1 consent no longer covers what is sent and has to be given again.
    static let scopeName = "visible-codex-on-open-v2"
    static let supersededScopeNames: Set<String> = ["visible-codex-on-open-v1"]
    /// Daily ledgers keep their first name, so a renewed consent continues today's count.
    static let ledgerName = "visible-codex-on-open-v1"
    /// A request that failed may be tried again; every attempt counts toward the daily limit.
    static let attemptsPerRequest = 3
    static let defaultDailyLimit = 100
    static func location(_ directory: URL) -> URL { directory.appendingPathComponent("assessment-on-open.json") }
    static func ledgerDirectory(_ directory: URL) -> URL { directory.appendingPathComponent("assessment-ledgers", isDirectory: true) }
    func save(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self), url = Self.location(directory)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// Ledgers are not named by consent, so pausing and turning assessment back on
    /// (a new consent ID) continues today's count instead of starting a fresh allowance.
    func transport(in directory: URL) throws -> DecisionsTransport {
        guard enabled, scope == Self.scopeName, credentialPath.hasPrefix("/") else { throw DecisionsTrialError.invalidConfiguration }
        let credential = try attentionCredential(at: URL(fileURLWithPath: credentialPath))
        return try DailyDecisionsTransport(credential: credential, directory: Self.ledgerDirectory(directory),
                                           consentID: Self.ledgerName, dailyLimit: dailyLimit, requestTimeout: 5,
                                           requestByteLimit: SessionAssessmentInput.maximumRequestBytes,
                                           attemptsPerRequest: Self.attemptsPerRequest)
    }
    /// An enabled consent given for an earlier, smaller scope. Nothing is sent under it.
    struct SupersededScope: Error {}
    static func load(from directory: URL) throws -> AutomaticAttentionConsent? {
        let url = location(directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count < 8192 else { throw DecisionsTrialError.invalidConfiguration }
        let consent = try JSONDecoder().decode(Self.self, from: data)
        if supersededScopeNames.contains(consent.scope) {
            if consent.enabled { throw SupersededScope() }
            return nil
        }
        guard consent.scope == scopeName, consent.credentialPath.hasPrefix("/"), (1...100).contains(consent.dailyLimit) else {
            throw DecisionsTrialError.invalidConfiguration
        }
        return consent.enabled ? consent : nil
    }
}
