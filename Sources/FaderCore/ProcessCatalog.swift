import CoreAudio
import Foundation
import os

/// Watches the HAL's list of audio-capable processes and reports changes.
///
/// This is the only place that knows how to enumerate processes. It publishes
/// snapshots; it never decides what to do about them.
public final class ProcessCatalog {

    private let log = Logger(subsystem: "com.fader.app", category: "catalog")
    private let queue = DispatchQueue(label: "com.fader.catalog")

    private var listListener: HAL.Listener?
    private var runStateListeners: [AudioObjectID: HAL.Listener] = [:]
    private var snapshot: [AudioProcess] = []
    private var pendingRefresh = false
    private var running = false

    public init() {}

    /// Delivered on an internal serial queue.
    public var onChange: (([AudioProcess]) -> Void)?

    public var current: [AudioProcess] { queue.sync { snapshot } }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            listListener = HAL.Listener(
                object: AudioDevices.system,
                address: HAL.address(kAudioHardwarePropertyProcessObjectList),
                queue: queue
            ) { [weak self] in
                self?.scheduleRefresh()
            }
            refreshNow()
        }
    }

    public func stop() {
        queue.sync {
            running = false
            listListener?.cancel()
            listListener = nil
            runStateListeners.values.forEach { $0.cancel() }
            runStateListeners.removeAll()
        }
    }

    public func refresh() {
        queue.async { [self] in scheduleRefresh() }
    }

    // MARK: Internals

    private func scheduleRefresh() {
        guard running, !pendingRefresh else { return }
        pendingRefresh = true
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.pendingRefresh = false
            self.refreshNow()
        }
    }

    private func refreshNow() {
        let processes = Self.enumerate()
        syncRunStateListeners(for: processes)

        guard processes != snapshot else { return }
        snapshot = processes
        onChange?(processes)
    }

    private func syncRunStateListeners(for processes: [AudioProcess]) {
        let live = Set(processes.map(\.objectID))
        for (objectID, listener) in runStateListeners where !live.contains(objectID) {
            listener.cancel()
            runStateListeners.removeValue(forKey: objectID)
        }
        for process in processes where runStateListeners[process.objectID] == nil {
            runStateListeners[process.objectID] = HAL.Listener(
                object: process.objectID,
                address: HAL.address(kAudioProcessPropertyIsRunningOutput),
                queue: queue
            ) { [weak self] in
                self?.scheduleRefresh()
            }
        }
    }

    private static func enumerate() -> [AudioProcess] {
        let objectIDs: [AudioObjectID] = HAL.array(
            AudioDevices.system,
            HAL.address(kAudioHardwarePropertyProcessObjectList),
            AudioObjectID.self
        )

        let resolver = AppInfo.Resolver()

        return objectIDs.compactMap { objectID in
            let pid: pid_t = HAL.get(objectID, HAL.address(kAudioProcessPropertyPID), default: pid_t(0))
            guard pid > 0 else { return nil }

            let running = HAL.get(objectID, HAL.address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0)) != 0
            let bundleID = HAL.string(objectID, HAL.address(kAudioProcessPropertyBundleID))
            let path = AppInfo.executablePath(pid: pid)
            let owner = resolver.owner(pid: pid, executablePath: path)

            return AudioProcess(
                objectID: objectID,
                pid: pid,
                bundleID: bundleID,
                executablePath: path,
                isRunningOutput: running,
                ownerPID: owner?.processIdentifier,
                ownerBundleID: owner?.bundleIdentifier,
                ownerName: owner?.localizedName
            )
        }
    }
}
