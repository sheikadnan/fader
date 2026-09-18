import Foundation

/// Per-app gain smoothing.
///
/// Without this, dragging a slider writes a new gain once per frame and the
/// discontinuities are audible as zipper noise. A short linear ramp per audio
/// callback removes that at negligible cost, and keeps the render loop free of
/// any state beyond two floats.
public struct GainRamp {

    /// Long enough to remove zipper noise, short enough that a slider still
    /// feels instant. 30 ms is the usual figure for volume ramps.
    public static let durationSeconds: Float = 0.03

    /// Largest gain change permitted per sample frame.
    public static func maxDeltaPerFrame(sampleRate: Double) -> Float {
        let frames = max(durationSeconds * Float(sampleRate), 1)
        return 1 / frames
    }

    /// Result of advancing the ramp for one callback.
    public struct Step: Equatable {
        /// Gain at the first frame of the buffer.
        public let start: Float
        /// Gain at the last frame of the buffer.
        public let end: Float
        /// Per-frame increment to apply across the buffer.
        public let delta: Float
    }

    /// Advances `current` toward `target` by at most `maxDelta * frames`,
    /// returning a two-point ramp that spans the buffer.
    ///
    /// The ramp never overshoots: once it reaches `target` it stays there.
    public static func advance(current: Float, target: Float, frames: Int, maxDeltaPerFrame: Float) -> Step {
        guard frames > 0 else { return Step(start: current, end: current, delta: 0) }

        let limit = maxDeltaPerFrame * Float(frames)
        let difference = target - current
        let clamped = Swift.max(-limit, Swift.min(limit, difference))
        let end = current + clamped

        // Snap the last sub-step so rounding cannot leave a permanent residual.
        let settled = abs(target - end) < maxDeltaPerFrame ? target : end
        let delta = frames > 1 ? (settled - current) / Float(frames - 1) : 0

        return Step(start: current, end: settled, delta: delta)
    }
}
