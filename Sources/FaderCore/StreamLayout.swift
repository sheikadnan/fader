import Foundation

/// Maps an aggregate device's flattened input channels onto the taps that
/// produced them.
///
/// An aggregate device presents every sub-tap as one input stream, laid out in
/// the order the taps were declared in the aggregate composition. The HAL hands
/// the render callback one buffer per *buffer*, not per stream, so the channel
/// layout has to be resolved from `kAudioDevicePropertyStreamConfiguration`
/// before audio can be attributed to the right app.
public enum StreamLayout {

    public enum Mapping: Equatable {
        /// Flattened channel index range for each tap, in tap order.
        case streams([Range<Int>])
        /// The observed layout cannot be attributed to taps. Never guess here:
        /// mis-attributing channels would apply one app's volume to another.
        case unsupported(reason: String)
    }

    /// - Parameters:
    ///   - bufferChannelCounts: `mNumberChannels` of each buffer, HAL order.
    ///   - tapCount: number of sub-taps in the aggregate.
    ///   - channelsPerTap: channels each tap contributes (2 for stereo mixdown).
    public static func map(bufferChannelCounts: [Int], tapCount: Int, channelsPerTap: Int = 2) -> Mapping {
        guard tapCount > 0 else { return .streams([]) }
        guard !bufferChannelCounts.isEmpty else {
            return .unsupported(reason: "aggregate reports no input buffers")
        }
        guard bufferChannelCounts.allSatisfy({ $0 > 0 }) else {
            return .unsupported(reason: "aggregate reports a buffer with no channels")
        }

        let totalChannels = bufferChannelCounts.reduce(0, +)
        let expected = tapCount * channelsPerTap
        guard totalChannels == expected else {
            return .unsupported(
                reason: "expected \(expected) input channels for \(tapCount) taps, saw \(totalChannels)"
            )
        }

        // Each tap contributes a contiguous run of channels, in tap order. This
        // holds for both interleaved (one buffer of N channels) and
        // non-interleaved (N buffers of one channel) layouts.
        var ranges: [Range<Int>] = []
        var start = 0
        for _ in 0..<tapCount {
            ranges.append(start..<(start + channelsPerTap))
            start += channelsPerTap
        }
        return .streams(ranges)
    }

    /// Flattens per-buffer channel counts into a stride map: the byte offset of
    /// each buffer plus its channel count, so a (buffer, channel) pair can be
    /// resolved to a flat channel index without allocating in the render loop.
    public struct BufferIndex: Equatable {
        public let channelStart: Int
        public let channelCount: Int
    }

    public static func index(_ bufferChannelCounts: [Int]) -> [BufferIndex] {
        var result: [BufferIndex] = []
        var start = 0
        for count in bufferChannelCounts {
            result.append(BufferIndex(channelStart: start, channelCount: count))
            start += count
        }
        return result
    }
}
