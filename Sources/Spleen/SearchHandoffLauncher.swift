import AppKit
import SpleenCore

/// Uses the running/registered companion, including a sibling development checkout.
/// Never writes the query to disk or the clipboard, and never invokes a shell.
enum SearchHandoffLauncher {
    static func open(_ request: SearchHandoff, to app: SearchHandoff.App, completion: @escaping (Bool) -> Void) {
        guard let url = request.url(for: app), let application = applicationURL(for: app) else {
            completion(false); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = ["--background-launch"]
        let deliver = {
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { running, error in
                DispatchQueue.main.async { completion(running != nil && error == nil) }
            }
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty {
            // Explicit application launch honors startup arguments; URL launches may not.
            NSWorkspace.shared.openApplication(at: application, configuration: configuration) { running, error in
                DispatchQueue.main.async {
                    guard running != nil, error == nil else { completion(false); return }
                    deliver()
                }
            }
        } else { deliver() }
    }
    static func applicationURL(for app: SearchHandoff.App) -> URL? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first?.bundleURL,
           Bundle(url: running)?.bundleIdentifier == app.bundleID { return running }
        if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID),
           Bundle(url: registered)?.bundleIdentifier == app.bundleID { return registered }
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(app.rawValue)
            .appendingPathComponent("build/\(app.name).app")
        return Bundle(url: sibling)?.bundleIdentifier == app.bundleID ? sibling : nil
    }
}
