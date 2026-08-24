import AppKit
import Foundation
import SwiftUI

/// `omlxbar --selftest` performs one full poll against the live oMLX server and
/// prints what the menubar and overlay would show, then exits.
///
/// This exists so the app's real decoding and state derivation can be checked
/// from a terminal — without it, verifying the dot colour means looking at the
/// menubar with your eyes.
@MainActor
enum SelfTest {
    static func run() async -> Int32 {
        let client = OMLXClient()
        let config = client.config

        print("config      \(config.baseURL.absoluteString)  api_key=\(config.apiKey == nil ? "none" : "set")")

        if CommandLine.arguments.contains("--alltime") { client.scope = .allTime }
        client.setOverlayVisible(true)
        // setOverlayVisible kicks off its refreshes on a detached task; give
        // them a moment to land before reading the published values.
        try? await Task.sleep(for: .seconds(2))

        let dot: String
        switch client.state {
        case .offline: dot = "GRAY (hollow)"
        case .idleNoModel: dot = "GREEN"
        case .loadedIdle: dot = "YELLOW"
        case .loading: dot = "YELLOW (pulsing)"
        case .active: dot = "RED"
        }

        print("state       \(client.state.label)  ->  dot \(dot)")
        print("hotkey      \(HotKey.currentDescription())")
        if client.authFailed { print("auth        REJECTED — check ~/.omlx/settings.json api_key") }
        if client.usingOfflineStats { print("source      ~/.omlx/stats.json (server unreachable)") }
        if !client.device.summary.isEmpty { print("device      \(client.device.summary)") }

        let t = client.totals
        print("")
        print("scope       \(client.usingOfflineStats ? "All-Time (from disk)" : client.scope.label)")
        print("  Total Prefill Tokens   \(Fmt.int(t.totalPromptTokens))")
        print("  Cached Tokens          \(Fmt.int(t.totalCachedTokens))")
        print("  Cache Efficiency       \(Fmt.percent(t.cacheEfficiency))")
        print("  Completion Tokens      \(Fmt.int(t.totalCompletionTokens))")
        print("  Requests               \(Fmt.int(t.totalRequests))")
        print("  Prompt Processing      \(Fmt.tps(t.avgPrefillTps)) tok/s")
        print("  Token Generation       \(Fmt.tps(t.avgGenerationTps)) tok/s")
        if !client.usingOfflineStats {
            print("  Uptime                 \(Fmt.duration(t.uptimeSeconds))")
        }

        let mem = client.activity
        print("")
        let enforcer = client.globalSettings.memory?.prefillMemoryGuard ?? false
        let ceiling = (enforcer && mem.modelMemoryMax > 0)
            ? Fmt.bytes(mem.modelMemoryMax) : "none (enforcer disabled)"
        print("memory      \(Fmt.bytes(mem.modelMemoryUsed)) used, ceiling \(ceiling)")
        print("requests    \(mem.totalActiveRequests) active, \(mem.totalWaitingRequests) waiting")

        print("")
        let snapshots = ModelSnapshot.merge(
            models: client.models,
            activity: client.activity,
            perModel: client.perModel,
            sampling: client.globalSettings.sampling
        )
        print("models      \(client.models.count) discovered, \(mem.models.count) resident")

        for m in snapshots {
            let mark = m.isBusy ? "\u{25CF}" : (m.isLoaded ? "\u{25CB}" : "\u{00B7}")
            var title = "  \(mark) \(m.id)"
            if let alias = m.info?.alias { title += "  (\(alias))" }
            print(title)

            if let s = m.stats, !s.isEmpty {
                print("      \(Fmt.int(s.totalPromptTokens)) prefill · \(Fmt.percent(s.cacheEfficiency)) cache · \(Fmt.tps(s.avgPrefillTps))/\(Fmt.tps(s.avgGenerationTps)) tok/s · \(s.totalRequests) req")
            }

            if let l = m.live {
                var bits = ["size \(l.sizeFormatted)"]
                if l.isLoading { bits.append("LOADING") }
                if let idle = l.idleSeconds { bits.append("idle \(Fmt.duration(idle))") }
                if let ttl = l.ttlRemainingSeconds { bits.append("ttl \(Fmt.duration(ttl))") }
                for g in l.generating {
                    bits.append("generating \(Fmt.tps(g.tokensPerSecond)) tok/s (\(g.generatedTokens) tok)")
                }
                for p in l.prefilling {
                    bits.append("prefill \(p.processed)/\(p.total) @ \(Fmt.tps(p.speed)) tok/s")
                }
                if l.waitingRequests > 0 { bits.append("\(l.waitingRequests) waiting") }
                print("      \(bits.joined(separator: " · "))")
            }

            var params: [String] = []
            if let ctx = m.effectiveContextLength { params.append("ctx \(Fmt.int(ctx))") }
            if let engine = m.info?.engineType, !engine.isEmpty { params.append(engine) }
            if let temp = m.temperature { params.append("temp \(Fmt.param(temp))") }
            if let topP = m.topP { params.append("top_p \(Fmt.param(topP))") }
            if let topK = m.topK, topK > 0 { params.append("top_k \(topK)") }
            if let maxTok = m.maxTokens { params.append("max_tok \(Fmt.compactInt(maxTok))") }
            if !params.isEmpty { print("      \(params.joined(separator: " · "))") }
        }

        // Layout diagnostics: is the overlay too tall for the space under the
        // menubar, or is it merely being positioned badly?
        for screen in NSScreen.screens {
            let f = screen.frame, v = screen.visibleFrame
            print("")
            print("screen      \(Int(f.width))x\(Int(f.height)) pt   visible \(Int(v.width))x\(Int(v.height)) pt at y=\(Int(v.origin.y))")
            print("            menubar inset \(Int(f.height - v.height - v.origin.y)) pt, safeAreaTop \(Int(screen.safeAreaInsets.top)) pt")
        }
        let probe = NSHostingController(
            rootView: OverlayView(client: client, maxContentHeight: 10_000)
        )
        probe.view.layoutSubtreeIfNeeded()
        let fitting = probe.view.fittingSize
        print("overlay     fits at \(Int(fitting.width))x\(Int(fitting.height)) pt")
        if let v = NSScreen.main?.visibleFrame {
            print("verdict     \(fitting.height <= v.height ? "FITS below the menubar" : "TOO TALL — must clamp")")
        }

        client.stop()
        return client.state == .offline && !client.usingOfflineStats ? 1 : 0
    }
}
