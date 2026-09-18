import AppKit
import CoreAudio
import Foundation
import Observation
import os

/// The app's single source of truth.
///
/// It joins three things that know nothing about each other — the HAL's process
/// list, the user's saved volumes, and the audio graph — and publishes the rows
/// the UI renders.
@MainActor
@Observable
public final class MixerStore {

    public struct Row: Identifiable {
        public let id: String
        public let key: AppKey
        public var name: String
        public var icon: NSImage?
        public var settings: MixSettings
        public var isPlaying: Bool
        public var processCount: Int
        public var isPinned: Bool
        /// Set when this specific app could not be mixed, e.g. permission denied.
        public var problem: String?
    }

    public private(set) var rows: [Row] = []
    public private(set) var outputDeviceName = "Unknown"
    public private(set) var problems: [String] = []

    private let catalog = ProcessCatalog()
    private let engine = MixerEngine()
    private let settingsStore: SettingsStore

    private var state = SettingsStore.State()
    private var processes: [AudioProcess] = []
    private var processIDsByKey: [String: [AudioObjectID]] = [:]
    private var failureByKey: [String: String] = [:]
    private var deviceListener: HAL.Listener?

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let ownBundleID = Bundle.main.bundleIdentifier
    private let log = Logger(subsystem: "com.fader.app", category: "store")

    public init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        self.state = settingsStore.load()

