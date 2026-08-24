import AppKit
import Combine
import Foundation

/// Which set of counters the overlay is showing.
enum StatsScope: String, CaseIterable, Identifiable {
    case session
    case allTime = "alltime"

    var id: String { rawValue }
    var label: String { self == .session ? "Session" : "All-Time" }
}

/// Polls the oMLX admin API and publishes everything the UI renders.
///
/// Two cadences: a slow one that only needs `/admin/api/activity` to colour the
/// menubar dot, and a fast one used while the overlay is open. Switching is
/// driven by `setOverlayVisible(_:)`.
@MainActor
final class OMLXClient: ObservableObject {

    // MARK: Published state

    @Published private(set) var state: ServerState = .offline
    @Published private(set) var activity = ActiveModelsDTO()
    @Published private(set) var totals = StatsDTO.empty
    @Published private(set) var perModel: [String: StatsDTO] = [:]
    @Published private(set) var models: [ModelInfoDTO] = []
    @Published private(set) var device = DeviceInfoDTO()
    @Published private(set) var globalSettings = GlobalSettingsDTO()
    @Published private(set) var config = OMLXConfig.fallback
    /// Set when the server answered but rejected us, so the overlay can say why.
    @Published private(set) var authFailed = false
    /// True while showing numbers recovered from ~/.omlx/stats.json.
    @Published private(set) var usingOfflineStats = false

    @Published var scope: StatsScope = .session {
        didSet { guard oldValue != scope else { return }; Task { await refreshStats() } }
    }

    /// Which model's counters the overlay shows; nil is "All Models". Purely a
    /// display filter — `refreshStats()` already fetches every model's slice,
    /// so changing it costs no request.
    @Published var modelFilter: String? = OMLXClient.storedModelFilter() {
        didSet { guard oldValue != modelFilter else { return }; Self.store(modelFilter) }
    }

    /// The counters the overlay renders: server-wide, or one model's slice.
    /// `totals` stays whole — the header's uptime is a property of the server.
    var displayedTotals: StatsDTO {
        guard let id = modelFilter else { return totals }
        return perModel[id] ?? .empty
    }

    private static let modelFilterKey = "statsModelFilter"

    private static func storedModelFilter() -> String? {
        let id = UserDefaults.standard.string(forKey: modelFilterKey)
        return (id?.isEmpty ?? true) ? nil : id
    }

    private static func store(_ id: String?) {
        if let id, !id.isEmpty {
            UserDefaults.standard.set(id, forKey: modelFilterKey)
        } else {
            UserDefaults.standard.removeObject(forKey: modelFilterKey)
        }
    }

    // MARK: Cadence

    private static let slowInterval: Duration = .seconds(3)
    private static let fastInterval: Duration = .milliseconds(750)
    /// Stats are heavier than activity, so they refresh every Nth fast tick.
    private static let statsEveryNTicks = 3
    private static let modelsEveryNTicks = 20

    private var overlayVisible = false
    private var pollTask: Task<Void, Never>?
    private var suspended = false
    private var tick = 0

