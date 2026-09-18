import CoreAudio
import FaderCore
import Foundation

// fader-probe — the M0 spike, kept in the repo because it is the only way to
// answer the questions that cannot be answered from documentation:
//   1. does tapping another process require permission on this machine, and
//      which prompt does the system raise?
//   2. what stream layout does an aggregate device with sub-taps actually
//      present to a render callback?
//
// It changes nothing unless you pass --run, which mixes every audible app at
// 50% for a few seconds and then puts everything back.

// Progress must be visible when piped to a file or another command; stdio
// would otherwise buffer everything until exit, which is useless for a
// diagnostic that can block.
setvbuf(stdout, nil, _IONBF, 0)

let arguments = Set(CommandLine.arguments.dropFirst())

func heading(_ text: String) {
    print("\n\u{001B}[1m\(text)\u{001B}[0m")
}

func value(_ label: String, _ text: String) {
    print("  \(label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(text)")
}

heading("Fader probe")
value("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
value("Fader bundle", Bundle.main.bundleIdentifier ?? "—")

// MARK: Output device

heading("Default output device")
let device = AudioDevices.defaultOutputID
value("AudioObjectID", "\(device)")
value("name", AudioDevices.name(device) ?? "—")
value("uid", AudioDevices.uid(device) ?? "—")
value("alive", AudioDevices.isAlive(device) ? "yes" : "no")
value("sample rate", "\(AudioDevices.nominalSampleRate(device)) Hz")
value("output channels", "\(AudioDevices.outputChannelCount(device))")
if let format = HAL.streamFormat(device, scope: kAudioObjectPropertyScopeOutput) {
    value("output format", "\(format.mFormatID.fourChar) \(format.mBitsPerChannel)-bit, flags 0x\(String(format.mFormatFlags, radix: 16))")
}

// MARK: Processes

let catalog = ProcessCatalog()
catalog.start()
Thread.sleep(forTimeInterval: 0.4)
let processes = catalog.current
catalog.stop()

let audible = processes.filter(\.isRunningOutput)

heading("Audio processes (\(processes.count) total, \(audible.count) producing audio)")
for process in audible.prefix(20) {
    let name = AppInfo.displayName(pid: process.pid, bundleID: process.bundleID)
    value(name, "pid \(process.pid)  \(process.bundleID ?? "no bundle id")")
}
if audible.isEmpty {
    print("  (nothing is playing right now — start some audio and re-run)")
}

// MARK: Tap + aggregate

heading("Tap and aggregate")
guard let deviceUID = AudioDevices.uid(device) else {
    print("  no output device UID; stopping here")
    exit(1)
}

let targets = Array(audible.prefix(4))
guard !targets.isEmpty else {
    print("  nothing to tap; stopping here")
    exit(0)
}

var taps: [(process: AudioProcess, id: AudioObjectID, uid: String)] = []
for process in targets {
    let name = AppInfo.displayName(pid: process.pid, bundleID: process.bundleID)
    let description = CATapDescription(stereoMixdownOfProcesses: [process.objectID])
    description.name = "Fader probe — \(name)"
    description.isPrivate = true
    description.muteBehavior = .mutedWhenTapped

    var tapID = AudioObjectID(0)
    let status = AudioHardwareCreateProcessTap(description, &tapID)
    if status == noErr, tapID != 0 {
        let uid = HAL.string(tapID, HAL.address(kAudioTapPropertyUID)) ?? description.uuid.uuidString
        taps.append((process, tapID, uid))
        value(name, "tap ok")
    } else {
        value(name, "tap FAILED — \(fourCharString(status)) (\(status))")
    }
}

guard !taps.isEmpty else {
    heading("Result")
    print("  No tap could be created. If the status above is 'nope'/-50 or similar,")
    print("  grant Fader permission in System Settings › Privacy & Security and re-run.")
    exit(2)
}

let composition: [String: Any] = [
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceNameKey: "Fader probe mixer",
    kAudioAggregateDeviceIsPrivateKey: 1,
    kAudioAggregateDeviceIsStackedKey: 0,
    kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
    kAudioAggregateDeviceTapListKey: taps.map { [kAudioSubTapUIDKey: $0.uid, kAudioSubTapDriftCompensationKey: 1] },
]

var aggregateID = AudioObjectID(0)
let aggregateStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
value("aggregate status", aggregateStatus == noErr ? "ok" : fourCharString(aggregateStatus))

if aggregateStatus == noErr, aggregateID != 0 {
    let inputCounts = HAL.bufferChannelCounts(aggregateID, scope: kAudioObjectPropertyScopeInput)
    let outputCounts = HAL.bufferChannelCounts(aggregateID, scope: kAudioObjectPropertyScopeOutput)
    value("aggregate id", "\(aggregateID)")
    value("input buffers", "\(inputCounts)  (taps: \(taps.count))")
    value("output buffers", "\(outputCounts)")

    switch StreamLayout.map(bufferChannelCounts: inputCounts, tapCount: taps.count) {
    case .streams(let ranges):
        value("tap channel map", "\(ranges)")
    case .unsupported(let reason):
        value("tap channel map", "UNSUPPORTED — \(reason)")
    }

    if arguments.contains("--run") {
        let gain: Float = 0.5
        heading("Mixing \(taps.count) app(s) at \(Int(gain * 100))% for 6 seconds")
        print("  Measuring rather than trusting: if the tapped app is audible now,")
        print("  output peak should be about half of input peak.")
        if let renderer = try? MixerRenderer(
            keys: taps.map { $0.uid },
            initialGains: taps.map { _ in gain },
            inputBufferChannelCounts: inputCounts,
            outputBufferChannelCounts: outputCounts,
            sampleRate: AudioDevices.nominalSampleRate(device),
            inputIsFloat32: true,
            outputIsFloat32: true
        ) {
            let stats = ProbeStats()
            var ioProcID: AudioDeviceIOProcID?
            let createStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
                stats.observe(input: input)
                renderer.render(inputData: input, outputData: output)
                stats.observe(output: output)
            }
            if createStatus == noErr, let ioProcID {
                // Start off the main thread behind a watchdog: a blocked start
                // must be reported, never waited on.
                let startBox = StartBox()
                DispatchQueue.global().async {
                    startBox.status = AudioDeviceStart(aggregateID, ioProcID)
                    startBox.done.signal()
                }
                if startBox.done.wait(timeout: .now() + 5) == .timedOut {
                    value("start", "BLOCKED — AudioDeviceStart never returned")
                    value("callbacks since", "\(stats.callbacks)")
                    value("input geometry", stats.inputGeometry)
                    value("output geometry", stats.outputGeometry)
                    AudioHardwareDestroyAggregateDevice(aggregateID)
                    for tap in taps { AudioHardwareDestroyProcessTap(tap.id) }
                    exit(5)
                }
                let startStatus = startBox.status
                value("start", startStatus == noErr ? "ok" : fourCharString(startStatus))
                Thread.sleep(forTimeInterval: 6)
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)

                heading("Measured")
                value("callbacks", "\(stats.callbacks)")
                value("input peak", String(format: "%.5f", stats.inputPeak))
                value("output peak", String(format: "%.5f", stats.outputPeak))
                value("input rms", String(format: "%.5f", stats.inputRMS))
                value("output rms", String(format: "%.5f", stats.outputRMS))
                value("input geometry", stats.inputGeometry)
                value("output geometry", stats.outputGeometry)
                if stats.inputPeak > 0 {
                    value("output / input", String(format: "%.3f  (requested %.2f)", stats.outputRMS / stats.inputRMS, gain))
                }
            } else {
                value("io proc", fourCharString(createStatus))
            }
        } else {
            print("  renderer could not be built for this layout")
        }
    }

    AudioHardwareDestroyAggregateDevice(aggregateID)
}

