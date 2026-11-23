import AppKit
import Darwin
import SpleenCore

enum TerminalNavigationError: LocalizedError {
    case ended, automation, replaced, rexUnavailable, rexNotFrontmost, timeout
    var errorDescription: String? {
        switch self {
        case .ended: return "This terminal session ended or changed. Reopen the compass for the current sessions."
        case .replaced: return "Spleen was rebuilt or updated while it was running. Quit and reopen Spleen to switch terminal panes."
        case .automation: return "Couldn’t select the terminal pane. Check Spleen in System Settings → Privacy & Security → Automation."
        case .rexUnavailable: return "Couldn’t reach this Mac’s Rex session. Check that Rex and its local server are running."
        case .rexNotFrontmost: return "Couldn’t bring Rex to the front. Try opening the session again."
        case .timeout: return "The terminal took too long to respond. Try opening the session again."
        }
    }
}

struct TerminalObservation {
    let samples: [TerminalProcesses.Sample]
    let selected: TerminalSession?
    let problem: String?

    static func read(foreground: TerminalHost?) -> Self {
        let scanned = TerminalProcesses.scan()
        let titles = TerminalNavigation.rexTitles(for: scanned.map(\.session))
        let samples = scanned.map { row in
            titles[row.session.pid].map { TerminalProcesses.Sample(session: row.session.retitled($0), activity: row.activity) } ?? row
        }
        let sessions = samples.map(\.session)
        guard let host = foreground, sessions.contains(where: { $0.host == host }) else {
            return Self(samples: samples, selected: nil, problem: nil)
        }
        do { return Self(samples: samples, selected: try TerminalNavigation.selected(in: host, among: sessions), problem: nil) }
        catch { return Self(samples: samples, selected: nil, problem: error.localizedDescription) }
    }
}

