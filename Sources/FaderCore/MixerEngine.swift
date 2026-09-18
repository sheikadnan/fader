import CoreAudio
import Foundation
import os

/// Owns the audio graph: one process tap per app, one private aggregate device
/// that carries those taps plus the default output device, and one render
/// callback that mixes them.
///
/// The invariant that matters most: an app is only ever tapped when its gain is
/// below unity. Everything else keeps using the system's own path, which is why
/// Fader costs nothing when you are not touching anything.
public final class MixerEngine {

    public struct Slot: Equatable {
        public let key: String
        public let name: String
        public let processes: [AudioObjectID]
        public let gain: Float

        public init(key: String, name: String, processes: [AudioObjectID], gain: Float) {
            self.key = key
            self.name = name
            self.processes = processes.sorted()
            self.gain = gain
        }
    }

    public struct TapFailure: Equatable {
        public let name: String
        public let message: String
    }

    private let log = Logger(subsystem: "com.fader.app", category: "engine")
    private let queue = DispatchQueue(label: "com.fader.engine")

    private var tapIDs: [AudioObjectID] = []
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var renderer: MixerRenderer?
    private var signature = ""
    private var keyToTapIndex: [String: Int] = [:]
    private var failures: [TapFailure] = []

    /// Called on the main thread whenever the set of usable taps changes.
    public var onFailures: (([TapFailure]) -> Void)?

    public init() {}


    // MARK: Public API

    /// Applies the desired mixer state. Rebuilds the audio graph only when the
    /// *shape* changes; gain-only updates are written straight into the render
    /// state and never interrupt playback.
    /// Never call this synchronously from the main thread. Every HAL call it
    /// leads to, `AudioDeviceStart` above all, must run off the main thread:
    /// starting IO from the main thread does not return, which was measured
    /// rather than assumed. The work is hopped to a private serial queue here
    /// so callers cannot get this wrong.
    public func apply(slots: [Slot]) {
        queue.async { [weak self] in
            self?.update(slots: slots)
        }
    }

    @discardableResult
    private func update(slots: [Slot]) -> [TapFailure] {
        let wanted = slots.filter { $0.gain < 1 }
        let outputDevice = AudioDevices.defaultOutputID
        let outputUID = AudioDevices.uid(outputDevice)

        let newSignature = Self.signature(slots: wanted, outputUID: outputUID)

        if newSignature == signature, let renderer {
            for slot in wanted {
                guard let index = keyToTapIndex[slot.key] else { continue }
                renderer.setGain(slot.gain, forTap: index)
            }
            return failures
        }

        rebuild(slots: wanted, outputDevice: outputDevice, outputUID: outputUID, signature: newSignature)
        return failures
    }

    /// Tears the whole graph down. After this, every app is back on the
    /// system's own audio path.
    ///
    /// Must be called before the engine is released; there is deliberately no
    /// `deinit` fallback, because the HAL calls below are only safe off the
    /// main thread and `deinit` runs on whichever thread releases the last
    /// reference.
    public func shutdown() {
        // Blocks until the graph is gone, so that when this returns every app
        // really is audible again. The work is queued rather than run via
        // `sync`, because `sync` would execute it on the calling thread — and
        // the caller is the main thread.
        let finished = DispatchSemaphore(value: 0)
        queue.async { [self] in
            teardown()
            signature = ""
            keyToTapIndex = [:]
            failures = []
            finished.signal()
        }
        finished.wait()
    }

    // MARK: Graph construction

    private func rebuild(slots: [Slot], outputDevice: AudioObjectID, outputUID: String?, signature newSignature: String) {
        teardown()
        failures = []

        guard !slots.isEmpty else {
            signature = ""
            return
        }
        guard let outputUID, outputDevice != 0, AudioDevices.isAlive(outputDevice) else {
            failures = [TapFailure(name: "Output device", message: "no usable default output device")]
            signature = ""
            report()
            return
        }

        var createdTaps: [(slot: Slot, tapID: AudioObjectID, uid: String)] = []

        for slot in slots {
            do {
                createdTaps.append(try makeTap(for: slot))
            } catch {
                failures.append(TapFailure(name: slot.name, message: Self.describe(error)))
            }
        }

        guard !createdTaps.isEmpty else {
            signature = ""
            report()
            return
        }

        do {
            let aggregate = try makeAggregate(
                taps: createdTaps,
                outputDevice: outputDevice,
                outputUID: outputUID
            )
            tapIDs = createdTaps.map(\.tapID)
            aggregateID = aggregate.deviceID

            let renderer = try MixerRenderer(
                keys: createdTaps.map(\.slot.key),
                initialGains: createdTaps.map(\.slot.gain),
                inputBufferChannelCounts: aggregate.inputChannelCounts,
                outputBufferChannelCounts: aggregate.outputChannelCounts,
                sampleRate: aggregate.sampleRate,
                inputIsFloat32: aggregate.inputIsFloat32,
                outputIsFloat32: aggregate.outputIsFloat32
            )
            self.renderer = renderer
            keyToTapIndex = Dictionary(uniqueKeysWithValues: createdTaps.enumerated().map { ($0.element.slot.key, $0.offset) })

            try start(aggregateID: aggregate.deviceID, renderer: renderer)
            signature = newSignature
            log.info("Fader mixing \(createdTaps.count) app(s) into \(outputUID, privacy: .public)")
        } catch {
            failures.append(TapFailure(name: "Mixer", message: Self.describe(error)))
            teardown()
            signature = ""
            log.error("Fader could not start: \(Self.describe(error), privacy: .public)")
        }

        report()
    }

