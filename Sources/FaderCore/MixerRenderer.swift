import CoreAudio
import Foundation

/// The real-time mixing stage.
///
/// One instance owns the render callback for one aggregate device: it reads each
/// tapped app's channels, applies that app's smoothed gain, and sums the result
/// into the hardware output buffers.
///
/// Real-time rules observed here: no allocation, no locks, no logging, no
/// Objective-C messaging on the audio thread. All state is preallocated in
/// `init` and indexed by a plan computed once.
public final class MixerRenderer {

    public enum LayoutError: Error, CustomStringConvertible {
        case emptyOutput
        case unsupportedInputFormat(String)
        case unsupportedOutputFormat(String)
        case channelMapping(String)

        public var description: String {
            switch self {
            case .emptyOutput:
                return "the output device has no channels"
            case .unsupportedInputFormat(let detail):
                return "unsupported tap format: \(detail)"
            case .unsupportedOutputFormat(let detail):
                return "unsupported output format: \(detail)"
            case .channelMapping(let detail):
                return "could not map tap channels: \(detail)"
            }
        }
    }

    /// Resolves one flattened input channel to one flattened output channel.
    private struct ChannelPlan {
        let inputBuffer: Int
        let inputChannel: Int
        let tap: Int
        let outputBuffer: Int
        let outputChannel: Int
    }

    public let keys: [String]
    public let tapCount: Int

    private let plan: [ChannelPlan]
    private let inputBufferCount: Int
    private let outputBufferCount: Int

    // Preallocated render state. Written by the main thread, read by the audio
    // thread. Aligned 32-bit stores are atomic on every platform we support.
    private let targets: UnsafeMutablePointer<Float>
    private let currents: UnsafeMutablePointer<Float>
    private let starts: UnsafeMutablePointer<Float>
    private let deltas: UnsafeMutablePointer<Float>

    private let maxDeltaPerFrame: Float
    private var mismatchLogged = false

    public init(
        keys: [String],
        initialGains: [Float],
        inputBufferChannelCounts: [Int],
        outputBufferChannelCounts: [Int],
        sampleRate: Double,
        inputIsFloat32: Bool,
        outputIsFloat32: Bool
    ) throws {
        guard keys.count == initialGains.count else {
            throw LayoutError.channelMapping("\(keys.count) taps but \(initialGains.count) gains")
        }

        let outputChannels = outputBufferChannelCounts.reduce(0, +)
        guard outputChannels > 0 else { throw LayoutError.emptyOutput }
        guard inputIsFloat32 else {
            throw LayoutError.unsupportedInputFormat("taps are not 32-bit float")
        }
        guard outputIsFloat32 else {
            throw LayoutError.unsupportedOutputFormat("device is not 32-bit float")
        }

        switch StreamLayout.map(bufferChannelCounts: inputBufferChannelCounts, tapCount: keys.count) {
        case .unsupported(let reason):
            throw LayoutError.channelMapping(reason)
        case .streams(let ranges):
            let inputIndex = StreamLayout.index(inputBufferChannelCounts)
            let outputIndex = StreamLayout.index(outputBufferChannelCounts)

            var plan: [ChannelPlan] = []
            for (tap, range) in ranges.enumerated() {
                for flat in range {
                    guard let source = Self.locate(flat, in: inputIndex) else {
                        throw LayoutError.channelMapping("no input buffer owns channel \(flat)")
                    }
                    guard let destination = Self.locate(flat % outputChannels, in: outputIndex) else {
                        throw LayoutError.channelMapping("no output buffer owns channel \(flat)")
                    }
                    plan.append(ChannelPlan(
                        inputBuffer: source.buffer,
                        inputChannel: source.channel,
                        tap: tap,
                        outputBuffer: destination.buffer,
                        outputChannel: destination.channel
                    ))
                }
            }
            self.plan = plan
        }

        self.keys = keys
        self.tapCount = keys.count
        self.inputBufferCount = inputBufferChannelCounts.count
        self.outputBufferCount = outputBufferChannelCounts.count
        self.maxDeltaPerFrame = GainRamp.maxDeltaPerFrame(sampleRate: sampleRate)

        let capacity = max(keys.count, 1)
        self.targets = .allocate(capacity: capacity)
        self.currents = .allocate(capacity: capacity)
        self.starts = .allocate(capacity: capacity)
        self.deltas = .allocate(capacity: capacity)
        for index in 0..<capacity {
            self.targets[index] = index < initialGains.count ? initialGains[index] : 1
            self.currents[index] = self.targets[index]
            self.starts[index] = self.targets[index]
            self.deltas[index] = 0
        }
    }

