import Foundation

/// Where the oMLX server lives and how to authenticate with it, read from
/// `~/.omlx/settings.json` (the same file the server itself loads).
///
/// A target is only usable once it has been validated: cleartext HTTP is
/// permitted for loopback and nowhere else, because every request carries the
/// admin API key. A refused target is *not* quietly replaced with loopback —
/// `rejection` is set, `baseURL` stays nil, and the overlay reports why.
struct OMLXConfig: Equatable {
    var scheme: String
    var host: String
    var port: Int
    var apiKey: String?
    /// Why this target was refused, or nil when it is usable.
    var rejection: String?
    /// True when an environment override chose this target. A pinned target is
    /// never re-derived from `settings.json` behind the user's back — that is
    /// how an explicit remote host used to become loopback on the first
    /// connection failure.
    var isPinned = false

    static let fallback = OMLXConfig(scheme: "http", host: "127.0.0.1", port: 8000, apiKey: nil)

    /// The server binds 127.0.0.1 even when settings say otherwise for a remote
    /// alias, so a wildcard host is normalised to loopback.
    var resolvedHost: String {
        (host.isEmpty || host == "0.0.0.0") ? "127.0.0.1" : host
    }

    var isLoopback: Bool { Self.isLoopback(resolvedHost) }

    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if h == "::1" || h == "0:0:0:0:0:0:0:1" { return true }
        // The whole 127.0.0.0/8 block, not just the canonical address.
        return h.hasPrefix("127.")
    }

    /// nil when the target was refused. Callers surface `rejection` rather than
    /// falling back to some other host.
    var baseURL: URL? {
        guard rejection == nil else { return nil }
        return URL(string: "\(scheme)://\(bracketedHost):\(port)")
    }

    var dashboardURL: URL? { baseURL?.appendingPathComponent("admin") }

    /// A literal IPv6 address needs brackets before it can go in a URL.
    private var bracketedHost: String {
        let h = resolvedHost
        guard h.contains(":"), !h.hasPrefix("[") else { return h }
        return "[\(h)]"
    }

    /// Human-readable target, for banners and the self-test.
    var displayTarget: String { "\(scheme)://\(resolvedHost):\(port)" }

    static var settingsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omlx/settings.json")
    }

    static var statsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omlx/stats.json")
    }

    // MARK: Validation

    /// Refuses anything that would put the API key on the wire in clear, or
    /// that is not addressable at all. Returns a config with `rejection` set
    /// rather than throwing, so the app can explain itself instead of dying.
    func validated() -> OMLXConfig {
        // A rejection recorded while loading (an unparseable OMLXBAR_URL) is
        // already the most specific explanation there is — keep it.
        guard rejection == nil else { return self }
        var config = self

        let host = config.resolvedHost
        guard !host.isEmpty else {
            config.rejection = "No host configured."
            return config
        }
        guard (1...65535).contains(config.port) else {
            config.rejection = "Port \(config.port) is not a valid TCP port."
            return config
        }
        guard config.scheme == "http" || config.scheme == "https" else {
            config.rejection = "Unsupported scheme \"\(config.scheme)\" — use http or https."
            return config
        }
        // The one rule that matters: every request carries the admin API key,
        // so cleartext is only ever acceptable when it cannot leave the machine.
        if config.scheme == "http", !Self.isLoopback(host) {
            config.rejection =
                "Refusing to send the API key in clear to \(host). Use https:// for a remote oMLX instance."
            return config
        }
        guard URL(string: "\(config.scheme)://\(config.bracketedHost):\(config.port)") != nil else {
            config.rejection = "\"\(host)\" is not a usable host name."
            return config
        }
        return config
    }

    // MARK: Loading

    /// Environment overrides, for pointing the app at an oMLX instance that is
    /// not the one described by the local settings file.
    static func applyEnvironmentOverrides(
        to config: OMLXConfig, environment env: [String: String]
    ) -> OMLXConfig {
        var config = config

        // A full URL is the unambiguous form: it carries the scheme, so a
        // remote target says out loud whether it is encrypted.
        if let raw = env["OMLXBAR_URL"], !raw.isEmpty {
            if let parsed = parse(url: raw) {
                config.scheme = parsed.scheme
                config.host = parsed.host
                config.port = parsed.port
                config.isPinned = true
            } else {
                config.isPinned = true
                config.rejection = "OMLXBAR_URL=\"\(raw)\" is not a valid http(s) URL."
                return config
            }
        }

        if let host = env["OMLXBAR_HOST"], !host.isEmpty {
            config.host = host
            config.isPinned = true
            // A bare host override carries no scheme. Loopback keeps plain
            // HTTP; anything else is upgraded rather than refused, since the
            // caller cannot have meant to leak the key.
            if env["OMLXBAR_URL"] == nil {
                config.scheme = isLoopback(host) ? "http" : "https"
            }
        }
        if let port = env["OMLXBAR_PORT"].flatMap(Int.init) {
            config.port = port
            config.isPinned = true
        }
        if let key = env["OMLXBAR_API_KEY"], !key.isEmpty { config.apiKey = key }
        return config
    }

    private static func parse(url raw: String) -> (scheme: String, host: String, port: Int)? {
        guard
            let components = URLComponents(string: raw),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        return (scheme, host, components.port ?? (scheme == "https" ? 443 : 80))
    }

    static func load() -> OMLXConfig {
        let root = (try? Data(contentsOf: settingsPath))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return resolve(settings: root, environment: ProcessInfo.processInfo.environment)
    }

    /// The whole resolution pipeline with both inputs handed in, so the rules
    /// can be exercised without a settings file or a mutated process
    /// environment.
    static func resolve(
        settings root: [String: Any]?, environment: [String: String]
    ) -> OMLXConfig {
        guard let root else {
            return applyEnvironmentOverrides(to: .fallback, environment: environment).validated()
        }
        let server = root["server"] as? [String: Any] ?? [:]
        let auth = root["auth"] as? [String: Any] ?? [:]

        // settings.json describes the server's own bind address, which the
        // server reaches over loopback; the scheme only becomes interesting
        // once an override points somewhere else.
        return applyEnvironmentOverrides(
            to: OMLXConfig(
                scheme: OMLXConfig.fallback.scheme,
                host: server["host"] as? String ?? OMLXConfig.fallback.host,
                port: server["port"] as? Int ?? OMLXConfig.fallback.port,
                apiKey: (auth["api_key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ),
            environment: environment
        ).validated()
    }
}

/// All-time totals as persisted by the server to `~/.omlx/stats.json`.
///
/// Read directly from disk so the overlay can still show history when the
/// server is stopped. Mirrors `ServerMetrics._build_snapshot`
/// (omlx/server_metrics.py:225) so the numbers match the dashboard exactly.
///
/// Only ever meaningful for a loopback target: the file belongs to *this*
/// machine, and presenting it as a remote server's history would be a lie.
enum PersistedStats {
    struct Snapshot {
        var total: StatsDTO
        var perModel: [String: StatsDTO]
        /// When the server last wrote the file. It persists periodically, so
        /// these numbers can be minutes behind even when they are genuine.
        var capturedAt: Date?
    }

    struct Raw {
        var promptTokens = 0
        var completionTokens = 0
        var cachedTokens = 0
        var requests = 0
        var prefillDuration = 0.0
        var generationDuration = 0.0

        init(_ dict: [String: Any], prefix: String) {
            promptTokens = dict["\(prefix)prompt_tokens"] as? Int ?? 0
            completionTokens = dict["\(prefix)completion_tokens"] as? Int ?? 0
            cachedTokens = dict["\(prefix)cached_tokens"] as? Int ?? 0
            requests = dict["\(prefix)requests"] as? Int ?? 0
            prefillDuration = dict["\(prefix)prefill_duration"] as? Double ?? 0
            generationDuration = dict["\(prefix)generation_duration"] as? Double ?? 0
        }

        var snapshot: StatsDTO {
            var s = StatsDTO()
            s.totalPromptTokens = promptTokens
            s.totalCompletionTokens = completionTokens
            s.totalCachedTokens = cachedTokens
            s.totalRequests = requests
            s.totalTokensServed = promptTokens + completionTokens
            // Prefill throughput counts only tokens the model actually had to
            // process — cache hits are excluded, matching the dashboard's
            // "Prompt Processing (excl. cached)".
            let processed = promptTokens - cachedTokens
            s.avgPrefillTps = prefillDuration > 0 ? (Double(processed) / prefillDuration).rounded(to: 1) : 0
            s.avgGenerationTps = generationDuration > 0 ? (Double(completionTokens) / generationDuration).rounded(to: 1) : 0
            s.cacheEfficiency = promptTokens > 0 ? (Double(cachedTokens) / Double(promptTokens) * 100).rounded(to: 1) : 0
            return s
        }
    }

    /// Returns the all-time aggregate plus per-model breakdown, or nil if the
    /// file is missing or unreadable.
    static func load(from path: URL = OMLXConfig.statsPath) -> Snapshot? {
        guard
            let data = try? Data(contentsOf: path),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let total = Raw(root, prefix: "total_").snapshot
        var perModel: [String: StatsDTO] = [:]
        if let models = root["per_model"] as? [String: Any] {
            for (id, value) in models {
                guard let dict = value as? [String: Any] else { continue }
                perModel[id] = Raw(dict, prefix: "").snapshot
            }
        }
        let capturedAt = (try? path.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return Snapshot(total: total, perModel: perModel, capturedAt: capturedAt)
    }
}

extension Double {
    func rounded(to places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
