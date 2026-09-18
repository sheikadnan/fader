import Foundation

/// Per-app mixer state. The unit of identity is the bundle identifier, because
/// process IDs are recycled across launches and a user's volume choice should
/// survive a relaunch.
public struct MixSettings: Codable, Equatable, Sendable {

    /// Linear gain, 0...1. Fader deliberately caps at unity.
    public var volume: Float
    public var isMuted: Bool

    public init(volume: Float = 1, isMuted: Bool = false) {
        self.volume = min(max(volume, 0), 1)
        self.isMuted = isMuted
    }

    public static let unity = MixSettings()

    public var gain: Float { isMuted ? 0 : volume }

    /// True when this app needs no tap at all. Keeping untouched apps on the
    /// system's own path is what makes Fader free when you are not using it.
    public var isPassthrough: Bool { gain >= 1 }

    public func sanitized() -> MixSettings {
        MixSettings(volume: volume.isFinite ? volume : 1, isMuted: isMuted)
    }
}

/// Identifies a mixer row. Bundled apps key on bundle ID; bare processes (helper
/// binaries, command-line tools) fall back to their executable identity so they
/// still get a stable row across launches.
public struct AppKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(bundleID: String) {
        self.rawValue = "bundle:\(bundleID)"
    }

    public init(executablePath: String) {
        self.rawValue = "exec:\(executablePath)"
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}