        // Both callbacks arrive on the sender's own queue, not on the main
        // actor, so hop rather than assume.
        engine.onFailures = { [weak self] failures in
            Task { @MainActor in self?.apply(failures: failures) }
        }
        catalog.onChange = { [weak self] processes in
            Task { @MainActor in self?.apply(processes: processes) }
        }
    }

    // MARK: Lifecycle

    public func start() {
        deviceListener = HAL.Listener(
            object: AudioDevices.system,
            address: HAL.address(kAudioHardwarePropertyDefaultOutputDevice),
            queue: .main
        ) { [weak self] in
            Task { @MainActor in self?.rebuildRows() }
        }
        catalog.start()
        outputDeviceName = AudioDevices.name(AudioDevices.defaultOutputID) ?? "Unknown"
    }

    public func stop() {
        deviceListener?.cancel()
        deviceListener = nil
        catalog.stop()
        engine.shutdown()
        // Nothing may be left on the write queue when the process goes away.
        settingsStore.flush()
    }

    // MARK: User actions

    public func setVolume(_ volume: Float, for id: String) {
        update(id) { $0.volume = min(max(volume, 0), 1) }
    }

    public func setMuted(_ muted: Bool, for id: String) {
        update(id) { $0.isMuted = muted }
    }

    public func toggleMute(for id: String) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        setMuted(!row.settings.isMuted, for: id)
    }

    public func reset(_ id: String) {
        update(id) { $0 = .unity }
    }

    public func setPinned(_ pinned: Bool, for id: String) {
        if pinned {
            guard !state.pinned.contains(id) else { return }
            state.pinned.append(id)
        } else {
            state.pinned.removeAll { $0 == id }
        }
        persist()
        rebuildRows()
    }

    /// Volume for an app that is not currently running, so the user can set it
    /// up ahead of time from the pinned list.
    public func settings(for id: String) -> MixSettings {
        state.apps[id] ?? .unity
    }

    // MARK: State plumbing

    private func update(_ id: String, _ mutate: (inout MixSettings) -> Void) {
        var settings = state.apps[id] ?? .unity
        mutate(&settings)
        settings = settings.sanitized()
        state.apps[id] = settings

        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].settings = settings
        }
        persist()
        reconcile()
    }

    private func persist() {
        settingsStore.save(state)
    }

    private func apply(processes: [AudioProcess]) {
        self.processes = processes
        rebuildRows()
    }

    private func apply(failures: [MixerEngine.TapFailure]) {
        failureByKey = [:]
        for failure in failures {
            failureByKey[failure.name] = failure.message
        }
        for index in rows.indices {
            rows[index].problem = failureByKey[rows[index].name]
        }
        problems = failures
            .filter { $0.name == "Mixer" || $0.name == "Output device" }
            .map { "\($0.name): \($0.message)" }
    }

    // MARK: Row construction

    private func rebuildRows() {
        var grouped: [String: (key: AppKey, name: String, icon: NSImage?, playing: Bool, count: Int, processIDs: [AudioObjectID])] = [:]

        let ownKey = ownBundleID.map { AppKey(bundleID: $0).rawValue }

        for process in processes {
            guard process.pid != ownPID else { continue }
            if let ownKey, process.key.rawValue == ownKey { continue }

            let key = process.key
            let existing = grouped[key.rawValue]
            grouped[key.rawValue] = (
                key: key,
                name: existing?.name ?? process.displayName,
                icon: existing?.icon ?? AppInfo.icon(pid: process.ownerPID ?? process.pid),
                playing: (existing?.playing ?? false) || process.isRunningOutput,
                count: (existing?.count ?? 0) + 1,
                processIDs: (existing?.processIDs ?? []) + [process.objectID]
            )
        }

        processIDsByKey = grouped.mapValues(\.processIDs)

        var built: [Row] = []
        for (id, entry) in grouped {
            let settings = state.apps[id] ?? .unity
            let pinned = state.pinned.contains(id)
            // Playing, pinned, or already adjusted. Nothing else: a list of
            // every process on the machine that can make sound is noise.
            guard entry.playing || pinned || !settings.isPassthrough else { continue }
            built.append(Row(
                id: id,
                key: entry.key,
                name: entry.name,
                icon: entry.icon,
                settings: settings,
                isPlaying: entry.playing,
                processCount: entry.count,
                isPinned: pinned,
                problem: failureByKey[entry.name]
            ))
        }

        for pinnedID in state.pinned where grouped[pinnedID] == nil {
            built.append(Row(
                id: pinnedID,
                key: AppKey(rawValue: pinnedID),
                name: state.names[pinnedID] ?? Self.fallbackName(for: pinnedID),
                icon: nil,
                settings: state.apps[pinnedID] ?? .unity,
                isPlaying: false,
                processCount: 0,
                isPinned: true,
                problem: nil
            ))
        }

        built.sort { left, right in
            if left.isPlaying != right.isPlaying { return left.isPlaying }
            if left.isPinned != right.isPinned { return left.isPinned }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }

        rows = built
        outputDeviceName = AudioDevices.name(AudioDevices.defaultOutputID) ?? "Unknown"
        reportRows()
        rememberNames()
        reconcile()
    }

    /// "My app is not in the list" is the question this app will be asked most,
    /// so the list it actually built is recorded rather than guessed at.
    private func reportRows() {
        guard !rows.isEmpty else {
            log.info("rows: none")
            return
        }
        let summary = rows
            .map { "\($0.name)\($0.isPlaying ? "*" : "")(\($0.processCount))" }
            .joined(separator: ", ")
        log.info("rows(\(self.rows.count)): \(summary, privacy: .public)")
    }

    private func rememberNames() {
        var changed = false
        for row in rows where !row.name.isEmpty && state.names[row.id] != row.name {
            state.names[row.id] = row.name
            changed = true
        }
        if changed { persist() }
    }

    private func reconcile() {
        let slots: [MixerEngine.Slot] = rows.compactMap { row in
            let processIDs = processIDsByKey[row.id] ?? []
            guard !row.settings.isPassthrough, !processIDs.isEmpty else { return nil }
            return MixerEngine.Slot(key: row.id, name: row.name, processes: processIDs, gain: row.settings.gain)
        }
        engine.apply(slots: slots)
    }

    private static func fallbackName(for key: String) -> String {
        let raw = key.contains(":") ? String(key.split(separator: ":", maxSplits: 1)[1]) : key
        return raw.split(separator: ".").last.map(String.init) ?? raw
    }
}
