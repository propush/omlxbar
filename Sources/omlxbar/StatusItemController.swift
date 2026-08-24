import AppKit
import SwiftUI

/// Owns the menubar dot and the popover it toggles.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let panel: OverlayPanel
    private let client: OMLXClient
    private var hotKey: HotKey?

    private var renderedState: ServerState?
    private var pulseTimer: Timer?
    private var pulsePhase = false
    private var stateObservation: NSKeyValueObservation?

    init(client: OMLXClient) {
        self.client = client
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        panel = OverlayPanel { maxHeight in
            AnyView(OverlayView(client: client, maxContentHeight: maxHeight))
        }
        super.init()

        configureButton()

        hotKey = HotKey { [weak self] in self?.toggle() }
        hotKey?.register()

        render(.offline)
    }

    // MARK: Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(buttonClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: Actions

    @objc private func buttonClicked() {
        guard let event = NSApp.currentEvent else { return toggle() }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            toggle()
        }
    }

    func toggle() {
        if panel.isVisible {
            panel.dismiss()
        } else {
            show()
        }
    }

    private func show() {
        guard let button = statusItem.button else { return }
        // Accessory apps must activate for the overlay to take keyboard focus
        // when it is opened by the global hotkey rather than by a click.
        NSApp.activate()
        panel.present(below: button) { [weak self] in
            self?.client.setOverlayVisible(false)
        }
        client.setOverlayVisible(true)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit omlxbar", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // restore click-to-toggle for the next click
    }

    @objc private func openDashboard() {
        NSWorkspace.shared.open(client.config.dashboardURL)
    }

    /// Diagnostics for `--probe-popover`: where the overlay actually landed.
    func probeGeometry() -> (anchor: NSRect, overlay: NSRect?, flipped: Bool)? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        return (anchor, panel.isVisible ? panel.frame : nil, button.isFlipped)
    }

    // MARK: Rendering

    /// Called by the app delegate whenever the client's state changes.
    func render(_ state: ServerState) {
        guard let button = statusItem.button else { return }
        if renderedState != state {
            renderedState = state
            button.toolTip = state.accessibilityDescription
            configurePulse(for: state)
        }
        button.image = Self.dotImage(color: state.color, filled: state.isFilled, dimmed: pulsePhase)
        button.image?.accessibilityDescription = state.accessibilityDescription
    }

    private func configurePulse(for state: ServerState) {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulsePhase = false
        guard state.pulses else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let current = self.renderedState else { return }
                self.pulsePhase.toggle()
                self.render(current)
            }
        }
    }

    /// The dot itself. Not a template image — the whole point is the colour, so
    /// it must survive the menubar's own tinting.
    private static func dotImage(color: NSColor, filled: Bool, dimmed: Bool) -> NSImage {
        let side: CGFloat = 16
        let diameter: CGFloat = 9
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let rect = NSRect(
                x: (side - diameter) / 2,
                y: (side - diameter) / 2,
                width: diameter,
                height: diameter
            )
            let effective = dimmed ? color.withAlphaComponent(0.4) : color

            if filled {
                effective.setFill()
                NSBezierPath(ovalIn: rect).fill()
                // A faint rim keeps the dot legible on both light and dark bars.
                NSColor.black.withAlphaComponent(0.25).setStroke()
                let rim = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                rim.lineWidth = 1
                rim.stroke()
            } else {
                effective.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.9, dy: 0.9))
                ring.lineWidth = 1.6
                ring.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
