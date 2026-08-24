import ServiceManagement
import SwiftUI

struct OverlayView: View {
    @ObservedObject var client: OMLXClient
    /// Ceiling handed down from the status item: the usable height of the
    /// screen the menubar icon sits on. Without it a tall overlay (several
    /// models, a couple of rows expanded) does not fit below the menubar and
    /// AppKit repositions the popover upward, behind the notch.
    var maxContentHeight: CGFloat = 640

    @State private var contentHeight: CGFloat = 0

    /// nil until the content has been measured, so the popover sizes itself
    /// naturally on first show instead of snapping open from zero.
    private var resolvedHeight: CGFloat? {
        contentHeight > 0 ? min(contentHeight, maxContentHeight) : nil
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ContentHeightKey.self, value: proxy.size.height
                        )
                    }
                )
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Theme.overlayWidth, height: resolvedHeight)
        .background(Theme.ground)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HeaderView(
                state: client.state,
                activeModelNames: activeModelNames,
                device: client.device,
                uptime: client.totals.uptimeSeconds
            )

            if client.state == .offline { offlineBanner }

            scopePicker
            tiles

            SpeedSection(
                prefillTps: stats.avgPrefillTps,
                generationTps: stats.avgGenerationTps,
                dimmed: client.usingOfflineStats
            )

            if client.state != .offline {
                MemoryBar(
                    used: client.activity.modelMemoryUsed,
                    max: client.activity.modelMemoryMax,
                    pressure: client.activity.memoryPressure,
                    deviceMemoryGB: client.device.memoryGb,
                    enforcerEnabled: client.globalSettings.memory?.prefillMemoryGuard ?? false
                )
            }

            modelsSection
            Divider().overlay(Theme.hairline)
            FooterView(client: client)
        }
        .padding(12)
        .frame(width: Theme.overlayWidth)
    }

    // MARK: Sections

    private var offlineBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: client.authFailed ? "lock.fill" : "bolt.horizontal.circle")
                .font(.system(size: 11))
            Text(
                client.authFailed
                    ? "Rejected by oMLX — check the API key in ~/.omlx/settings.json"
                    : "oMLX is not responding on \(client.config.host):\(client.config.port)"
            )
            .font(.system(size: 10.5))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.accentYellow)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(fill: Theme.accentYellow.opacity(0.08))
    }

    @ViewBuilder
    private var scopePicker: some View {
        HStack(spacing: 8) {
            if client.usingOfflineStats {
                // ~/.omlx/stats.json only ever holds all-time totals, so
                // offering a Session choice here would be a lie.
                Text("All-Time")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                Text("from disk")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.faint)
            } else {
                Picker("", selection: $client.scope) {
                    ForEach(StatsScope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
            }
            modelPicker
            Spacer(minLength: 0)
        }
    }

    /// The dashboard's model filter: "All Models" plus everything the overlay
    /// knows about. Picking one narrows the tiles, the speed panel and the list
    /// below to that model; the header and the memory bar stay server-wide.
    private var modelPicker: some View {
        Picker("", selection: $client.modelFilter) {
            Text("All Models").tag(String?.none)
            ForEach(modelChoices) { choice in
                Text(choice.name).tag(String?.some(choice.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 178)
    }

    /// Every filterable model, by name. Deliberately not in the list's order —
    /// that one moves busy models to the top, and a menu that reshuffles under
    /// the pointer is worse than one that ignores what the server is doing.
    /// A selection whose model has dropped out of the server's list stays in
    /// the menu: without a tag matching it the picker would read "All Models"
    /// while the numbers below stayed filtered.
    private var modelChoices: [ModelChoice] {
        var choices = allSnapshots.map { ModelChoice(id: $0.id, name: $0.displayName) }
        if let id = client.modelFilter, !choices.contains(where: { $0.id == id }) {
            choices.append(ModelChoice(id: id, name: id))
        }
        return choices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Name of the filtered model, for the empty state.
    private var filterName: String? {
        guard let id = client.modelFilter else { return nil }
        return modelChoices.first { $0.id == id }?.name ?? id
    }

    /// What the tiles and the speed panel count, honouring the model filter.
    private var stats: StatsDTO { client.displayedTotals }

    private var tiles: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                StatTile(
                    label: "Total Prefill Tokens",
                    value: Fmt.int(stats.totalPromptTokens),
                    dimmed: client.usingOfflineStats
                )
                StatTile(
                    label: "Cached Tokens",
                    value: Fmt.int(stats.totalCachedTokens),
                    dimmed: client.usingOfflineStats
                )
            }
            StatTile(
                label: "Cache Efficiency",
                value: Fmt.percent(stats.cacheEfficiency),
                emphasized: true,
                dimmed: client.usingOfflineStats
            )
            // Secondary counters ride on one line rather than two more tiles —
            // the dashboard has three tiles and so should this, or the overlay
            // grows taller than the space under the menubar.
            HStack(spacing: 5) {
                Text(Fmt.int(stats.totalCompletionTokens))
                    .font(Theme.number(11))
                    .foregroundStyle(Theme.secondary)
                Text("completion")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faint)
                Text("·").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                Text(Fmt.int(stats.totalRequests))
                    .font(Theme.number(11))
                    .foregroundStyle(Theme.secondary)
                Text("requests")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
    }

    private var modelsSection: some View {
        VStack(spacing: 0) {
            SectionHeader(
                systemImage: "waveform.path.ecg",
                title: "Models",
                trailing: modelsTrailing
            )

            if visibleSnapshots.isEmpty {
                Text(filterName.map { "No stats for \($0)" } ?? "No models loaded")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleSnapshots.enumerated()), id: \.element.id) { index, snapshot in
                        if index > 0 {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                        ModelRow(model: snapshot, dimmed: client.usingOfflineStats)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .background(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(Theme.card)
        )
    }

    private var modelsTrailing: String? {
        guard client.state != .offline else { return nil }
        // Counted off the rows actually shown, so a filtered list never claims
        // the whole server's tally.
        let shown = visibleSnapshots
        let loaded = shown.filter(\.isLoaded).count
        let active = shown.reduce(0) { $0 + ($1.live?.activeRequests ?? 0) }
        let waiting = shown.reduce(0) { $0 + ($1.live?.waitingRequests ?? 0) }
        var parts: [String] = []
        if loaded > 0 { parts.append("\(loaded) loaded") }
        if active > 0 { parts.append("\(active) active") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Merge

    private var allSnapshots: [ModelSnapshot] {
        ModelSnapshot.merge(
            models: client.models,
            activity: client.activity,
            perModel: client.perModel,
            sampling: client.globalSettings.sampling
        )
    }

    private var visibleSnapshots: [ModelSnapshot] {
        guard let id = client.modelFilter else { return allSnapshots }
        return allSnapshots.filter { $0.id == id }
    }

    /// The header describes the server, not the filter, so it sees every model.
    private var activeModelNames: [String] {
        let busy = allSnapshots.filter(\.isBusy)
        if !busy.isEmpty { return busy.map(\.displayName) }
        return allSnapshots.filter(\.isLoaded).map(\.displayName)
    }
}

/// One entry in the model filter menu.
private struct ModelChoice: Identifiable {
    let id: String
    let name: String
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Footer

private struct FooterView: View {
    @ObservedObject var client: OMLXClient
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        HStack(spacing: 10) {
            Button {
                NSWorkspace.shared.open(client.config.dashboardURL)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.square")
                    Text("Open Dashboard")
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)

            Spacer(minLength: 0)

            Text(HotKey.currentDescription())
                .font(Theme.number(10))
                .foregroundStyle(Theme.faint)

            Menu {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Divider()
                Button("Quit omlxbar") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration needs a signed bundle in a stable location; if it
            // fails, put the switch back rather than lying about the state.
            launchAtLogin = SMAppService.mainApp.status == .enabled
            NSLog("omlxbar: launch-at-login change failed: \(error.localizedDescription)")
        }
    }
}
