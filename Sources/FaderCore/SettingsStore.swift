import Foundation

/// Persists per-app volumes. Deliberately a plain JSON file: the data is small,
/// human-inspectable, and losing it is recoverable.
public final class SettingsStore {

    public struct State: Codable, Equatable {
        public var apps: [String: MixSettings] = [:]
        public var pinned: [String] = []
        /// Last known display name per key, so a pinned app that is not running
        /// can still be listed by name.
        public var names: [String: String] = [:]

        public init(
            apps: [String: MixSettings] = [:],
            pinned: [String] = [],
            names: [String: String] = [:]
        ) {
            self.apps = apps
            self.pinned = pinned
            self.names = names
        }

        /// Written by hand because the synthesized decoder rejects files that
        /// predate a field, and settings files outlive app versions.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            apps = try container.decodeIfPresent([String: MixSettings].self, forKey: .apps) ?? [:]
            pinned = try container.decodeIfPresent([String].self, forKey: .pinned) ?? []
            names = try container.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        }
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Fader", isDirectory: true).appendingPathComponent("settings.json")
    }

    /// Older versions must keep working when new fields appear, and a corrupt
    /// file must never take the app down.
    private static let maxEntries = 400

    private let url: URL
    private let queue = DispatchQueue(label: "com.fader.settings")

    public init(url: URL = SettingsStore.defaultURL) {
        self.url = url
    }

    public func load() -> State {
        guard let data = try? Data(contentsOf: url) else { return State() }
        guard let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }

        var sanitized = State()
        sanitized.apps = state.apps.mapValues { $0.sanitized() }
        sanitized.pinned = Array(state.pinned.prefix(Self.maxEntries))
        sanitized.names = state.names
        return sanitized
    }

    /// Returns immediately. Writes are ordered on a private queue so a slider
    /// drag never waits on the disk; `flush()` closes the window between a
    /// change and the app quitting.
    public func save(_ state: State) {
        var trimmed = State()
        trimmed.apps = state.apps.mapValues { $0.sanitized() }
        trimmed.pinned = Array(state.pinned.prefix(Self.maxEntries))
        trimmed.names = state.names

        queue.async { [url] in
            Self.write(trimmed, to: url)
        }
    }

    /// Blocks until every queued write has landed. Call this before the process
    /// exits, not on the UI path.
    public func flush() {
        queue.sync {}
    }

    private static func write(_ state: State, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // Losing settings is not worth interrupting playback over.
        }
    }
}
