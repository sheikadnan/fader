import Testing
@testable import FaderCore

@Suite("Gain ramp")
struct GainRampTests {

    @Test("a full-length ramp lands exactly on the target")
    func reachesTargetExactly() {
        let rate = 48_000.0
        let maxDelta = GainRamp.maxDeltaPerFrame(sampleRate: rate)
        let frames = Int(0.03 * rate)

        let step = GainRamp.advance(current: 1.0, target: 0.0, frames: frames, maxDeltaPerFrame: maxDelta)

        #expect(abs(step.end - 0.0) < 1e-6)
        #expect(abs(step.start - 1.0) < 1e-6)
    }

    @Test("the ramp never overshoots the target")
    func neverOvershoots() {
        let maxDelta = GainRamp.maxDeltaPerFrame(sampleRate: 48_000)
        var current: Float = 1.0
        for _ in 0..<200 {
            let step = GainRamp.advance(current: current, target: 0.25, frames: 512, maxDeltaPerFrame: maxDelta)
            #expect(step.end >= 0.25)
            #expect(step.end <= current)
            current = step.end
        }
        #expect(abs(current - 0.25) < 1e-6)
    }

    @Test("the ramp is monotonic across one buffer")
    func monotonicWithinBuffer() {
        let maxDelta = GainRamp.maxDeltaPerFrame(sampleRate: 48_000)
        let step = GainRamp.advance(current: 1.0, target: 0.0, frames: 256, maxDeltaPerFrame: maxDelta)

        #expect(step.delta < 0)
        #expect(abs((step.start + step.delta * 255) - step.end) < 1e-4)
    }

    @Test("zero frames is a no-op")
    func zeroFrames() {
        let step = GainRamp.advance(current: 0.5, target: 1.0, frames: 0, maxDeltaPerFrame: 0.001)
        #expect(step.start == 0.5)
        #expect(step.end == 0.5)
        #expect(step.delta == 0)
    }

    @Test("30 ms of smoothing at 48 kHz")
    func rampDuration() {
        let maxDelta = GainRamp.maxDeltaPerFrame(sampleRate: 48_000)
        #expect(abs(maxDelta - 1.0 / 1440.0) < 1e-9)
    }
}
