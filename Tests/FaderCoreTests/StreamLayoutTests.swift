import Testing
@testable import FaderCore

@Suite("Tap stream layout")
struct StreamLayoutTests {

    @Test("non-interleaved stereo taps map in tap order")
    func nonInterleaved() {
        #expect(StreamLayout.map(bufferChannelCounts: [1, 1, 1, 1], tapCount: 2) == .streams([0..<2, 2..<4]))
    }

    @Test("interleaved stereo taps map in tap order")
    func interleaved() {
        #expect(StreamLayout.map(bufferChannelCounts: [2, 2], tapCount: 2) == .streams([0..<2, 2..<4]))
    }

    @Test("a single tap occupies the first two channels")
    func singleTap() {
        #expect(StreamLayout.map(bufferChannelCounts: [2], tapCount: 1) == .streams([0..<2]))
    }

    @Test("a layout that cannot be attributed to taps is rejected")
    func rejectsMismatch() {
        // The dangerous case. Guessing here would apply one app's volume to
        // another app's audio, so the engine must refuse to mix instead.
        let mapping = StreamLayout.map(bufferChannelCounts: [1, 1, 1], tapCount: 2)
        guard case .unsupported = mapping else {
            Issue.record("expected an unsupported layout, got \(mapping)")
            return
        }
    }

    @Test("no input buffers is rejected")
    func rejectsEmpty() {
        let mapping = StreamLayout.map(bufferChannelCounts: [], tapCount: 1)
        guard case .unsupported = mapping else {
            Issue.record("expected an unsupported layout, got \(mapping)")
            return
        }
    }

    @Test("zero taps maps to zero channels")
    func noTaps() {
        #expect(StreamLayout.map(bufferChannelCounts: [], tapCount: 0) == .streams([]))
    }

    @Test("flattened indices line up with buffer channel counts")
    func flatIndex() {
        #expect(StreamLayout.index([1, 2, 1]) == [
            StreamLayout.BufferIndex(channelStart: 0, channelCount: 1),
            StreamLayout.BufferIndex(channelStart: 1, channelCount: 2),
            StreamLayout.BufferIndex(channelStart: 3, channelCount: 1),
        ])
    }
}
