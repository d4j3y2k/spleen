import AppKit
import Darwin
import SpleenCore

/// Reads kernel process metadata only. A foreground process on a raw-mode terminal is
/// eligible if its ancestry leads back to one of the supported local terminal hosts.
enum TerminalProcesses {
    struct Sample {
        let session: TerminalSession
        let activity: RuntimeActivity?
    }
    private struct ClaudeRecord: Decodable {
        let pid: Int32
        let sessionId: UUID
        let procStart: String
        let kind: String
        let entrypoint: String
        let name: String?
        let status: String?
    }

    static func scan() -> [Sample] {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var bytes = 0
        guard sysctl(&mib, 4, nil, &bytes, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var rows = [kinfo_proc](repeating: kinfo_proc(), count: bytes / stride + 64)
        bytes = rows.count * stride
        guard sysctl(&mib, 4, &rows, &bytes, nil, 0) == 0 else { return [] }
        let processes = rows.prefix(bytes / stride)
        let parents = Dictionary(processes.map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid) }, uniquingKeysWith: { a, _ in a })
        var hosts: [Int32: TerminalHost] = [:]
        for host in TerminalHost.allCases {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: host.bundleID) {
                hosts[app.processIdentifier] = host
            }
        }
        func host(of pid: Int32) -> TerminalHost? {
            var cursor = pid
            for _ in 0..<64 {
                if let host = hosts[cursor] { return host }
                // login(1) can be root-owned between the user shell and the terminal app.
                guard let parent = parents[cursor], parent > 1, parent != cursor else { return nil }
                if let path = executable(parent), path.hasSuffix("/Contents/MacOS/rex") {
                    let bundle = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    if Bundle(url: bundle)?.bundleIdentifier == "com.superlogical.rex.server" {
                        hosts[parent] = .rex
                    }
                }
                cursor = parent
            }
            return nil
        }
        var found: [Sample] = []
        for row in processes where row.kp_eproc.e_ucred.cr_uid == getuid() && row.kp_eproc.e_tdev != -1 && row.kp_eproc.e_pgid == row.kp_eproc.e_tpgid {
            let pid = row.kp_proc.p_pid
            guard let path = executable(pid) else { continue }
            let binary = URL(fileURLWithPath: path).lastPathComponent
            let isClaude = binary == "claude" || URL(fileURLWithPath: path).deletingLastPathComponent().path.hasSuffix("/claude/versions")
            let isCodex = ["codex", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin"].contains(binary)
            guard isClaude || isCodex || binary == "node",
                  let host = host(of: pid), let info = info(pid), info.pbi_uid == getuid() else { continue }
            var name = [CChar](repeating: 0, count: 64)
            guard devname_r(row.kp_eproc.e_tdev, S_IFCHR, &name, Int32(name.count)) != nil else { continue }
            let tty = "/dev/" + String(cString: name)
            guard tty.hasPrefix("/dev/ttys"), rawTerminal(tty) else { continue }
            let start = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
            let provider: ContextProvider, id: UUID?, title: String?, activity: RuntimeActivity?
            if isClaude || binary == "node" {
                let record = claudeRecord(pid, started: info.pbi_start_tvsec)
                guard isClaude || record != nil else { continue }
                provider = .claude; id = record?.sessionId; title = record?.name; activity = claudeActivity(record?.status)
            } else {
                provider = .codex; id = codexThread(pid); title = nil; activity = nil
            }
            guard let folder = workingDirectory(pid), !folder.isEmpty else { continue }
            let session = TerminalSession(host: host, provider: provider, pid: pid, startMicroseconds: start, tty: tty,
                folder: folder, sessionID: id, title: title.flatMap { $0.isEmpty ? nil : String($0.prefix(240)) })
            found.append(Sample(session: session, activity: activity))
        }
        // If multiple CLI processes share a pane, resolve it only when there is a single candidate.
        // Multiple panes for one thread remain observable; the index presents one destination.
        let ttys = Dictionary(grouping: found, by: { $0.session.tty })
        return ttys.values.compactMap { $0.count == 1 ? $0[0] : nil }.sorted { $0.session.startedAt > $1.session.startedAt }
    }

    static func info(_ pid: Int32) -> proc_bsdinfo? {
        var result = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: result))
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &result, size) == size ? result : nil
    }

    private static func rawTerminal(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var attrs = termios()
        return tcgetattr(fd, &attrs) == 0 && (attrs.c_lflag & UInt(ICANON)) == 0
    }

    private static func executable(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
    private static func workingDirectory(_ pid: Int32) -> String? {
        var paths = proc_vnodepathinfo()
        let size = Int32(MemoryLayout.size(ofValue: paths))
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, size) == size else { return nil }
        return withUnsafeBytes(of: paths.pvi_cdir.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
    static func claudeActivity(_ status: String?) -> RuntimeActivity? {
        switch status {
        case "busy": return .working
        case "waiting": return .waitingForInput
        case "idle": return .idle
        default: return nil
        }
    }

    private static func claudeRecord(_ pid: Int32, started: UInt64) -> ClaudeRecord? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions/\(pid).json")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32_769), data.count <= 32_768,
              let record = try? JSONDecoder().decode(ClaudeRecord.self, from: data), record.pid == pid,
              record.kind == "interactive", record.entrypoint == "cli" else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let date = Date(timeIntervalSince1970: Double(started))
        for zone in [TimeZone.current, TimeZone(secondsFromGMT: 0)!] {
            formatter.timeZone = zone
            if formatter.date(from: record.procStart) == date { return record }
        }
        return nil
    }

    /// Match an open thread-writer lock by filename only. Multiple locks cannot identify
    /// the selected thread. Keep a process-scoped route in that case, never guess by cwd.
    private static func codexThread(_ pid: Int32) -> UUID? {
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 1024)
        let stride = MemoryLayout<proc_fdinfo>.stride
        let count = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))) / stride
        guard count > 0, count < fds.count else { return nil }
        var ids = Set<UUID>()
        for fd in fds.prefix(count) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var node = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout.size(ofValue: node))
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &node, size) == size else { continue }
            let path = withUnsafeBytes(of: node.pvip.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            guard path.contains("/thread-writer-locks/"), path.hasSuffix(".lock") else { continue }
            let file = URL(fileURLWithPath: path)
            if file.deletingLastPathComponent().lastPathComponent == "thread-writer-locks",
               let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) { ids.insert(id) }
        }
        return ids.count == 1 ? ids.first : nil
    }
}
