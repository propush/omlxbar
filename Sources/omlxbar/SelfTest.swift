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

        print("config      \(config.displayTarget)  api_key=\(config.apiKey == nil ? "none" : "set")")
        if let rejection = config.rejection {
            print("REFUSED     \(rejection)")
            return 2
        }

        if CommandLine.arguments.contains("--alltime") { client.scope = .allTime }
        // --model <id> exercises the overlay's model filter. The overlay
        // remembers its own choice, so put it back before exiting rather than
        // letting a self-test rewrite what the menubar shows next launch.
        let storedFilter = client.modelFilter
        if let flag = CommandLine.arguments.firstIndex(of: "--model"),
           flag + 1 < CommandLine.arguments.count {
            client.modelFilter = CommandLine.arguments[flag + 1]
        }
        defer { client.modelFilter = storedFilter }
        // Awaited to completion rather than slept on: a single request may
        // spend the whole 2 s timeout, so a fixed sleep reported a false
        // picture under exactly the slow conditions this exists to diagnose.
        await client.refreshAll()

        let dot: String
        switch client.state {
        case .offline: dot = "GRAY (hollow)"
        case .idleNoModel: dot = "GREEN"
        case .loadedIdle: dot = "YELLOW"
        case .loading: dot = "YELLOW (pulsing)"
        case .active: dot = "RED"
        case .incompatible: dot = "ORANGE (hollow)"
        case .misconfigured: dot = "ORANGE (hollow)"
        }

        print("state       \(client.state.label)  ->  dot \(dot)")
        print("hotkey      \(HotKey.currentDescription())")
        if client.authFailed { print("auth        REJECTED — check ~/.omlx/settings.json api_key") }
        if client.usingOfflineStats {
            let age = client.offlineStatsCapturedAt.map { "written \(Fmt.age($0))" } ?? "age unknown"
            print("source      ~/.omlx/stats.json (server unreachable, \(age))")
        }
        if client.statsUnavailable { print("source      none — no attributable statistics to show") }
        if client.isStale, let last = client.lastSuccess {
            print("freshness   STALE — last good read \(Fmt.age(last))")
        }
        if !client.device.summary.isEmpty { print("device      \(client.device.summary)") }

        let t = client.displayedTotals
        print("")
        let scopeLabel = client.usingOfflineStats ? "All-Time (from disk)" : client.scope.label
        print("scope       \(scopeLabel)  ·  \(client.modelFilter ?? "All Models")")
        print("  Total Prefill Tokens   \(Fmt.int(t.totalPromptTokens))")
        print("  Cached Tokens          \(Fmt.int(t.totalCachedTokens))")
        print("  Cache Efficiency       \(Fmt.percent(t.cacheEfficiency))")
        print("  Completion Tokens      \(Fmt.int(t.totalCompletionTokens))")
        print("  Requests               \(Fmt.int(t.totalRequests))")
        print("  Prompt Processing      \(Fmt.tps(t.avgPrefillTps)) tok/s")
        print("  Token Generation       \(Fmt.tps(t.avgGenerationTps)) tok/s")
        if !client.usingOfflineStats {
            print("  Uptime                 \(Fmt.duration(client.totals.uptimeSeconds))")
        }

        let mem = client.activity
        print("")
        let memory = MemoryPresentation(
            activity: mem,
            deviceMemoryGB: client.device.memoryGb,
            guardEnabled: client.globalSettings.memory?.prefillMemoryGuard
        )
        print("memory      \(memory.diagnosticSummary)")
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
        let launchAtLoginSuite = "com.pushkin.omlxbar.selftest.\(UUID().uuidString)"
        let launchAtLoginDefaults = UserDefaults(suiteName: launchAtLoginSuite)!
        defer { launchAtLoginDefaults.removePersistentDomain(forName: launchAtLoginSuite) }
        let probe = NSHostingController(
            rootView: OverlayView(
                client: client,
                launchAtLogin: LaunchAtLoginController(defaults: launchAtLoginDefaults),
                maxContentHeight: 10_000
            )
        )
        probe.view.layoutSubtreeIfNeeded()
        let fitting = probe.view.fittingSize
        print("overlay     fits at \(Int(fitting.width))x\(Int(fitting.height)) pt")
        if let v = NSScreen.main?.visibleFrame {
            print("verdict     \(fitting.height <= v.height ? "FITS below the menubar" : "TOO TALL — must clamp")")
        }

        client.stop()
        return client.state.isUncertain && !client.usingOfflineStats ? 1 : 0
    }
}