    /// Failures are delivered on the main thread; the store owns presentation.
    private func report() {
        let failures = self.failures
        DispatchQueue.main.async { [weak self] in
            self?.onFailures?(failures)
        }
    }

    private func makeTap(for slot: Slot) throws -> (slot: Slot, tapID: AudioObjectID, uid: String) {
        let description = CATapDescription(stereoMixdownOfProcesses: slot.processes)
        description.name = "Fader — \(slot.name)"
        description.isPrivate = true
        // Muted only while Fader is actively reading. If Fader dies, the tap
        // dies with it and the app's audio comes straight back.
        description.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID(0)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != 0 else {
            throw EngineError.tapFailed(status)
        }

        let uid = HAL.string(tapID, HAL.address(kAudioTapPropertyUID)) ?? description.uuid.uuidString
        return (slot, tapID, uid)
    }

    private struct Aggregate {
        let deviceID: AudioObjectID
        let inputChannelCounts: [Int]
        let outputChannelCounts: [Int]
        let sampleRate: Double
        let inputIsFloat32: Bool
        let outputIsFloat32: Bool
    }

    private func makeAggregate(
        taps: [(slot: Slot, tapID: AudioObjectID, uid: String)],
        outputDevice: AudioObjectID,
        outputUID: String
    ) throws -> Aggregate {
        let composition: [String: Any] = [
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceNameKey: "Fader Mixer",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: taps.map { tap in
                [
                    kAudioSubTapUIDKey: tap.uid,
                    kAudioSubTapDriftCompensationKey: 1,
                ]
            },
        ]

        var deviceID = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &deviceID)
        guard status == noErr, deviceID != 0 else {
            throw EngineError.aggregateFailed(status)
        }

        let inputCounts = HAL.bufferChannelCounts(deviceID, scope: kAudioObjectPropertyScopeInput)
        let outputCounts = HAL.bufferChannelCounts(deviceID, scope: kAudioObjectPropertyScopeOutput)
        let inputFormat = HAL.streamFormat(deviceID, scope: kAudioObjectPropertyScopeInput)
        let outputFormat = HAL.streamFormat(deviceID, scope: kAudioObjectPropertyScopeOutput)

        return Aggregate(
            deviceID: deviceID,
            inputChannelCounts: inputCounts,
            outputChannelCounts: outputCounts,
            sampleRate: AudioDevices.nominalSampleRate(outputDevice),
            inputIsFloat32: Self.isFloat32(inputFormat),
            outputIsFloat32: Self.isFloat32(outputFormat)
        )
    }

    private func start(aggregateID: AudioObjectID, renderer: MixerRenderer) throws {
        var ioProcID: AudioDeviceIOProcID?
        // NULL queue: the block is invoked directly on the HAL's real-time
        // thread rather than hopping through a dispatch queue.
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inputData, _, outputData, _ in
            renderer.render(inputData: inputData, outputData: outputData)
        }
        guard createStatus == noErr, let ioProcID else {
            throw EngineError.ioProcFailed(createStatus)
        }

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            throw EngineError.startFailed(startStatus)
        }
        self.ioProcID = ioProcID
    }

    private func teardown() {
        if aggregateID != 0, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        renderer = nil

        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        for tapID in tapIDs {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapIDs = []
    }

    // MARK: Helpers

    private static func signature(slots: [Slot], outputUID: String?) -> String {
        let body = slots
            .map { "\($0.key)=\($0.processes.map(String.init).joined(separator: ","))" }
            .sorted()
            .joined(separator: "|")
        return "\(outputUID ?? "none")#\(body)"
    }

    private static func isFloat32(_ format: AudioStreamBasicDescription?) -> Bool {
        guard let format else { return false }
        return format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let EngineError.tapFailed(status):
            if status == kAudioHardwareIllegalOperationError {
                return "permission denied (\(fourCharString(status)))"
            }
            return "could not create tap (\(fourCharString(status)))"
        case let EngineError.aggregateFailed(status):
            return "could not create mixer device (\(fourCharString(status)))"
        case let EngineError.ioProcFailed(status):
            return "could not attach render callback (\(fourCharString(status)))"
        case let EngineError.startFailed(status):
            return "could not start audio (\(fourCharString(status)))"
        case let layout as MixerRenderer.LayoutError:
            return layout.description
        default:
            return error.localizedDescription
        }
    }

    private enum EngineError: Error {
        case tapFailed(OSStatus)
        case aggregateFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)
    }
}
