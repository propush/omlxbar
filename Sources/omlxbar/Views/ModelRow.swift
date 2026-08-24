import SwiftUI

/// Everything the overlay knows about one model, merged from the three
/// endpoints that each hold a piece of it.
struct ModelSnapshot: Identifiable {
    let id: String
    /// Static description from /admin/api/models. Nil for a model that is
    /// resident but no longer in the discovery list.
    var info: ModelInfoDTO?
    /// Live state from /admin/api/activity. Nil when the model is not loaded.
    var live: ActiveModelDTO?
    /// Counters from /admin/api/stats for the selected scope.
    var stats: StatsDTO?
    /// Server-wide sampling defaults, needed to resolve what this model's
    /// parameters actually are when it has no per-model override.
    var sampling: SamplingSettingsDTO?

    var isLoaded: Bool { live != nil }
    var isLoading: Bool { live?.isLoading ?? info?.isLoading ?? false }
    var isBusy: Bool { (live?.activeRequests ?? 0) > 0 }

    var displayName: String { info?.alias ?? id }
    var sizeFormatted: String { live?.sizeFormatted ?? info?.sizeFormatted ?? "" }

    /// Context window actually in force, mirroring
    /// `server.get_max_context_window`: a per-model override always wins,
    /// otherwise the native length is clamped by the global policy.
    var effectiveContextLength: Int? {
        if let override = info?.settings?.maxContextWindow { return override }
        if let native = info?.modelContextLength {
            if let policy = sampling?.maxContextWindowPolicy { return Swift.min(native, policy) }
            return native
        }
        return sampling?.maxContextWindow
    }

    var temperature: Double? { info?.settings?.temperature ?? sampling?.temperature }
    var topP: Double? { info?.settings?.topP ?? sampling?.topP }
    var topK: Int? { info?.settings?.topK ?? sampling?.topK }
    var maxTokens: Int? { info?.settings?.maxTokens ?? sampling?.maxTokens }

    var dotColor: Color {
        if isBusy { return Theme.accentRed }
        if isLoading { return Theme.accentYellow }
        if isLoaded { return Theme.accentYellow }
        return Theme.faint
    }
}

