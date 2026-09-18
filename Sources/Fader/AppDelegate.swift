import AppKit
import FaderCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var store: MixerStore?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = MixerStore()
        let menuBar = MenuBarController(store: store)
        self.store = store
        self.menuBar = menuBar
        menuBar.install()
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Destroys every tap. Any app that was being mixed drops back to the
        // system's own audio path, at full volume, before we exit.
        store?.stop()
    }
}
