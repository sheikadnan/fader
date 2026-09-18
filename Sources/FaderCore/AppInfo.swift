import AppKit
import Foundation

/// Display metadata for running processes. Kept apart from the HAL layer so
/// audio code never depends on AppKit.
public enum AppInfo {

    private static var cache: [pid_t: NSRunningApplication] = [:]
    private static let cacheLock = NSLock()

    public static func application(pid: pid_t) -> NSRunningApplication? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[pid], cached.processIdentifier == pid { return cached }
        let app = NSRunningApplication(processIdentifier: pid)
        cache[pid] = app
        return app
    }

    public static func executablePath(pid: pid_t) -> String? {
        application(pid: pid)?.executableURL?.path
    }

    /// Prefers the app the user recognises over the helper process that
    /// actually owns the audio stream.
    public static func displayName(pid: pid_t, bundleID: String?) -> String {
        if let app = application(pid: pid), let name = app.localizedName, !name.isEmpty {
            return name
        }
        if let bundleID, let last = bundleID.split(separator: ".").last {
            return String(last)
        }
        return "Process \(pid)"
    }

    public static func icon(pid: pid_t) -> NSImage? {
        application(pid: pid)?.icon
    }

    public static func isTerminated(pid: pid_t) -> Bool {
        guard let app = application(pid: pid) else { return false }
        return app.isTerminated
    }

    public static func invalidate(pid: pid_t) {
        cacheLock.lock()
        cache.removeValue(forKey: pid)
        cacheLock.unlock()
    }
}
