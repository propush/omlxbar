import Foundation

/// Where the oMLX server lives and how to authenticate with it, read from
/// `~/.omlx/settings.json` (the same file the server itself loads).
struct OMLXConfig: Equatable {
    var host: String
    var port: Int
    var apiKey: String?

    static let fallback = OMLXConfig(host: "127.0.0.1", port: 8000, apiKey: nil)

    /// The server binds 127.0.0.1 even when settings say otherwise for a remote
    /// alias, so a wildcard host is normalised to loopback.
    var baseURL: URL {
        let resolved = (host.isEmpty || host == "0.0.0.0") ? "127.0.0.1" : host
        return URL(string: "http://\(resolved):\(port)") ?? URL(string: "http://127.0.0.1:8000")!
    }

    var dashboardURL: URL { baseURL.appendingPathComponent("admin") }

    static var settingsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omlx/settings.json")
    }

    static var statsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omlx/stats.json")
    }

    /// Environment overrides, for pointing the app at an oMLX instance that is
    /// not the one described by the local settings file.
    private static func applyEnvironmentOverrides(to config: OMLXConfig) -> OMLXConfig {
        var config = config
        let env = ProcessInfo.processInfo.environment
        if let host = env["OMLXBAR_HOST"], !host.isEmpty { config.host = host }
        if let port = env["OMLXBAR_PORT"].flatMap(Int.init) { config.port = port }
        if let key = env["OMLXBAR_API_KEY"], !key.isEmpty { config.apiKey = key }
        return config
    }

    static func load() -> OMLXConfig {
        guard
            let data = try? Data(contentsOf: settingsPath),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return applyEnvironmentOverrides(to: .fallback) }

        let server = root["server"] as? [String: Any] ?? [:]
        let auth = root["auth"] as? [String: Any] ?? [:]

        return applyEnvironmentOverrides(
            to: OMLXConfig(
                host: server["host"] as? String ?? OMLXConfig.fallback.host,
                port: server["port"] as? Int ?? OMLXConfig.fallback.port,
                apiKey: (auth["api_key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        )
    }
}

/// All-time totals as persisted by the server to `~/.omlx/stats.json`.
///
/// Read directly from disk so the overlay can still show history when the
/// server is stopped. Mirrors `ServerMetrics._build_snapshot`
/// (omlx/server_metrics.py:225) so the numbers match the dashboard exactly.
enum PersistedStats {
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
    static func load() -> (total: StatsDTO, perModel: [String: StatsDTO])? {
        guard
            let data = try? Data(contentsOf: OMLXConfig.statsPath),
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
        return (total, perModel)
    }
}

extension Double {
    func rounded(to places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
