import AppKit
import Combine
import SwiftUI

@main
enum OMLXBar {
    static func main() {
        if CommandLine.arguments.contains("--probe-popover") {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            delegate.probePopoverAfterLaunch = true
            app.run()
            exit(0)
        }

        if CommandLine.arguments.contains("--selftest") {
            // Headless probe of the live server; prints what the UI would show.
            let status = runSelfTest()
            exit(status)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menubar-only: no Dock tile, no menu bar of our own.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Drives the async self-test to completion on the main actor.
private func runSelfTest() -> Int32 {
    let box = SelfTestResult()
    Task { @MainActor in
        box.status = await SelfTest.run()
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.status
}

private final class SelfTestResult: @unchecked Sendable {
    var status: Int32 = 1
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = OMLXClient()
    private var statusItem: StatusItemController?
    private var cancellables = Set<AnyCancellable>()
    /// Set by `--probe-popover`: open the overlay, report its geometry, quit.
    var probePopoverAfterLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController(client: client)
        statusItem = controller

        client.$state
            .removeDuplicates()
            .sink { state in
                MainActor.assumeIsolated { controller.render(state) }
            }
            .store(in: &cancellables)

        client.start()

        if probePopoverAfterLaunch {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                controller.toggle()
                try? await Task.sleep(for: .milliseconds(700))
                if let g = controller.probeGeometry() {
                    let screen = NSScreen.main!.frame
                    let visible = NSScreen.main!.visibleFrame
                    print("screen      \(Int(screen.width))x\(Int(screen.height)); menubar occupies y \(Int(visible.maxY))…\(Int(screen.maxY))")
                    print("anchor      x \(Int(g.anchor.minX))…\(Int(g.anchor.maxX))  y \(Int(g.anchor.minY))…\(Int(g.anchor.maxY))  (button.isFlipped=\(g.flipped))")
                    if let p = g.overlay {
                        print("overlay     x \(Int(p.minX))…\(Int(p.maxX))  y \(Int(p.minY))…\(Int(p.maxY))  size \(Int(p.width))x\(Int(p.height))")
                        let overlapsMenubar = p.maxY > visible.maxY
                        let offTop = p.maxY > screen.maxY
                        print("verdict     \(offTop ? "RUNS OFF THE TOP OF THE SCREEN" : overlapsMenubar ? "OVERLAPS THE MENUBAR" : "sits cleanly below the menubar")")
                    } else {
                        print("overlay     window not visible")
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        client.stop()
    }
}
