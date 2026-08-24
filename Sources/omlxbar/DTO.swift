import Foundation

// Codable mirrors of the oMLX admin API (omlx/admin/routes.py). The server's
// snake_case is folded to camelCase by .convertFromSnakeCase on the decoder.
//
// Every field is decoded leniently: Swift's synthesized Decodable throws on a
// missing key rather than falling back to the property's default value, and we
// would rather render a partial overlay than nothing at all when a future oMLX
// release renames or drops a field.

extension KeyedDecodingContainer {
    /// Decoded value, or `fallback` if the key is absent, null, or the wrong type.
    func get<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        // `try?` flattens the optional, so a missing key, a null, and a type
        // mismatch all arrive here as nil.
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    /// Decoded value, or nil if the key is absent, null, or the wrong type.
    func opt<T: Decodable>(_ key: Key) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }
}

/// The decoder every oMLX response is parsed with.
enum OMLXJSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

// MARK: - /admin/api/stats

struct StatsDTO: Decodable {
    var totalTokensServed = 0
    var totalCachedTokens = 0
    var cacheEfficiency = 0.0
    var totalPromptTokens = 0
    var totalCompletionTokens = 0
    var totalRequests = 0
    var avgPrefillTps = 0.0
    var avgGenerationTps = 0.0
    var uptimeSeconds = 0.0
    var activeModels: ActiveModelsDTO?

    init() {}

    enum CodingKeys: String, CodingKey {
        case totalTokensServed, totalCachedTokens, cacheEfficiency
        case totalPromptTokens, totalCompletionTokens, totalRequests
        case avgPrefillTps, avgGenerationTps, uptimeSeconds, activeModels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalTokensServed = c.get(.totalTokensServed, 0)
        totalCachedTokens = c.get(.totalCachedTokens, 0)
        cacheEfficiency = c.get(.cacheEfficiency, 0)
        totalPromptTokens = c.get(.totalPromptTokens, 0)
        totalCompletionTokens = c.get(.totalCompletionTokens, 0)
        totalRequests = c.get(.totalRequests, 0)
        avgPrefillTps = c.get(.avgPrefillTps, 0)
        avgGenerationTps = c.get(.avgGenerationTps, 0)
        uptimeSeconds = c.get(.uptimeSeconds, 0)
        activeModels = c.opt(.activeModels)
    }

    static let empty = StatsDTO()

    var isEmpty: Bool { totalRequests == 0 && totalTokensServed == 0 }
}

// MARK: - /admin/api/activity

struct ActivityDTO: Decodable {
    var activeModels = ActiveModelsDTO()

    enum CodingKeys: String, CodingKey { case activeModels }

    init(activeModels: ActiveModelsDTO = ActiveModelsDTO()) {
        self.activeModels = activeModels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Deliberately *not* lenient. The whole menubar dot is derived from
        // this envelope, so an absent or renamed `active_models` must surface
        // as a decoding failure. Defaulting it to empty would paint a green
        // "no model" dot for a server we can no longer read — the one outcome
        // worse than admitting we do not know.
        activeModels = try c.decode(ActiveModelsDTO.self, forKey: .activeModels)
    }
}

struct ActiveModelsDTO: Decodable {
    var models: [ActiveModelDTO] = []
    var modelMemoryUsed = 0
    var modelMemoryMax = 0
    var memoryPressure = MemoryPressureDTO()
    var totalActiveRequests = 0
    var totalWaitingRequests = 0

    init() {}

    enum CodingKeys: String, CodingKey {
        case models, modelMemoryUsed, modelMemoryMax
        case memoryPressure, totalActiveRequests, totalWaitingRequests
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = c.get(.models, [])
        modelMemoryUsed = c.get(.modelMemoryUsed, 0)
        modelMemoryMax = c.get(.modelMemoryMax, 0)
        memoryPressure = c.get(.memoryPressure, MemoryPressureDTO())
        totalActiveRequests = c.get(.totalActiveRequests, 0)
        totalWaitingRequests = c.get(.totalWaitingRequests, 0)
    }
}

struct MemoryPressureDTO: Decodable {
    var enabled = false
    var currentBytes = 0
    var softBytes = 0
    var hardBytes = 0
    var currentFormatted = "0.0GB"
    var pressureLevel = "ok"

    init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, currentBytes, softBytes, hardBytes, currentFormatted, pressureLevel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.get(.enabled, false)
        currentBytes = c.get(.currentBytes, 0)
        softBytes = c.get(.softBytes, 0)
        hardBytes = c.get(.hardBytes, 0)
        currentFormatted = c.get(.currentFormatted, "0.0GB")
        pressureLevel = c.get(.pressureLevel, "ok")
    }
}

