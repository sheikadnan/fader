import CoreAudio
import Foundation

/// One audio-capable process as the HAL sees it.
///
/// A single app commonly owns several of these: `Google Chrome` plus the
/// helper processes that actually decode and play its audio. They share an
/// `AppKey` so they present as one row with one volume.
public struct AudioProcess: Hashable, Sendable {

    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let executablePath: String?
    public let isRunningOutput: Bool

    /// The owning app, when one could be identified. For a helper process this
    /// is the app the user launched.
    public let ownerPID: pid_t?
    public let ownerBundleID: String?
    public let ownerName: String?

    public init(
        objectID: AudioObjectID,
        pid: pid_t,
        bundleID: String?,
        executablePath: String? = nil,
        isRunningOutput: Bool,
        ownerPID: pid_t? = nil,
        ownerBundleID: String? = nil,
        ownerName: String? = nil
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.isRunningOutput = isRunningOutput
        self.ownerPID = ownerPID
        self.ownerBundleID = ownerBundleID
        self.ownerName = ownerName
    }

    /// Stable identity for mixer settings, independent of process lifetime.
    ///
    /// Prefers the owning app's bundle ID so that a helper and its parent share
    /// one setting, and so the user's volume choice for "Google Chrome" is not
    /// stored against "com.google.Chrome.helper".
    public var key: AppKey {
        if let ownerBundleID, !ownerBundleID.isEmpty { return AppKey(bundleID: ownerBundleID) }
        if let bundleID, !bundleID.isEmpty { return AppKey(bundleID: bundleID) }
        if let executablePath, !executablePath.isEmpty { return AppKey(executablePath: executablePath) }
        return AppKey(rawValue: "pid:\(pid)")
    }

    /// What to show the user. Never a bare helper name if an owner is known.
    public var displayName: String {
        if let ownerName, !ownerName.isEmpty { return ownerName }
        if let bundleID, !bundleID.isEmpty, let last = bundleID.split(separator: ".").last {
            return String(last)
        }
        if let executablePath, let last = executablePath.split(separator: "/").last {
            return String(last)
        }
        return "Process \(pid)"
    }
}
