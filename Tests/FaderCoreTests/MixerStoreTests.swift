import Foundation
import Testing
@testable import FaderCore

/// Exercises the whole stack against the real HAL: process enumeration, the
/// main-actor hop, row construction, and tearing the graph back down. The
/// callbacks in this path used to trap because they assumed the main actor from
/// a queue that is not the main actor, which no unit test would have caught.
@Suite("Mixer store integration", .serialized)
struct MixerStoreTests {

    @Test("starting and stopping against the real HAL is safe")
    @MainActor
    func lifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fader-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MixerStore(settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")))
        store.start()

        // Give the catalog's first enumeration time to arrive and be applied.
        try await Task.sleep(nanoseconds: 900_000_000)

        #expect(!store.outputDeviceName.isEmpty)
        #expect(store.rows.allSatisfy { !$0.id.isEmpty })

        store.setVolume(0.5, for: "bundle:com.fader.nonexistent")
        #expect(store.settings(for: "bundle:com.fader.nonexistent").volume == 0.5)

        store.setPinned(true, for: "bundle:com.fader.nonexistent")
        #expect(store.rows.contains { $0.id == "bundle:com.fader.nonexistent" && $0.isPinned })

        store.stop()

        // Nothing may be left tapped, and nothing may be left unwritten.
        let reloaded = SettingsStore(url: directory.appendingPathComponent("settings.json")).load()
        #expect(reloaded.apps["bundle:com.fader.nonexistent"]?.volume == 0.5)
        #expect(reloaded.pinned.contains("bundle:com.fader.nonexistent"))
    }

    @Test("a paused app with no processes is still adjustable")
    @MainActor
    func pinnedAppWithoutProcesses() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fader-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")

        let first = MixerStore(settingsStore: SettingsStore(url: url))
        first.start()
        try await Task.sleep(nanoseconds: 400_000_000)
        first.setPinned(true, for: "bundle:com.fader.ghost")
        first.setVolume(0.25, for: "bundle:com.fader.ghost")
        first.stop()

        let second = MixerStore(settingsStore: SettingsStore(url: url))
        second.start()
        try await Task.sleep(nanoseconds: 400_000_000)
        defer { second.stop() }

        let row = second.rows.first { $0.id == "bundle:com.fader.ghost" }
        #expect(row != nil)
        #expect(row?.settings.volume == 0.25)
        #expect(row?.isPlaying == false)
    }
}
