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
///
/// Statistics never run inside the activity poll. They are heavier — one
/// request per model — so they are handed to a coordinator that bounds their
/// concurrency and their total duration, and the dot keeps updating regardless
/// of how slow they are.
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
    /// When the server last wrote the file behind `usingOfflineStats`. It saves
    /// periodically, so even genuine numbers can be minutes old.
    @Published private(set) var offlineStatsCapturedAt: Date?
    /// True when there is nothing truthful left to show: the server is
    /// unreachable and no attributable history could be recovered.
    @Published private(set) var statsUnavailable = false
    /// Last time `/admin/api/activity` was read successfully. nil means never.
    @Published private(set) var lastSuccess: Date?
    /// True when what is on screen is older than a refresh interval or two, so
    /// the overlay can stop presenting it as current.
    @Published private(set) var isStale = false

    @Published var scope: StatsScope = .session {
        didSet { guard oldValue != scope else { return }; scheduleStatsRefresh() }
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
    /// Ceiling on one whole stats refresh, however many models it covers.
    static let statsDeadline: Duration = .seconds(6)
    /// How many per-model requests may be in flight at once. Enough to stay
    /// responsive on a large library, few enough not to hammer a server that
    /// is busy doing the actual inference.
    nonisolated static let maxConcurrentStatsRequests = 4
    /// Past this, what is on screen stops counting as current.
    static let staleAfter: TimeInterval = 15

    private var overlayVisible = false
    private var pollTask: Task<Void, Never>?
    private var suspended = false
    private var tick = 0

    private let session: URLSession
    private var didAttemptLogin = false

    // MARK: Refresh coordination

    /// Bumped by every refresh and by every transition that invalidates one.
    /// A refresh may only publish if its generation is still the current one,
    /// so a slow response can never overwrite a newer, faster one.
    private var statsGeneration = 0
    private var statsTask: Task<Void, Never>?
    private var overlayRefreshTask: Task<Void, Never>?

    /// Where the server's persisted all-time file lives. Injectable so the
    /// offline-attribution rules can be tested without touching ~/.omlx.
    private let statsPath: URL

    /// True when the caller chose the target, so the client must not re-derive
    /// one from `settings.json`.
    private let configWasInjected: Bool

    init(session: URLSession? = nil, config: OMLXConfig? = nil, statsPath: URL? = nil) {
        self.statsPath = statsPath ?? OMLXConfig.statsPath
        self.configWasInjected = config != nil
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            // A wedged server must never stall the menubar.
            cfg.timeoutIntervalForRequest = 2
            cfg.timeoutIntervalForResource = 4
            cfg.httpCookieStorage = HTTPCookieStorage()
            cfg.httpShouldSetCookies = true
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
        }
        self.config = config ?? OMLXConfig.load()
        if self.config.rejection != nil { state = .misconfigured }
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
        cancelStatsWork()
        overlayRefreshTask?.cancel()
        overlayRefreshTask = nil
    }

    /// Called by the status item when the popover opens or closes. Opening
    /// forces an immediate full refresh so the overlay is never stale on show;
    /// closing cancels the fan-out, since nothing on screen needs it.
    func setOverlayVisible(_ visible: Bool) {
        guard overlayVisible != visible else { return }
        overlayVisible = visible
        overlayRefreshTask?.cancel()
        guard visible else {
            cancelStatsWork()
            overlayRefreshTask = nil
            return
        }
        tick = 0
        overlayRefreshTask = Task { [weak self] in await self?.refreshAll() }
    }

    /// One complete pass, awaited to completion. The overlay uses it on open
    /// and `--selftest` uses it instead of guessing at a sleep duration.
    func refreshAll() async {
        await refreshActivity()
        // Models first: the per-model stats fan-out needs the list of IDs to
        // ask about.
        await refreshModels()
        await refreshGlobals()
        await refreshStats()
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
        // A refused target never gets a request. Settings are re-read each
        // tick so fixing the file recovers without a relaunch.
        if config.rejection != nil {
            reloadConfigIfSelfManaged()
            guard config.rejection != nil else { return }
            state = .misconfigured
            if !statsUnavailable { clearStats() }
            return
        }

        await refreshActivity()
        refreshStaleness()
        guard overlayVisible else { return }
        tick += 1
        // Handed to the coordinator rather than awaited: however long the
        // fan-out takes, the next activity tick is not waiting on it.
        if tick % Self.statsEveryNTicks == 0 { scheduleStatsRefresh() }
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
            lastSuccess = Date()
            isStale = false
        } catch {
            handle(error, endpoint: "/admin/api/activity")
        }
    }

    private func refreshStaleness() {
        guard !state.isUncertain else { return }
        guard let lastSuccess else { isStale = true; return }
        isStale = Date().timeIntervalSince(lastSuccess) > Self.staleAfter
    }

    // MARK: Stats

    /// One refresh's worth of numbers, assembled in full before any of it is
    /// published. Publishing field by field is what let the scope picker and
    /// the tiles disagree.
    private struct StatsSnapshot {
        var totals: StatsDTO
        var perModel: [String: StatsDTO]
    }

    /// Starts a stats refresh, superseding any that is still running.
    private func scheduleStatsRefresh() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in await self?.refreshStats() }
    }

    private func cancelStatsWork() {
        statsTask?.cancel()
        statsTask = nil
        // Invalidate whatever was in flight so it cannot publish later.
        statsGeneration &+= 1
    }

    private func refreshStats() async {
        statsGeneration &+= 1
        let generation = statsGeneration
        // Pinned once, for the aggregate *and* every per-model request. Reading
        // `self.scope` again inside the loop is what let one refresh mix
        // all-time totals with session per-model slices.
        let scope = self.scope
        let ids = modelIDsNeedingStats()

        guard let transport = makeTransport() else {
            handle(OMLXError.notConfigured(config.rejection ?? "No usable server target."),
                   endpoint: "/admin/api/stats")
            return
        }

        let snapshot = await withDeadline(Self.statsDeadline) { [weak self] in
            await self?.fetchStats(transport: transport, scope: scope, ids: ids)
        }

        // Three ways to lose the right to publish: superseded by a newer
        // refresh, cancelled, or the deadline expired. In all three the caller
        // keeps what it already had.
        guard generation == statsGeneration, !Task.isCancelled,
              let snapshot = snapshot ?? nil
        else { return }

        totals = snapshot.totals
        perModel = snapshot.perModel
        usingOfflineStats = false
        offlineStatsCapturedAt = nil
        statsUnavailable = false
    }

    private func fetchStats(
        transport: Transport, scope: StatsScope, ids: [String]
    ) async -> StatsSnapshot? {
        let totals: StatsDTO
        do {
            totals = try await get("/admin/api/stats?scope=\(scope.rawValue)")
        } catch {
            handle(error, endpoint: "/admin/api/stats")
            return nil
        }
        guard !Task.isCancelled else { return nil }

        let fetched = await Self.fetchPerModel(transport: transport, scope: scope, ids: ids)

        // Merged over what we already had, not substituted for it: a model
        // whose request timed out keeps its last known numbers instead of
        // vanishing from the list. Only models the server no longer reports
        // are dropped.
        var merged = perModel.filter { ids.contains($0.key) }
        for (id, dto) in fetched { merged[id] = dto }
        return StatsSnapshot(totals: totals, perModel: merged)
    }

    /// The per-model fan-out, capped at `maxConcurrentStatsRequests` in flight.
    ///
    /// `nonisolated` and driven off the Sendable `Transport` so the requests do
    /// not queue behind the main actor while the UI is drawing.
    private nonisolated static func fetchPerModel(
        transport: Transport, scope: StatsScope, ids: [String]
    ) async -> [String: StatsDTO] {
        func path(_ id: String) -> String? {
            guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            else { return nil }
            return "/admin/api/stats?model=\(encoded)&scope=\(scope.rawValue)"
        }

        var pending = ids.compactMap { id in path(id).map { (id, $0) } }.makeIterator()
        var results: [String: StatsDTO] = [:]

        await withTaskGroup(of: (String, StatsDTO?).self) { group in
            var started = 0
            while started < maxConcurrentStatsRequests, let (id, path) = pending.next() {
                group.addTask { (id, try? await transport.get(path) as StatsDTO) }
                started += 1
            }
            while let (id, dto) = await group.next() {
                if let dto { results[id] = dto }
                guard !Task.isCancelled, let (nextID, nextPath) = pending.next() else { continue }
                group.addTask { (nextID, try? await transport.get(nextPath) as StatsDTO) }
            }
        }
        return results
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

    private func handle(_ error: Error, endpoint: String) {
        // The server answered with something we cannot read. It is up, so
        // calling it offline would be a lie — but so would leaving the last
        // good dot on screen as though nothing had changed.
        if let error = error as? DecodingError {
            Diagnostics.log(endpoint: endpoint, "unreadable — \(Diagnostics.describe(error))")
            state = .incompatible
            isStale = true
            return
        }
        if case OMLXError.unreadable(let why) = error {
            Diagnostics.log(endpoint: endpoint, "unreadable — \(why)")
            state = .incompatible
            isStale = true
            return
        }
        if case OMLXError.notConfigured(let why) = error {
            Diagnostics.log(endpoint: endpoint, "not configured — \(why)")
            state = .misconfigured
            cancelStatsWork()
            clearStats()
            return
        }

        if case OMLXError.unauthorized = error {
            authFailed = true
        } else {
            authFailed = false
            if case OMLXError.http(let code) = error {
                Diagnostics.log(endpoint: endpoint, "HTTP \(code)")
            }
        }
        state = .offline
        isStale = true
        activity = ActiveModelsDTO()
        // Re-read settings.json — the server may have moved to a new port.
        reloadConfigIfSelfManaged()
        // Anything still in flight belongs to a server we have just declared
        // unreachable; it must not land on top of the offline numbers.
        cancelStatsWork()
        loadOfflineStats()
    }

    /// Picks up an edited `settings.json` — the server may have moved to a new
    /// port. Deliberately a no-op when the target was pinned by an environment
    /// override or handed in: silently retargeting somewhere else is how the
    /// numbers on screen stopped belonging to the server named above them.
    private func reloadConfigIfSelfManaged() {
        guard !configWasInjected, !config.isPinned else { return }
        let latest = OMLXConfig.load()
        if latest != config { config = latest }
    }

    /// Falls back to the server's own persisted all-time file so the overlay
    /// still has something true to show while oMLX is stopped.
    ///
    /// Only ever for a loopback target: `~/.omlx/stats.json` describes *this*
    /// machine, and captioning it with a remote server's name would invent
    /// history that server never had.
    private func loadOfflineStats() {
        guard config.isLoopback, let persisted = PersistedStats.load(from: statsPath) else {
            clearStats()
            return
        }
        totals = persisted.total
        perModel = persisted.perModel
        offlineStatsCapturedAt = persisted.capturedAt
        usingOfflineStats = true
        statsUnavailable = false
    }

    /// No server and no attributable history. Showing the last online numbers
    /// here is what made stale session totals look like recovered ones.
    private func clearStats() {
        totals = .empty
        perModel = [:]
        usingOfflineStats = false
        offlineStatsCapturedAt = nil
        statsUnavailable = true
    }

    // MARK: Transport

    /// An immutable, `Sendable` view of everything one request needs, so the
    /// fan-out can run off the main actor without touching client state.
    struct Transport: Sendable {
        let session: URLSession
        let baseURL: URL
        let apiKey: String?

        func get<T: Decodable>(_ path: String) async throws -> T {
            let (data, http) = try await send(path)
            guard (200..<300).contains(http.statusCode) else {
                throw http.statusCode == 401 || http.statusCode == 403
                    ? OMLXError.unauthorized
                    : OMLXError.http(http.statusCode)
            }
            // An HTML error page is a 200 with the wrong content type often
            // enough to be worth catching before the decoder turns it into a
            // confidently empty result. A server that sends no type at all is
            // given the benefit of the doubt; one that says "text/html" is not.
            if let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
               !type.contains("json") {
                throw OMLXError.unreadable("expected JSON, got \(type)")
            }
            return try OMLXJSON.decoder.decode(T.self, from: data)
        }

        func send(_ path: String, method: String = "GET", body: Data? = nil) async throws
            -> (Data, HTTPURLResponse) {
            guard let url = URL(string: path, relativeTo: baseURL) else {
                throw OMLXError.badURL
            }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let apiKey {
                // Harmless when the server skips verification; required by
                // sub-key setups. `OMLXConfig.validated()` has already refused
                // any target that would put this on the wire in clear.
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw OMLXError.badResponse }
            return (data, http)
        }
    }

    private func makeTransport() -> Transport? {
        guard let baseURL = config.baseURL else { return nil }
        return Transport(session: session, baseURL: baseURL, apiKey: config.apiKey)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let transport = makeTransport() else {
            throw OMLXError.notConfigured(config.rejection ?? "No usable server target.")
        }
        do {
            let value: T = try await transport.get(path)
            // Any accepted request means the current credentials work, so allow
            // a fresh login attempt if the session cookie later expires.
            didAttemptLogin = false
            return value
        } catch OMLXError.unauthorized {
            // One shot at exchanging the API key for a session cookie, then retry.
            guard !didAttemptLogin, try await login(transport) else { throw OMLXError.unauthorized }
            let value: T = try await transport.get(path)
            didAttemptLogin = false
            return value
        }
    }

    @discardableResult
    private func login(_ transport: Transport) async throws -> Bool {
        didAttemptLogin = true
        guard let key = transport.apiKey else { return false }
        let body = try JSONSerialization.data(withJSONObject: ["api_key": key, "remember": true])
        let (_, http) = try await transport.send("/admin/api/login", method: "POST", body: body)
        return (200..<300).contains(http.statusCode)
    }
}

enum OMLXError: Error {
    case badURL
    /// The configured target was refused; the string says why.
    case notConfigured(String)
    /// Not an HTTP response at all.
    case badResponse
    /// The server answered, but not with something we can read.
    case unreadable(String)
    case unauthorized
    case http(Int)
}
