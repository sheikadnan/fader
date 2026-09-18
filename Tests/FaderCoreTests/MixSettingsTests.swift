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
        let path = AudioProcess(
            objectID: 1, pid: 2, bundleID: nil,
            executablePath: "/usr/bin/afplay", isRunningOutput: true
        )
        #expect(path.key == AppKey(executablePath: "/usr/bin/afplay"))
        #expect(path.displayName == "afplay")

        let bare = AudioProcess(objectID: 1, pid: 2, bundleID: nil, isRunningOutput: true)
        #expect(bare.key.rawValue == "pid:2")
        #expect(bare.displayName == "Process 2")
    }

    @Test("a helper process takes the identity of the app it belongs to")
    func helperTakesOwnerIdentity() {
        // Chrome plays YouTube from `Google Chrome Helper`, whose own name is
        // the bare word "helper". Showing that, or storing a volume against
        // com.google.Chrome.helper, would be useless to the user.
        let helper = AudioProcess(
            objectID: 110,
            pid: 21517,
            bundleID: "com.google.Chrome.helper",
            executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
            isRunningOutput: true,
            ownerPID: 15633,
            ownerBundleID: "com.google.Chrome",
            ownerName: "Google Chrome"
        )

        #expect(helper.key == AppKey(bundleID: "com.google.Chrome"))
        #expect(helper.displayName == "Google Chrome")
    }

    @Test("a helper and its parent share one volume setting")
    func helperAndParentShareSettings() {
        let parent = AudioProcess(
            objectID: 104, pid: 15633, bundleID: "com.google.Chrome",
            isRunningOutput: false, ownerPID: 15633,
            ownerBundleID: "com.google.Chrome", ownerName: "Google Chrome"
        )
        let helper = AudioProcess(
            objectID: 110, pid: 21517, bundleID: "com.google.Chrome.helper",
            isRunningOutput: true, ownerPID: 15633,
            ownerBundleID: "com.google.Chrome", ownerName: "Google Chrome"
        )
        #expect(parent.key == helper.key)
    }

    @Test("an owner name is never a bare helper label when a real name exists")
    func ownerNameWins() {
        let process = AudioProcess(
            objectID: 1, pid: 2, bundleID: "com.google.Chrome.helper",
            isRunningOutput: true, ownerName: "Google Chrome"
        )
        #expect(process.displayName == "Google Chrome")
    }
}
