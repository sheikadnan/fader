import AppKit
import FaderCore
import os
import SwiftUI

@MainActor
final class MenuBarController {

    private static let symbolName = "slider.vertical.3"

    private let store: MixerStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let log = Logger(subsystem: "com.fader.app", category: "menubar")

    init(store: MixerStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    func install() {
        configureButton()

        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 360, height: 460)
        popover.contentViewController = NSHostingController(rootView: MixerView(store: store))

        reportGeometry()
    }

    /// Fader has no Dock icon and no window, so this button is the entire user
    /// interface. It must never end up invisible or zero-width: if the symbol
    /// cannot be loaded, fall back to a text title.
    private func configureButton() {
        guard let button = statusItem.button else { return }

        if let image = NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: "Fader") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "Fader"
        }

        button.toolTip = "Fader — per-app volume"
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Records where the item landed. Menu bar space is finite and macOS hides
    /// overflow items without telling anyone, so "I can't see the icon" should
    /// be answerable from the log rather than guessed at.
    private func reportGeometry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            guard let button = statusItem.button, let window = button.window else {
                log.error("status item has no window — the icon is not on screen")
                return
            }
            log.info(
                """
                status item: visible=\(window.isVisible, privacy: .public) \
                frame=\(NSStringFromRect(window.frame), privacy: .public) \
                hasImage=\(button.image != nil, privacy: .public) \
                title=\(button.title, privacy: .public)
                """
            )
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            show()
        }
    }

    private func show() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // The popover is transient, but the app is an accessory, so it needs an
        // explicit activation to receive key events.
        NSApp.activate(ignoringOtherApps: true)
    }
}
