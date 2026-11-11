import Foundation
import Darwin
import SpleenCore

func attentionTrialTransport(directory: URL, arguments: [String]) throws -> DecisionsTransport? {
    guard let index = arguments.firstIndex(of: "--attention-trial") else { return nil }
    guard arguments.indices.contains(index + 1), let credentialIndex = arguments.firstIndex(of: "--attention-credential-file"),
          arguments.indices.contains(credentialIndex + 1), arguments[index + 1].hasPrefix("/"),
          arguments[credentialIndex + 1].hasPrefix("/") else { throw DecisionsTrialError.invalidConfiguration }
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
    guard data.count <= 32768 else { throw DecisionsTrialError.invalidConfiguration }
    let manifest = try JSONDecoder().decode(AttentionTrialManifest.self, from: data)
    guard Date() < manifest.configuration.expiresAt else { throw DecisionsTrialError.expired }
    let key = try attentionCredential(at: URL(fileURLWithPath: arguments[credentialIndex + 1]))
    let ledger = DecisionsTrialLedger(url: directory.appendingPathComponent("attention-trial-ledger.json"), configuration: manifest.configuration,
                                      requestByteLimit: SessionAssessmentInput.maximumRequestBytes)
    return ReviewedAttentionTransport(manifest: manifest, underlying: DecisionsHTTPTransport(approvedCredential: key, ledger: ledger))
}

/// Explicit local export. Reads at most eight recent sessions and exports at most two complete windows; never sends HTTP.
func exportAttentionTrial(directory: URL, output: URL) throws {
    let catalog = try CatalogCache.load(from: directory.appendingPathComponent("catalog.json"))
    let fresh = try installedCodexCatalogClient().fetch(policy: catalog.effectivePolicy)
    let entries = Array(fresh.entries.filter { catalog.includes($0) && !catalog.hiddenIDs.contains($0.id) }
        .sorted { $0.updatedAt > $1.updatedAt }.prefix(8))
    let notes = try installedCodexCatalogClient().insights(entries: entries, policy: catalog.effectivePolicy)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var bodies: [Data] = []
    for note in notes {
        guard bodies.count < 2, let window = note.window, !window.incomplete, !window.unansweredUser else { continue }
        let body = try SessionAssessmentInput(window: window).body()
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let input = object?["input"] as? [[String: Any]]
        let content = input?.first?["content"] as? [[String: Any]]
        let evidence = content?.first?["data"] as? [String: Any]
        guard evidence?["incomplete"] as? Bool == false else { continue }
        let url = output.appendingPathComponent("request-\(bodies.count + 1).json")
        try body.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        bodies.append(body)
    }
    guard !bodies.isEmpty else { throw DecisionsTrialError.invalidConfiguration }
    let config = try DecisionsTrialConfiguration(id: "attention-\(UUID().uuidString)", maximumRequests: bodies.count,
        expiresAt: Date().addingTimeInterval(86400))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(AttentionTrialManifest(configuration: config, bodies: bodies)).write(to: output.appendingPathComponent("trial.json"), options: .atomic)
    print("Prepared \(bodies.count) local request(s), at most \(bodies.map(\.count).max() ?? 0) bytes each; zero API calls. Trial expires in 24 hours.")
}

/// Explicitly selected raw-key or .env file. No discovery, symlink following, output, or extra secret copies.
func attentionCredential(at url: URL) throws -> String {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { throw DecisionsTrialError.invalidConfiguration }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_size > 0, info.st_size <= 16384,
          info.st_mode & 0o077 == 0 else { throw DecisionsTrialError.invalidConfiguration }
    var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count < 0 { if errno == EINTR { continue }; throw DecisionsTrialError.invalidConfiguration }
        if count == 0 { break }
        guard data.count + count <= 16384 else { throw DecisionsTrialError.invalidConfiguration }
        data.append(contentsOf: bytes.prefix(count))
    }
    guard let text = String(data: data, encoding: .utf8) else { throw DecisionsTrialError.invalidConfiguration }
    let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
    let assignments = lines.compactMap { line -> String? in
        let normalized = line.hasPrefix("export ") ? String(line.dropFirst(7)) : line
        guard let equal = normalized.firstIndex(of: "="), normalized[..<equal].trimmingCharacters(in: .whitespaces) == "OPENAI_API_KEY" else { return nil }
        var value = normalized[normalized.index(after: equal)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, (first == "\"" || first == "'"), value.last == first { value = String(value.dropFirst().dropLast()) }
        return value
    }
    guard assignments.count <= 1 else { throw DecisionsTrialError.invalidConfiguration }
    let key = assignments.first ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard key.hasPrefix("sk-"), key.count <= 4096, !key.contains(where: { $0.isWhitespace }), !key.contains("=") else {
        throw DecisionsTrialError.invalidConfiguration
    }
    return key
}