enum TerminalNavigation {
    /// Fixed scripts receive identifiers as argv. Nothing from a session is executed as code.
    private static let script = #"""
    function run(argv) {
        const [host, action, target] = argv;
        const app = Application(host);
        if (!app.running()) throw Error("closed");
        if (host === "com.superlogical.rex") {
            // The app qualifies a CLI session ID with its host ID.
            const localID = s => s.id().split("/").pop();
            if (action === "open") {
                const matches = app.sessions().filter(s => !s.remote() && localID(s) === target);
                if (matches.length !== 1) throw Error("closed");
                app.show(matches[0]);
                app.activate();
            }
            const session = app.currentSession;
            return session.exists() && !session.remote() ? localID(session) : "";
        }
        if (host === "com.mitchellh.ghostty") {
            if (action === "open") {
                const pane = app.terminals().find(p => p.tty() === target);
                if (!pane) throw Error("closed");
                app.focus(pane);
                app.activate();
            }
            if (!app.windows().length) return "";
            return app.frontWindow.selectedTab.focusedTerminal.tty();
        }
        if (action === "open") {
            for (const win of app.windows()) {
                const tab = win.tabs().find(t => t.tty() === target);
                if (!tab) continue;
                tab.selected = true;
                win.frontmost = true;
                app.activate();
                break;
            }
        }
        if (!app.windows().length) return "";
        return app.windows[0].selectedTab.tty();
    }
    """#

    private static func apple(_ host: TerminalHost, open target: String? = nil) throws -> String {
        // macOS identifies the sender by Spleen's executable. Once a rebuild or update
        // replaces that file, it refuses these events whatever the Automation setting says.
        var path = [CChar](repeating: 0, count: 4096)
        let failure: TerminalNavigationError = proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 ? .automation : .replaced
        let data = try run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script, "--",
            host.bundleID, target == nil ? "selected" : "open", target ?? ""], timeout: 8, failure: failure)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct RexSessionList: Decodable {
        struct Entry: Decodable { let session_id: String }
        let sessions: [Entry]
    }
    private struct RexSession: Decodable {
        struct Window: Decodable {
            struct Layer: Decodable {
                struct Block: Decodable { let block_id: String; let flavor: String }
                let blocks: [Block]
            }
            let window_id: String
            let focused_block_id: String?
            let layers: [Layer]
        }
        let active_window_id: String?
        let windows: [Window]
    }
    private struct RexProcess: Decodable {
        struct ProcessID: Decodable { let pid: Int32 }
        let foreground: ProcessID?
    }
    private static func rex(_ args: [String]) throws -> Data {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: TerminalHost.rex.bundleID).first?.bundleURL else {
            throw TerminalNavigationError.rexUnavailable
        }
        let cli = app.appendingPathComponent("Contents/Helpers/Rex Server.rex/Contents/MacOS/rex")
        var socket = URLComponents()
        socket.scheme = "unix"; socket.host = ""
        socket.path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/rex/server.sock").path
        guard let server = socket.string else { throw TerminalNavigationError.rexUnavailable }
        return try run(cli.path, ["--autostart=false", "--server", server, "--timeout", "2s"] + args,
                       timeout: 3, failure: .rexUnavailable)
    }
    private static func inspect(_ id: String) throws -> RexSession {
        try JSONDecoder().decode(RexSession.self, from: rex(["session", "inspect", id, "--json"]))
    }
    private static func device(session: String, block: String) throws -> UInt32? {
        let process = try JSONDecoder().decode(RexProcess.self, from: rex(["block", "call", "-s", session, "-b", block, "process"]))
        guard let pid = process.foreground?.pid, let info = TerminalProcesses.info(pid), info.pbi_uid == getuid(),
              info.pbi_pgid == info.e_tpgid else { return nil }
        return info.e_tdev
    }

    private struct RexPane { let session: String, block: String }
    private struct RexTitle: Decodable {
        struct Owner: Decodable { let pid: Int32 }
        let title: String
        let owner: Owner?
    }
    /// Visits this Mac's Rex shell panes with each one's foreground terminal until `visit` returns true.
    private static func eachRexPane(until deadline: TimeInterval, _ visit: (RexPane, UInt32) throws -> Bool) throws {
        let list = try JSONDecoder().decode(RexSessionList.self, from: rex(["ls", "--json"]))
        for entry in list.sessions {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw TerminalNavigationError.timeout }
            let id = entry.session_id
            guard let layout = try? inspect(id) else { continue }
            for block in layout.windows.flatMap(\.layers).flatMap(\.blocks) where block.flavor == "com.superlogical.terminal.shell" {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw TerminalNavigationError.timeout }
                guard let tty = try? device(session: id, block: block.block_id) else { continue }
                if try visit(RexPane(session: id, block: block.block_id), tty) { return }
            }
        }
    }

    // A process keeps its pane, so each one is looked up once and then asked only for its title.
    private static var rexPanes: [String: RexPane] = [:]
    private static let rexPaneLock = NSLock()

    /// The title Rex lists each Claude Code tab under, by process. A title set by
    /// another program in the pane, such as the shell, is not the session's.
    static func rexTitles(for sessions: [TerminalSession]) -> [Int32: String] {
        let live = sessions.filter { $0.host == .rex && $0.provider == .claude }
        guard !live.isEmpty else { return [:] }
        func key(_ session: TerminalSession) -> String { "\(session.pid)-\(session.startMicroseconds)" }
        let keys = Set(live.map(key))
        rexPaneLock.lock()
        var panes = rexPanes.filter { keys.contains($0.key) }
        rexPaneLock.unlock()
        if panes.count < keys.count {
            var found: [UInt32: RexPane] = [:]
            try? eachRexPane(until: ProcessInfo.processInfo.systemUptime + 3) { pane, device in found[device] = pane; return false }
            for session in live where panes[key(session)] == nil {
                if let device = TerminalProcesses.info(session.pid)?.e_tdev { panes[key(session)] = found[device] }
            }
        }
        var titles: [Int32: String] = [:]
        for session in live {
            guard let pane = panes[key(session)] else { continue }
            guard let data = try? rex(["block", "call", "-s", pane.session, "-b", pane.block, "title"]),
                  let value = try? JSONDecoder().decode(RexTitle.self, from: data) else {
                panes[key(session)] = nil // The pane closed or moved; find it again on the next scan.
                continue
            }
            if value.owner?.pid == session.pid, let title = TerminalSession.tabTitle(value.title, provider: session.provider) {
                titles[session.pid] = title
            }
        }
        rexPaneLock.lock()
        rexPanes = panes
        rexPaneLock.unlock()
        return titles
    }

    static func selected(in host: TerminalHost, among sessions: [TerminalSession]) throws -> TerminalSession? {
        let selected = try apple(host)
        if host != .rex { return sessions.first { $0.host == host && $0.tty == selected } }
        guard !selected.isEmpty else { return nil }
        let layout = try inspect(selected)
        guard let window = layout.windows.first(where: { $0.window_id == layout.active_window_id }),
              let block = window.focused_block_id, let tty = try device(session: selected, block: block) else { return nil }
        return sessions.first { $0.host == .rex && TerminalProcesses.info($0.pid)?.e_tdev == tty }
    }

    static func open(_ session: TerminalSession) throws {
        func stillActive() -> Bool {
            TerminalProcesses.scan().contains { session.matchesLiveRoute($0.session) }
        }
        guard stillActive() else { throw TerminalNavigationError.ended }
        if session.host != .rex {
            guard try apple(session.host, open: session.tty) == session.tty, stillActive() else { throw TerminalNavigationError.ended }
            return
        }
        guard let tty = TerminalProcesses.info(session.pid)?.e_tdev else { throw TerminalNavigationError.ended }
        var arrived = false
        try eachRexPane(until: ProcessInfo.processInfo.systemUptime + 8) { pane, device in
            guard device == tty else { return false }
            guard stillActive() else { throw TerminalNavigationError.ended }
            _ = try rex(["focus", "-s", pane.session, pane.block])
            _ = try apple(.rex, open: pane.session)
            try confirmRexArrival {
                try selected(in: .rex, among: [session]) != nil
            }
            guard stillActive() else { throw TerminalNavigationError.ended }
            arrived = true
            return true
        }
        guard arrived else { throw TerminalNavigationError.ended }
    }

    // Rex can report the requested session and pane while another app still owns
    // the keyboard. Allow time for macOS activation and the Rex window switch.
    static func confirmRexArrival(timeout: TimeInterval = 2,
                                  isFrontmost: () -> Bool = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TerminalHost.rex.bundleID },
                                  paneIsSelected: () throws -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if isFrontmost(), try paneIsSelected(), isFrontmost() { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw isFrontmost() ? TerminalNavigationError.ended : .rexNotFrontmost
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Bound output and elapsed time, including an unresponsive application or Automation dialog.
    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval,
                            failure: TerminalNavigationError) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw failure }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        let fd = output.fileHandleForReading.fileDescriptor
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while ProcessInfo.processInfo.systemUptime < deadline {
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 100)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw failure }
            if ready == 0 { continue }
            let n = read(fd, &buffer, buffer.count)
            guard n >= 0, result.count + n <= 1_048_576 else { throw failure }
            if n == 0 {
                if process.isRunning { usleep(1_000); continue }
                guard process.terminationStatus == 0 else { throw failure }
                return result
            }
            result.append(contentsOf: buffer.prefix(n))
        }
        throw TerminalNavigationError.timeout
    }
}
