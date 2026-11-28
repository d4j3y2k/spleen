import Foundation

/// The built-in /usage command prints one tab-separated row per model group and window.
public enum AntigravityUsage {
    public static func resolveExecutable(home: URL, path: String?) -> URL? {
        UsageExecutable.resolve(UsageExecutable.candidates("agy", local: [home.appendingPathComponent(".local/bin/agy").path], path: path))
    }

    static func reading(_ report: Data, checkedAt: Date) -> Result<UsageReading, UsageProblem> {
        guard let text = String(data: report, encoding: .utf8) else { return .failure(UsageProblem(.incompatible)) }
        let rows = text.split(whereSeparator: \.isNewline)
        var windows: [UsageWindow] = []
        var seen = Set<String>()
        for row in rows {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 4, let group = UsageLabels.displayName(fields[0]),
                  fields[2].hasSuffix("%"), let remaining = Double(fields[2].dropLast()),
                  remaining.isFinite, (0...100).contains(remaining) else { continue }
            let minutes: Int
            switch fields[1].lowercased() {
            case "five hour limit remaining": minutes = 300
            case "weekly limit remaining": minutes = 10_080
            default: continue
            }

            let id = "antigravity." + UsageIdentity.hash([fields[0].lowercased()]) + ".\(minutes)"
            guard seen.insert(id).inserted else { continue }
            // An unused window can carry the Unix epoch as its reset.
            let reset = UsageTimestamp.parse(fields[3]).flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
            windows.append(UsageWindow(id: id, label: "\(UsageLabels.duration(minutes: minutes)) · \(group)",
                                       usedPercent: 100 - remaining, resetsAt: reset, durationMinutes: minutes))
        }
        guard !windows.isEmpty else { return .failure(UsageProblem(rows.isEmpty ? .offlineOrEmpty : .incompatible)) }
        return .success(UsageReading(windows: windows, checkedAt: checkedAt, owner: UsageOwner(user: .unknown)))
    }

    public static func fetch(executable resolve: @escaping () -> URL?, workingDirectory: @escaping () -> URL,
                             environment: [String: String], lane: HelperLane, request: UsageFetchRequest) {
        lane.submit(cancellation: request.cancellation, job: { lane, cancellation in
            guard let executable = resolve() else {
                request.emit(.finished(.failure(UsageProblem(cancellation.isCancelled ? .cancelled : .missingClient))))
                return
            }
            let launch = HelperLaunch(executable: executable, arguments: ["--print", "/usage"], environment: environment,
                                      workingDirectory: workingDirectory())
            let checkedAt = Date()
            BoundedHelper.exchange(launch, limits: .usage, cancellation: cancellation, lane: lane,
                                   body: { try $0.readReport() }, deliver: { result in
                request.emit(.finished(result.mapError { UsageProblem(UsageHelperFailure.map($0)) }
                    .flatMap { reading($0, checkedAt: checkedAt) }))
            })
        }, dropped: { request.emit(.finished(.failure(UsageProblem(.cancelled)))) })
    }
}
