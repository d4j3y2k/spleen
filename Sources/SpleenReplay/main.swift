import Foundation
import Darwin
import CryptoKit
import SpleenEvaluation

private enum CLIError: Error { case arguments, input, output }
private struct Options {
    var synthetic = false
    var fixture: String?
    var output: String?
    var exportRequests: String?
    var writeSyntheticFixture: String?
    var json = false
    var help = false

    init(_ arguments: [String]) throws {
        var index = 0
        func value() throws -> String {
            index += 1
            guard arguments.indices.contains(index), !arguments[index].hasPrefix("--"),
                  !arguments[index].isEmpty, !arguments[index].contains("\0") else { throw CLIError.arguments }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--synthetic": guard !synthetic else { throw CLIError.arguments }; synthetic = true
            case "--fixture": guard fixture == nil else { throw CLIError.arguments }; fixture = try value()
            case "--output": guard output == nil else { throw CLIError.arguments }; output = try value()
            case "--export-requests": guard exportRequests == nil else { throw CLIError.arguments }; exportRequests = try value()
            case "--write-synthetic-fixture": guard writeSyntheticFixture == nil else { throw CLIError.arguments }; writeSyntheticFixture = try value()
            case "--json": json = true
            case "--help", "-h": help = true
            default: throw CLIError.arguments
            }
            index += 1
        }
        guard fixture == nil || (!synthetic && writeSyntheticFixture == nil) else { throw CLIError.arguments }
    }
}

private let help = """
SpleenReplay — offline ranking and readiness evaluation

Usage: SpleenReplay [--synthetic | --fixture FILE] [options]

  --synthetic                     Replay built-in synthetic scenarios (default).
  --fixture FILE                  Replay an explicit regular JSON fixture; never reads app stores.
  --output DIRECTORY              Write replay-report.json and replay-report.txt.
  --export-requests DIRECTORY      Write exact pre-choice request bodies for local review.
  --write-synthetic-fixture FILE   Save the built-in suite as editable JSON with ISO8601 dates.
  --json                          Print the full structured report.
  --help                          Show this help.

All event times are simulated. Canned/recorded replies are evaluated locally.
This tool has no credential setup, network requests, UI interaction, or chat dispatch.
Synthetic scores demonstrate control flow and arithmetic, not real model quality.
"""

private func loadFixture(_ path: String) throws -> Data {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw CLIError.input }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    let maximum = 1_048_576
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          (1...maximum).contains(Int(info.st_size)),
          let data = try file.read(upToCount: maximum + 1), data.count <= maximum else { throw CLIError.input }
    return data
}

private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(value)
    data.append(10)
    return data
}

private func write(_ data: Data, to url: URL) throws {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch { throw CLIError.output }
}

private func summary(_ report: ReplayReport) -> String {
    let totals = report.totals
    let labels = totals.labeledOpens
    var lines = [
        "Offline replay (evidence: \(report.evidenceKind.rawValue)); simulated timing, zero API calls.",
        "Synthetic scores demonstrate control flow, not real model quality.",
        "Opens: \(totals.opens); labeled: \(labels); dismissals: \(totals.dismissals).",
        "Available targets: \(totals.availableTargets)/\(labels); unavailable: \(totals.unavailableTargets).",
        "Pinned targets: \(totals.pinnedTargets); unpinned shortlist: \(totals.shortlistTargets)/\(totals.shortlistEligibleLabeledOpens); available outside shortlist: \(totals.outsideShortlistTargets)."
    ]
    let metrics: [(KeyPath<ReplayHits, Int>, String)] = [(\.center, "Center"), (\.top3, "Top three"), (\.compass, "Compass (five)")]
    for (key, label) in metrics {
        lines.append("\(label): local \(totals.local[keyPath: key])/\(labels), replay \(totals.deployed[keyPath: key])/\(labels); wins \(totals.pairedWins[keyPath: key]), losses \(totals.pairedLosses[keyPath: key]).")
    }
    lines += [
        "Timely valid response available at opening: \(totals.timelyValidResponseAvailableOpens)/\(totals.opens).",
        "Accepted reorder ready at opening: \(totals.acceptedReorderReadyOpens)/\(totals.opens).",
        "Virtual requests: \(totals.requests); responses: \(totals.responses); accepted valid: \(totals.acceptedValidResponses).",
        "Late responses: \(totals.lateResponses); stale: \(totals.staleResponses); invalid: \(totals.invalidResponses); superseded requests: \(totals.supersededRequests).",
        "Physical shortcut, screen, and live API latency are unmeasured."
    ]
    return lines.joined(separator: "\n") + "\n"
}

private func fail(_ message: String, code: Int32) -> Never {
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    exit(code)
}

do {
    let options = try Options(Array(CommandLine.arguments.dropFirst()))
    if options.help { print(help); exit(0) }
    let suite: ReplaySuite
    do { suite = try options.fixture.map { try RankingReplay.decodeSuite(loadFixture($0)) } ?? RankingReplay.syntheticSuite() }
    catch { throw CLIError.input }
    let report = try RankingReplay.run(suite)
    let reportData = try encoded(report)
    let text = summary(report)
    if let folder = options.output {
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try write(reportData, to: directory.appendingPathComponent("replay-report.json"))
        try write(Data(text.utf8), to: directory.appendingPathComponent("replay-report.txt"))
    }
    if let path = options.writeSyntheticFixture { try write(try encoded(suite), to: URL(fileURLWithPath: path)) }
    if let folder = options.exportRequests {
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        let requests = try RankingReplay.requests(suite)
        var manifest: [[String: Any]] = []
        for (index, body) in requests.enumerated() {
            let name = String(format: "request-%03d.json", index + 1)
            try write(body, to: directory.appendingPathComponent(name))
            let fingerprint = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            manifest.append(["file": name, "bytes": body.count, "sha256": fingerprint])
        }
        let manifestData = try JSONSerialization.data(withJSONObject: ["version": 1, "mode": "offline-only", "requests": manifest], options: [.prettyPrinted, .sortedKeys])
        try write(manifestData, to: directory.appendingPathComponent("manifest.json"))
    }
    if options.json { try FileHandle.standardOutput.write(contentsOf: reportData) }
    else { print(text, terminator: "") }
} catch CLIError.arguments {
    fail("Unknown, conflicting, or incomplete options. Use --help. No replay ran.", code: 2)
} catch CLIError.input {
    fail("The fixture must be a valid, bounded regular JSON file. No provider or network was accessed.", code: 2)
} catch CLIError.output {
    fail("Replay artifacts could not be written. No provider or network was accessed.", code: 1)
} catch is ReplayError {
    fail("The replay fixture is unsupported or invalid. No provider or network was accessed.", code: 2)
} catch {
    fail("The replay could not be completed because its fixture is unsupported or invalid. No provider or network was accessed.", code: 1)
}
