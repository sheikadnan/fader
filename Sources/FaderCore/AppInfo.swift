import AppKit
import Darwin
import Foundation

/// Display metadata for running processes. Kept apart from the HAL layer so
/// audio code never depends on AppKit.
public enum AppInfo {

    /// A snapshot of the running applications, taken once per pass over the
    /// process list so resolving N processes does not re-query the workspace N
    /// times.
    public struct Resolver {

        private let byPID: [pid_t: NSRunningApplication]
        /// Sorted shortest path first, so the outermost bundle containing an
        /// executable wins.
        private let bundlePaths: [(path: String, app: NSRunningApplication)]

        public init() {
            let running = NSWorkspace.shared.runningApplications
            byPID = Dictionary(
                running.map { ($0.processIdentifier, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            bundlePaths = running
                .compactMap { app -> (path: String, app: NSRunningApplication)? in
                    guard let path = app.bundleURL?.path else { return nil }
                    return (path: path, app: app)
                }
                .sorted { $0.path.count < $1.path.count }
        }

        /// Resolves the app a process belongs to.
        ///
        /// Most apps that make sound are not the app the user launched. Chrome
        /// plays YouTube from `Google Chrome Helper`, whose own name is the
        /// bare word "helper" and whose bundle ID is `com.google.Chrome.helper`.
        /// A helper's executable lives inside its parent's bundle, so the
        /// outermost bundle that contains it is the app the user recognises.
        public func owner(pid: pid_t, executablePath: String?) -> NSRunningApplication? {
            if let executablePath, !executablePath.isEmpty {
                for entry in bundlePaths where executablePath.hasPrefix(entry.path + "/") {
                    return entry.app
                }
            }
            return byPID[pid]
        }
    }

    /// Full path of a process's executable. Works for command line tools and
    /// helpers, which `NSRunningApplication` does not always know about.
    public static func executablePath(pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)], as: UTF8.self)
    }

    public static func icon(pid: pid_t) -> NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    public static func isTerminated(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.isTerminated ?? false
    }
}