    private let session: URLSession
    private var didAttemptLogin = false

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        // A wedged server must never stall the menubar.
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 4
        cfg.httpCookieStorage = HTTPCookieStorage()
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
        config = OMLXConfig.load()
        observeSleep()
    }

    // MARK: Lifecycle

    func start() {
        guard pollTask == nil else { return }
        // Task inherits this method's MainActor isolation, so the state reads
        // below need no hopping.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.suspended { await self.pollOnce() }
                let interval = self.overlayVisible ? Self.fastInterval : Self.slowInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Called by the status item when the popover opens or closes. Opening
    /// forces an immediate full refresh so the overlay is never stale on show.
    func setOverlayVisible(_ visible: Bool) {
        guard overlayVisible != visible else { return }
        overlayVisible = visible
        if visible {
            tick = 0
            Task {
                await pollOnce()
                // Models first: the per-model stats fan-out needs the list of
                // IDs to ask about.
                await refreshModels()
                await refreshGlobals()
                await refreshStats()
            }
        }
    }

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspended = true }
        }
        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspended = false
                self?.didAttemptLogin = false
            }
        }
    }

    // MARK: Polling

    private func pollOnce() async {
        await refreshActivity()
        guard overlayVisible else { return }
        tick += 1
        if tick % Self.statsEveryNTicks == 0 { await refreshStats() }
        if tick % Self.modelsEveryNTicks == 0 {
            await refreshModels()
            await refreshGlobals()
        }
    }

    private func refreshActivity() async {
        do {
            let dto: ActivityDTO = try await get("/admin/api/activity")
            activity = dto.activeModels
            state = ServerState.from(dto.activeModels)
            authFailed = false
        } catch {
            handle(error)
        }
    }

    private func refreshStats() async {
        do {
            totals = try await get("/admin/api/stats?scope=\(scope.rawValue)")
            usingOfflineStats = false
        } catch {
            handle(error)
            return
        }

        // One request per model for the selected scope. Cheap enough at the
        // handful of models oMLX discovers, and only while the overlay is open.
        var fetched: [String: StatsDTO] = [:]
        for id in modelIDsNeedingStats() {
            guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            else { continue }
            if let dto: StatsDTO = try? await get(
                "/admin/api/stats?model=\(encoded)&scope=\(scope.rawValue)"
            ) {
                fetched[id] = dto
            }
        }
        perModel = fetched
    }

    private func refreshModels() async {
        if let dto: ModelsResponseDTO = try? await get("/admin/api/models") {
            models = dto.models.filter { !$0.isHidden }
        }
    }

    /// Machine description and the global settings that decide a model's
    /// effective parameters. The device never changes; settings can, so they
    /// ride along with the periodic model refresh.
    private func refreshGlobals() async {
        if device.chipName.isEmpty,
           let dto: DeviceInfoDTO = try? await get("/admin/api/device-info") {
            device = dto
        }
        if let dto: GlobalSettingsDTO = try? await get("/admin/api/global-settings") {
            globalSettings = dto
        }
    }

    private func modelIDsNeedingStats() -> [String] {
        var ids = models.map(\.id)
        // A model can be loaded without appearing in the (cached) model list.
        for m in activity.models where !ids.contains(m.id) { ids.append(m.id) }
        return ids
    }

    // MARK: Failure handling

    private func handle(_ error: Error) {
        // A payload we could not parse means the server is up but has changed
        // shape — reporting that as "offline" would be a lie.
        if error is DecodingError { return }

        if case OMLXError.unauthorized = error {
            authFailed = true
        } else {
            authFailed = false
        }
        state = .offline
        activity = ActiveModelsDTO()
        // Re-read settings.json — the server may have moved to a new port.
        let latest = OMLXConfig.load()
        if latest != config { config = latest }
        loadOfflineStats()
    }

    /// Falls back to the server's own persisted all-time file so the overlay
    /// still has something true to show while oMLX is stopped.
    private func loadOfflineStats() {
        guard let persisted = PersistedStats.load() else { return }
        totals = persisted.total
        perModel = persisted.perModel
        usingOfflineStats = true
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String) async throws -> T {
        do {
            return try await request(path)
        } catch OMLXError.unauthorized {
            // One shot at exchanging the API key for a session cookie, then retry.
            guard !didAttemptLogin, try await login() else { throw OMLXError.unauthorized }
            return try await request(path)
        }
    }

    private func request<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: config.baseURL) else {
            throw OMLXError.badURL
        }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = config.apiKey {
            // Harmless when the server skips verification; required by sub-key setups.
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OMLXError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw OMLXError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw OMLXError.http(http.statusCode)
        }
        // Any accepted request means the current credentials work, so allow a
        // fresh login attempt if the session cookie later expires.
        didAttemptLogin = false
        return try OMLXJSON.decoder.decode(T.self, from: data)
    }

    @discardableResult
    private func login() async throws -> Bool {
        didAttemptLogin = true
        guard let key = config.apiKey,
              let url = URL(string: "/admin/api/login", relativeTo: config.baseURL)
        else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["api_key": key, "remember": true]
        )
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return false }
        return true
    }
}

enum OMLXError: Error {
    case badURL
    case badResponse
    case unauthorized
    case http(Int)
}