struct ActiveModelDTO: Decodable, Identifiable {
    var id = ""
    var estimatedSize = 0
    var estimatedSizeFormatted = ""
    var actualSize = 0
    var actualSizeFormatted: String?
    var pinned = false
    var isLoading = false
    var loadingElapsedSeconds: Double?
    var loadingRemainingSecondsEstimate: Double?
    var activeRequests = 0
    var waitingRequests = 0
    var generating: [GeneratingDTO] = []
    var prefilling: [PrefillingDTO] = []
    var idleSeconds: Double?
    var ttlRemainingSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case id, estimatedSize, estimatedSizeFormatted, actualSize, actualSizeFormatted
        case pinned, isLoading, loadingElapsedSeconds, loadingRemainingSecondsEstimate
        case activeRequests, waitingRequests, generating, prefilling
        case idleSeconds, ttlRemainingSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.get(.id, "")
        estimatedSize = c.get(.estimatedSize, 0)
        estimatedSizeFormatted = c.get(.estimatedSizeFormatted, "")
        actualSize = c.get(.actualSize, 0)
        actualSizeFormatted = c.opt(.actualSizeFormatted)
        pinned = c.get(.pinned, false)
        isLoading = c.get(.isLoading, false)
        loadingElapsedSeconds = c.opt(.loadingElapsedSeconds)
        loadingRemainingSecondsEstimate = c.opt(.loadingRemainingSecondsEstimate)
        activeRequests = c.get(.activeRequests, 0)
        waitingRequests = c.get(.waitingRequests, 0)
        generating = c.get(.generating, [])
        prefilling = c.get(.prefilling, [])
        idleSeconds = c.opt(.idleSeconds)
        ttlRemainingSeconds = c.opt(.ttlRemainingSeconds)
    }

    /// Size actually resident once loaded, falling back to the pre-load estimate.
    var sizeFormatted: String {
        if let actual = actualSizeFormatted, !actual.isEmpty { return actual }
        return estimatedSizeFormatted
    }

    /// Live generation rate across every in-flight request on this model.
    var liveTokensPerSecond: Double {
        generating.reduce(0) { $0 + $1.tokensPerSecond }
    }
}

struct GeneratingDTO: Decodable, Identifiable {
    var requestId = ""
    var elapsedSeconds: Double?
    var generatedTokens = 0
    var tokensPerSecond = 0.0
    var promptTokens = 0
    var maxTokens: Int?

    var id: String { requestId }

    enum CodingKeys: String, CodingKey {
        case requestId, elapsedSeconds, generatedTokens, tokensPerSecond, promptTokens, maxTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = c.get(.requestId, "")
        elapsedSeconds = c.opt(.elapsedSeconds)
        generatedTokens = c.get(.generatedTokens, 0)
        tokensPerSecond = c.get(.tokensPerSecond, 0)
        promptTokens = c.get(.promptTokens, 0)
        maxTokens = c.opt(.maxTokens)
    }
}

struct PrefillingDTO: Decodable, Identifiable {
    var requestId = ""
    var processed = 0
    var total = 0
    var speed = 0.0
    var eta: Double?
    var elapsed = 0.0
    var phase = "prefill"

    var id: String { requestId }

    /// 0…1, or nil when the total is unknown.
    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(processed) / Double(total)))
    }

    enum CodingKeys: String, CodingKey {
        case requestId, processed, total, speed, eta, elapsed, phase
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = c.get(.requestId, "")
        processed = c.get(.processed, 0)
        total = c.get(.total, 0)
        speed = c.get(.speed, 0)
        eta = c.opt(.eta)
        elapsed = c.get(.elapsed, 0)
        phase = c.get(.phase, "prefill")
    }
}

// MARK: - /admin/api/models

struct ModelsResponseDTO: Decodable {
    var models: [ModelInfoDTO] = []

    enum CodingKeys: String, CodingKey { case models }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = c.get(.models, [])
    }
}

struct ModelInfoDTO: Decodable, Identifiable {
    var id = ""
    var displayName = ""
    var loaded = false
    var isLoading = false
    var estimatedSizeFormatted = ""
    var actualSizeFormatted: String?
    var pinned = false
    var isDefault = false
    var isHidden = false
    var engineType = ""
    var configModelType: String?
    var modelContextLength: Int?
    var settings: ModelSettingsDTO?