extension ModelSnapshot {
    /// Merge the three endpoints that each hold part of the picture into one
    /// row per known model, ordered the way the overlay lists them: whatever is
    /// working first, then what is resident, then by how much it has served.
    static func merge(
        models: [ModelInfoDTO],
        activity: ActiveModelsDTO,
        perModel: [String: StatsDTO],
        sampling: SamplingSettingsDTO?
    ) -> [ModelSnapshot] {
        let liveByID = Dictionary(
            activity.models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var byID: [String: ModelSnapshot] = [:]
        var order: [String] = []

        for info in models {
            byID[info.id] = ModelSnapshot(
                id: info.id,
                info: info,
                live: liveByID[info.id],
                stats: perModel[info.id],
                sampling: sampling
            )
            order.append(info.id)
        }
        // A resident model that discovery no longer lists still deserves a row.
        for (id, live) in liveByID where byID[id] == nil {
            byID[id] = ModelSnapshot(
                id: id, info: nil, live: live, stats: perModel[id], sampling: sampling
            )
            order.append(id)
        }
        // While the server is down there is no model list at all — fall back to
        // whatever the persisted stats file remembers.
        if order.isEmpty {
            for (id, stats) in perModel where !stats.isEmpty {
                byID[id] = ModelSnapshot(
                    id: id, info: nil, live: nil, stats: stats, sampling: sampling
                )
                order.append(id)
            }
        }

        return order.compactMap { byID[$0] }.sorted { a, b in
            if a.isBusy != b.isBusy { return a.isBusy }
            if a.isLoaded != b.isLoaded { return a.isLoaded }
            let ra = a.stats?.totalRequests ?? 0
            let rb = b.stats?.totalRequests ?? 0
            if ra != rb { return ra > rb }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }
}

struct ModelRow: View {
    let model: ModelSnapshot
    var dimmed: Bool = false

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            if let stats = model.stats, !stats.isEmpty { counters(stats) }
            if let live = model.live { liveDetail(live) }
            if isExpanded { parameters }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() } }
    }

    // MARK: Rows

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.dotColor)
                .frame(width: 7, height: 7)

            Text(model.displayName)
                .font(.system(size: 12, weight: model.isLoaded ? .semibold : .regular))
                .foregroundStyle(model.isLoaded ? Theme.value : Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if model.info?.pinned == true {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.faint)
            }

            Spacer(minLength: 6)

            Text(model.sizeFormatted)
                .font(Theme.number(10.5))
                .foregroundStyle(Theme.faint)
        }
    }

    private func counters(_ stats: StatsDTO) -> some View {
        HStack(spacing: 5) {
            metric(Fmt.compactInt(stats.totalTokensServed), unit: "tok")
            dot
            metric(Fmt.percent(stats.cacheEfficiency), unit: "cache")
            dot
            metric(
                "\(Fmt.tps(stats.avgPrefillTps))/\(Fmt.tps(stats.avgGenerationTps))",
                unit: "tok/s"
            )
            dot
            metric(Fmt.int(stats.totalRequests), unit: "req")
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
    }

    @ViewBuilder
    private func liveDetail(_ live: ActiveModelDTO) -> some View {
        if live.isLoading {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                Text(loadingText(live))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.accentYellow)
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
        } else if !live.prefilling.isEmpty || !live.generating.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(live.prefilling) { p in
                    HStack(spacing: 5) {
                        Text("prefill")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.accentRed)
                        Text("\(Fmt.compactInt(p.processed))/\(Fmt.compactInt(p.total))")
                            .font(Theme.number(10.5))
                            .foregroundStyle(Theme.secondary)
                        Text("\(Fmt.tps(p.speed)) tok/s")
                            .font(Theme.number(10.5))
                            .foregroundStyle(Theme.secondary)
                        if let eta = p.eta {
                            Text("eta \(Fmt.duration(eta))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.faint)
                        }
                        Spacer(minLength: 0)
                    }
                }
                ForEach(live.generating) { g in
                    HStack(spacing: 5) {
                        Text("generating")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.accentRed)
                        Text("\(Fmt.tps(g.tokensPerSecond)) tok/s")
                            .font(Theme.number(10.5))
                            .foregroundStyle(Theme.value)
                        Text("\(Fmt.int(g.generatedTokens)) tok")
                            .font(Theme.number(10.5))
                            .foregroundStyle(Theme.secondary)
                        if let elapsed = g.elapsedSeconds {
                            Text(Fmt.duration(elapsed))
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.faint)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if live.waitingRequests > 0 {
                    Text("\(live.waitingRequests) waiting")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.accentYellow)
                }
            }
            .padding(.leading, 14)
        } else {
            HStack(spacing: 5) {
                if let idle = live.idleSeconds {
                    Text("idle \(Fmt.duration(idle))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.faint)
                }
                if let ttl = live.ttlRemainingSeconds {
                    dot
                    Text("unloads in \(Fmt.duration(ttl))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
        }
    }

    private var parameters: some View {
        let info = model.info
        let s = info?.settings
        return FlowLine(items: [
            model.effectiveContextLength.map { "ctx \(Fmt.int($0))" },
            info?.engineType.isEmpty == false ? info?.engineType : nil,
            info?.configModelType,
            model.temperature.map { "temp \(Fmt.param($0))" },
            model.topP.map { "top_p \(Fmt.param($0))" },
            model.topK.flatMap { $0 > 0 ? "top_k \($0)" : nil },
            s?.minP.flatMap { $0 > 0 ? "min_p \(Fmt.param($0))" : nil },
            model.maxTokens.map { "max_tok \(Fmt.compactInt($0))" },
            s?.ttlSeconds.map { "ttl \(Fmt.duration(Double($0)))" },
            s?.enableThinking == true ? "thinking" : nil,
        ].compactMap { $0 })
        .padding(.leading, 14)
        .padding(.top, 2)
    }

    // MARK: Bits

    private var dot: some View {
        Text("·").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
    }

    private func metric(_ value: String, unit: String) -> some View {
        HStack(spacing: 2.5) {
            Text(value)
                .font(Theme.number(10.5))
                .foregroundStyle(dimmed ? Theme.faint : Theme.secondary)
            Text(unit)
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
        }
    }

    private func loadingText(_ live: ActiveModelDTO) -> String {
        if let remaining = live.loadingRemainingSecondsEstimate {
            return "loading — about \(Fmt.duration(remaining)) left"
        }
        if let elapsed = live.loadingElapsedSeconds {
            return "loading — \(Fmt.duration(elapsed))"
        }
        return "loading"
    }
}

/// Wrapping row of small pill-less tags, used for model parameters.
private struct FlowLine: View {
    let items: [String]

    var body: some View {
        Text(items.joined(separator: "  ·  "))
            .font(.system(size: 10))
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