for tap in taps {
    AudioHardwareDestroyProcessTap(tap.id)
}

heading("Done")
print("  Taps destroyed. Every app is back on the system's own audio path.\n")

/// Diagnostic-only meters. Written on the audio thread, read after the device has
/// been stopped, which is why no atomics are needed here. The shipping renderer
/// has no equivalent and does no measuring.
final class StartBox: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var status: OSStatus = -9999
}

final class ProbeStats: @unchecked Sendable {
    var callbacks = 0
    var inputGeometry = "—"
    var outputGeometry = "—"
    var inputPeak: Float = 0
    var outputPeak: Float = 0
    var inputSumSquares: Double = 0
    var outputSumSquares: Double = 0
    var sampleCount = 0

    var inputRMS: Float { sampleCount > 0 ? Float((inputSumSquares / Double(sampleCount)).squareRoot()) : 0 }
    var outputRMS: Float { sampleCount > 0 ? Float((outputSumSquares / Double(sampleCount)).squareRoot()) : 0 }

    func observe(input: UnsafePointer<AudioBufferList>?) {
        callbacks += 1
        guard let input else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if callbacks == 1 {
            inputGeometry = list.map { "\(Int($0.mNumberChannels))ch/\($0.mDataByteSize)B" }.joined(separator: " ")
        }
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size {
                let value = samples[index]
                inputPeak = max(inputPeak, abs(value))
                inputSumSquares += Double(value) * Double(value)
            }
        }
    }

    func observe(output: UnsafeMutablePointer<AudioBufferList>?) {
        guard let output else { return }
        let list = UnsafeMutableAudioBufferListPointer(output)
        if outputGeometry == "—" {
            outputGeometry = list.map { "\(Int($0.mNumberChannels))ch/\($0.mDataByteSize)B" }.joined(separator: " ")
        }
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size {
                let value = samples[index]
                outputPeak = max(outputPeak, abs(value))
                outputSumSquares += Double(value) * Double(value)
            }
        }
        // Both scopes are counted once per callback, so RMS compares like with like.
        sampleCount += list.reduce(0) { $0 + Int($1.mDataByteSize) } / MemoryLayout<Float>.size
    }
}

extension FourCharCode {
    var fourChar: String {
        let bytes = [
            UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF),
        ]
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "\(self)" }
        return String(bytes: bytes, encoding: .ascii) ?? "\(self)"
    }
}
