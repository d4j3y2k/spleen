import Foundation

/// Spleen's data files hold conversation titles, project paths and message excerpts.
/// Keep them, and the folder that holds them, readable only by this account.
public enum PrivateFile {
    public static func write(_ data: Data, to url: URL) throws {
        try createDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Creates the folder owner-only. An existing folder is left as it is; see `restrict`.
    public static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// Makes the data folder owner-only, including one created earlier with default
    /// permissions (0755), which let other local accounts read the files inside.
    public static func restrict(_ directory: URL) throws {
        try createDirectory(directory)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue, mode & 0o077 != 0 else { return }
        try FileManager.default.setAttributes([.posixPermissions: mode & 0o700], ofItemAtPath: directory.path)
    }
}
