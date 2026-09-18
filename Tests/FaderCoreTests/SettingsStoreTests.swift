import Foundation
import Testing
@testable import FaderCore

@Suite("Settings persistence")
struct SettingsStoreTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fader-tests-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
    }

    @Test("a missing file is an empty state, not an error")
    func missingFile() {
        #expect(SettingsStore(url: temporaryURL()).load() == SettingsStore.State())
    }

    @Test("settings survive a save and load")
    func roundTrip() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SettingsStore(url: url)
        store.save(SettingsStore.State(
            apps: ["bundle:com.spotify.client": MixSettings(volume: 0.3)],
            pinned: ["bundle:com.spotify.client"],
            names: ["bundle:com.spotify.client": "Spotify"]
        ))
        store.flush()

        let loaded = store.load()
        #expect(loaded.apps["bundle:com.spotify.client"]?.volume == 0.3)
        #expect(loaded.pinned == ["bundle:com.spotify.client"])
        #expect(loaded.names["bundle:com.spotify.client"] == "Spotify")
    }

    @Test("a save that is never flushed is not yet on disk")
    func unflushedSaveIsPending() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SettingsStore(url: url)
        store.save(SettingsStore.State(apps: ["bundle:com.x": MixSettings(volume: 0.1)]))
        store.flush()
        #expect(store.load().apps["bundle:com.x"]?.volume == 0.1)
    }

    @Test("a file written before a field existed still loads")
    func forwardCompatible() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"apps":{"bundle:com.apple.Safari":{"volume":0.5,"isMuted":false}}}"#.utf8).write(to: url)

        let loaded = SettingsStore(url: url).load()
        #expect(loaded.apps["bundle:com.apple.Safari"]?.volume == 0.5)
        #expect(loaded.pinned.isEmpty)
        #expect(loaded.names.isEmpty)
    }

    @Test("a corrupt file degrades to defaults instead of crashing")
    func corruptFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: url)
        #expect(SettingsStore(url: url).load() == SettingsStore.State())
    }

    @Test("an out-of-range stored volume is clamped on load")
    func clampsOnLoad() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"apps":{"bundle:com.x":{"volume":99,"isMuted":false}},"pinned":[],"names":{}}"#.utf8).write(to: url)
        #expect(SettingsStore(url: url).load().apps["bundle:com.x"]?.volume == 1)
    }
}
