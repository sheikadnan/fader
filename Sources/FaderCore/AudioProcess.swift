import CoreAudio
import Foundation

/// One audio-capable process as the HAL sees it.
///
/// A single app commonly owns several of these (`Google Chrome` plus its helper
/// processes). They share an `AppKey` and are tapped together.
public struct AudioProcess: Hashable, Sendable {

    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isRunningOutput: Bool
    public let executablePath: String?

    public init(
        objectID: AudioObjectID,
        pid: pid_t,
        bundleID: String?,
        isRunningOutput: Bool,
        executablePath: String? = nil
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
        self.executablePath = executablePath
    }

    /// Stable identity for mixer settings, independent of process lifetime.
    public var key: AppKey {
        if let bundleID, !bundleID.isEmpty { return AppKey(bundleID: bundleID) }
        if let executablePath, !executablePath.isEmpty { return AppKey(executablePath: executablePath) }
        return AppKey(rawValue: "pid:\(pid)")
    }
}
