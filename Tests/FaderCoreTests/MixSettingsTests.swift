import Testing
@testable import FaderCore

@Suite("Mixer settings and app identity")
struct MixSettingsTests {

    @Test("unity gain is passthrough, so no tap is created")
    func unityIsPassthrough() {
        #expect(MixSettings.unity.isPassthrough)
        #expect(MixSettings.unity.gain == 1)
    }

    @Test("a muted app is still tapped, or it would keep playing")
    func mutedIsStillTapped() {
        let settings = MixSettings(volume: 1, isMuted: true)
        #expect(settings.gain == 0)
        #expect(!settings.isPassthrough)
    }

    @Test("volume is clamped to 100%")
    func clampsToUnity() {
        #expect(MixSettings(volume: 4).volume == 1)
        #expect(MixSettings(volume: -2).volume == 0)
    }

    @Test("a non-finite volume is replaced rather than propagated")
    func sanitizesNonFinite() {
        #expect(MixSettings(volume: .nan).sanitized().volume == 1)
        #expect(MixSettings(volume: .infinity).sanitized().volume == 1)
    }

    @Test("settings follow the bundle ID, not the process ID")
    func keyIsStableAcrossProcesses() {
        let first = AudioProcess(objectID: 41, pid: 900, bundleID: "com.spotify.client", isRunningOutput: true)
        let second = AudioProcess(objectID: 57, pid: 1400, bundleID: "com.spotify.client", isRunningOutput: true)
        #expect(first.key == second.key)
    }

    @Test("processes without a bundle ID fall back to path, then PID")
    func keyFallbacks() {
        let path = AudioProcess(objectID: 1, pid: 2, bundleID: nil, isRunningOutput: true, executablePath: "/usr/bin/afplay")
        #expect(path.key == AppKey(executablePath: "/usr/bin/afplay"))

        let bare = AudioProcess(objectID: 1, pid: 2, bundleID: nil, isRunningOutput: true)
        #expect(bare.key.rawValue == "pid:2")
    }
}