    deinit {
        targets.deallocate()
        currents.deallocate()
        starts.deallocate()
        deltas.deallocate()
    }

    private static func locate(_ flat: Int, in index: [StreamLayout.BufferIndex]) -> (buffer: Int, channel: Int)? {
        for (buffer, entry) in index.enumerated() where flat >= entry.channelStart && flat < entry.channelStart + entry.channelCount {
            return (buffer, flat - entry.channelStart)
        }
        return nil
    }

    /// Called from the main thread when a slider moves.
    public func setGain(_ gain: Float, forTap index: Int) {
        guard index >= 0, index < tapCount else { return }
        targets[index] = min(max(gain, 0), 1)
    }

    public func setGains(_ gains: [Float]) {
        for (index, gain) in gains.enumerated() where index < tapCount {
            setGain(gain, forTap: index)
        }
    }

    // MARK: Render

    public func render(inputData: UnsafePointer<AudioBufferList>?, outputData: UnsafeMutablePointer<AudioBufferList>?) {
        guard let outputData else { return }
        let outputs = UnsafeMutableAudioBufferListPointer(outputData)

        guard outputs.count == outputBufferCount else {
            silence(outputs)
            return
        }

        silence(outputs)

        guard let inputData else { return }
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard inputs.count == inputBufferCount else { return }

        let frames = outputFrames(outputs)
        guard frames > 0 else { return }

        for tap in 0..<tapCount {
            let step = GainRamp.advance(
                current: currents[tap],
                target: targets[tap],
                frames: frames,
                maxDeltaPerFrame: maxDeltaPerFrame
            )
            starts[tap] = step.start
            deltas[tap] = step.delta
            currents[tap] = step.end
        }

        for entry in plan {
            let inputBuffer = inputs[entry.inputBuffer]
            let outputBuffer = outputs[entry.outputBuffer]
            guard let inputRaw = inputBuffer.mData, let outputRaw = outputBuffer.mData else { continue }

            let inputChannels = max(Int(inputBuffer.mNumberChannels), 1)
            let outputChannels = max(Int(outputBuffer.mNumberChannels), 1)
            let inputFrames = Int(inputBuffer.mDataByteSize) / (MemoryLayout<Float>.size * inputChannels)
            let outputFrames = Int(outputBuffer.mDataByteSize) / (MemoryLayout<Float>.size * outputChannels)
            let count = min(inputFrames, outputFrames, frames)
            guard count > 0 else { continue }

            let source = inputRaw.assumingMemoryBound(to: Float.self) + entry.inputChannel
            let destination = outputRaw.assumingMemoryBound(to: Float.self) + entry.outputChannel

            var gain = starts[entry.tap]
            let delta = deltas[entry.tap]
            var frame = 0
            while frame < count {
                destination[frame * outputChannels] += source[frame * inputChannels] * gain
                gain += delta
                frame += 1
            }
        }
    }

    private func outputFrames(_ outputs: UnsafeMutableAudioBufferListPointer) -> Int {
        guard let first = outputs.first else { return 0 }
        let channels = max(Int(first.mNumberChannels), 1)
        return Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
    }

    private func silence(_ outputs: UnsafeMutableAudioBufferListPointer) {
        for index in 0..<outputs.count {
            guard let data = outputs[index].mData else { continue }
            memset(data, 0, Int(outputs[index].mDataByteSize))
        }
    }
}
