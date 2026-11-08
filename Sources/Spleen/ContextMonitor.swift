import Foundation
import Darwin

/// Watches Spleen's own directory because atomic JSON writes replace the file inode.
/// Only the selected file identity triggers a reload; unrelated writes do not.
final class ContextMonitor {
    private let source: DispatchSourceFileSystemObject
    init?(directory: URL, fileName: String = "context.json", changed: @escaping () -> Void) {
        // A fresh store may not exist yet, and background catalog persistence may
        // not have created it. Observation must not depend on that writer winning.
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let queue = DispatchQueue(label: "spleen.context-events", qos: .utility)
        let file = directory.appendingPathComponent(fileName)
        var previous: ContextFileIdentity?
        let inspect = {
            let current = ContextFileIdentity(file)
            guard current != previous else { return }
            previous = current
            changed()
        }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: queue)
        source.setEventHandler(handler: inspect)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        // Closes the load-before-watch race, including an initially absent file.
        queue.async(execute: inspect)
    }
    deinit { source.cancel() }
}

private enum ContextFileIdentity: Equatable {
    case missing
    case unavailable(Int32)
    case file(device: Int32, inode: UInt64, size: Int64,
              modifiedSeconds: Int, modifiedNanoseconds: Int)
    init(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            self = errno == ENOENT ? .missing : .unavailable(errno)
            return
        }
        self = .file(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                     modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec)
    }
}