    enum CodingKeys: String, CodingKey {
        case id, displayName, loaded, isLoading, estimatedSizeFormatted, actualSizeFormatted
        case pinned, isDefault, isHidden, engineType, configModelType
        case modelContextLength, settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.get(.id, "")
        displayName = c.get(.displayName, "")
        loaded = c.get(.loaded, false)
        isLoading = c.get(.isLoading, false)
        estimatedSizeFormatted = c.get(.estimatedSizeFormatted, "")
        actualSizeFormatted = c.opt(.actualSizeFormatted)
        pinned = c.get(.pinned, false)
        isDefault = c.get(.isDefault, false)
        isHidden = c.get(.isHidden, false)
        engineType = c.get(.engineType, "")
        configModelType = c.opt(.configModelType)
        modelContextLength = c.opt(.modelContextLength)
        settings = c.opt(.settings)
    }

    var sizeFormatted: String {
        if let actual = actualSizeFormatted, !actual.isEmpty { return actual }
        return estimatedSizeFormatted
    }

    /// The alias users type in API calls, when one is configured.
    var alias: String? {
        guard let alias = settings?.modelAlias, !alias.isEmpty, alias != id else { return nil }
        return alias
    }

}

/// Only the per-model parameters the overlay surfaces. The server sends ~80
/// fields in this object; the rest are deliberately ignored.
struct ModelSettingsDTO: Decodable {
    var modelAlias: String?
    var ttlSeconds: Int?
    var maxContextWindow: Int?
    var maxTokens: Int?
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var minP: Double?
    var repetitionPenalty: Double?
    var enableThinking: Bool?

    enum CodingKeys: String, CodingKey {
        case modelAlias, ttlSeconds, maxContextWindow, maxTokens
        case temperature, topP, topK, minP, repetitionPenalty, enableThinking
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelAlias = c.opt(.modelAlias)
        ttlSeconds = c.opt(.ttlSeconds)
        maxContextWindow = c.opt(.maxContextWindow)
        maxTokens = c.opt(.maxTokens)
        temperature = c.opt(.temperature)
        topP = c.opt(.topP)
        topK = c.opt(.topK)
        minP = c.opt(.minP)
        repetitionPenalty = c.opt(.repetitionPenalty)
        enableThinking = c.opt(.enableThinking)
    }
}

// MARK: - /admin/api/device-info

struct DeviceInfoDTO: Decodable {
    var chipName = ""
    var chipVariant: String?
    var memoryGb = 0
    var gpuCores = 0

    init() {}

    enum CodingKeys: String, CodingKey { case chipName, chipVariant, memoryGb, gpuCores }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chipName = c.get(.chipName, "")
        chipVariant = c.opt(.chipVariant)
        memoryGb = c.get(.memoryGb, 0)
        gpuCores = c.get(.gpuCores, 0)
    }

    /// "M4 Max · 48 GB · 40 GPU"
    var summary: String {
        var parts: [String] = []
        let chip = [chipName, chipVariant ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        if !chip.isEmpty { parts.append(chip) }
        if memoryGb > 0 { parts.append("\(memoryGb) GB") }
        if gpuCores > 0 { parts.append("\(gpuCores) GPU") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - /admin/api/global-settings

/// The slices of the server's global settings the overlay needs to resolve what
/// a model's parameters actually are at request time.
struct GlobalSettingsDTO: Decodable {
    var sampling: SamplingSettingsDTO?
    var memory: MemorySettingsDTO?

    init() {}

    enum CodingKeys: String, CodingKey { case sampling, memory }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sampling = c.opt(.sampling)
        memory = c.opt(.memory)
    }
}

struct SamplingSettingsDTO: Decodable {
    var maxContextWindow: Int?
    /// When set, every model's native context is clamped to
    /// min(native, policy) — see server.get_max_context_window.
    var maxContextWindowPolicy: Int?
    var maxTokens: Int?
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var repetitionPenalty: Double?

    enum CodingKeys: String, CodingKey {
        case maxContextWindow, maxContextWindowPolicy, maxTokens
        case temperature, topP, topK, repetitionPenalty
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxContextWindow = c.opt(.maxContextWindow)
        maxContextWindowPolicy = c.opt(.maxContextWindowPolicy)
        maxTokens = c.opt(.maxTokens)
        temperature = c.opt(.temperature)
        topP = c.opt(.topP)
        topK = c.opt(.topK)
        repetitionPenalty = c.opt(.repetitionPenalty)
    }
}

struct MemorySettingsDTO: Decodable {
    /// The dashboard's "Enforcer disabled" note tracks this flag.
    var prefillMemoryGuard: Bool?
    var memoryGuardTier: String?

    enum CodingKeys: String, CodingKey { case prefillMemoryGuard, memoryGuardTier }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prefillMemoryGuard = c.opt(.prefillMemoryGuard)
        memoryGuardTier = c.opt(.memoryGuardTier)
    }
}
