import Foundation

private let traceQueue = DispatchQueue(label: "spleen.diagnostics", qos: .utility)
private let diagnosticTraceURL: URL? = {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--diagnostics"), args.indices.contains(i + 1) else { return nil }
    return URL(fileURLWithPath: args[i + 1])
}()

var diagnosticTracingEnabled: Bool { diagnosticTraceURL != nil }

// Fixed navigation vocabulary only. Space is eligible only while it means a
// compass confirmation; text-entry characters are never passed to tracing.
enum DiagnosticNavigationKey: String {
    case up, right, down, left, enter, keypadEnter, confirmSpace, escape
    init?(keyCode: UInt16, compass: Bool) {
        switch keyCode {
        case 126: self = .up
        case 124: self = .right
        case 125: self = .down
        case 123: self = .left
        case 36: self = .enter
        case 76: self = .keypadEnter
        case 49 where compass: self = .confirmSpace
        case 53: self = .escape
        default: return nil
        }
    }
}

func traceNavigation(_ key: DiagnosticNavigationKey?, _ route: String) {
    guard diagnosticTracingEnabled, let key else { return }
    trace("input.\(key.rawValue).\(route)")
}

// Opt-in test trace. Only event names and timestamps; no queries, destinations, or external app data.
func trace(_ event: String) {
    guard let url = diagnosticTraceURL else { return }
    let record: [String: Any] = ["event": event, "time": Date().timeIntervalSince1970,
                                 "uptime": ProcessInfo.processInfo.systemUptime]
    guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
    data.append(10)
    let line = data
    // Opting into diagnostics must not add filesystem latency to shortcut delivery.
    traceQueue.async {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
              size.intValue + line.count <= 1_000_000,
              let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        do { try file.seekToEnd(); try file.write(contentsOf: line) } catch {}
    }
}

func flushDiagnosticTrace() { traceQueue.sync {} }
