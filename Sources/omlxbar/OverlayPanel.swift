import AppKit
import SwiftUI

/// The overlay window.
///
/// This is a manually positioned `NSPanel` rather than an `NSPopover`.
/// `NSStatusBarButton` is a flipped view, and `NSPopover` insists on hanging
/// the overlay off the top edge of it regardless of `preferredEdge` — which
/// puts a 658 pt overlay hundreds of points above the top of the screen,
/// behind the menubar and the notch. A panel lets us compute the frame
/// ourselves and clamp it to the screen's usable area.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Distance kept between the menubar and the top of the overlay.
    private static let gap: CGFloat = 6
    private static let screenMargin: CGFloat = 8

    private let hosting: NSHostingView<AnyView>
    private var dismissMonitors: [Any] = []
    private var onDismiss: (() -> Void)?

    init(content: @escaping (CGFloat) -> AnyView) {
        hosting = NSHostingView(rootView: content(400))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Theme.overlayWidth, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.contentFactory = content

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        // Above normal windows and the menubar's own level, so it is never
        // clipped by whatever is frontmost.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .utilityWindow

        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 14
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        contentView = hosting
    }

    private var contentFactory: ((CGFloat) -> AnyView)?

    // MARK: Presentation

    /// Positions the overlay under `anchorView` and shows it.
    func present(below anchorView: NSView, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss

        guard let anchorWindow = anchorView.window else { return }
        let screen = anchorWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = anchorWindow.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))

        // Lay out against the tallest overlay the screen can take, then take
        // whatever the content actually needs up to that.
        let maxHeight = visible.height - Self.gap - Self.screenMargin
        if let factory = contentFactory { hosting.rootView = factory(maxHeight) }
        hosting.layoutSubtreeIfNeeded()
        let height = min(max(hosting.fittingSize.height, 80), maxHeight)

        let width = Theme.overlayWidth
        var x = anchor.midX - width / 2
        x = min(max(x, visible.minX + Self.screenMargin), visible.maxX - width - Self.screenMargin)
        // Hang from just under the menubar rather than from the icon itself:
        // the icon's own rect sits inside the menubar strip.
        let y = visible.maxY - height - Self.gap

        setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        orderFrontRegardless()
        makeKey()
        installDismissMonitors()
    }

    func dismiss() {
        removeDismissMonitors()
        orderOut(nil)
        onDismiss?()
    }

    // MARK: Dismissal

    private func installDismissMonitors() {
        removeDismissMonitors()

        // A click anywhere else closes the overlay, the way a menu would.
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        )
        if let global { dismissMonitors.append(global) }

        // Esc closes it; clicks inside our own window are left alone.
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown],
            handler: { [weak self] event in
            // Local monitors are delivered on the main thread.
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }  // Escape
                MainActor.assumeIsolated { self.dismiss() }
                return nil
            }
            if event.window !== self {
                MainActor.assumeIsolated { self.dismiss() }
            }
            return event
        })
        if let local { dismissMonitors.append(local) }
    }

    private func removeDismissMonitors() {
        for monitor in dismissMonitors { NSEvent.removeMonitor(monitor) }
        dismissMonitors.removeAll()
    }

    override func resignKey() {
        super.resignKey()
        // Switching to another app should put the overlay away.
        if isVisible { dismiss() }
    }
}
