import AppKit

/// What the menubar dot is reporting.
enum ServerState: Equatable {
    /// The server is not answering — stopped, restarting, or unreachable.
    case offline
    /// The server is up but holds no model in memory.
    case idleNoModel
    /// A model is resident in memory but no request is in flight.
    case loadedIdle
    /// At least one model is loading its weights.
    case loading
    /// At least one request is prefilling or generating right now.
    case active
    /// The server answered, but not with anything we could parse. It is up and
    /// we have no idea what it is doing — which is not the same as idle.
    case incompatible
    /// The configured target was refused before any request was sent.
    case misconfigured

    /// Derived from `/admin/api/activity`.
    static func from(_ activity: ActiveModelsDTO) -> ServerState {
        if activity.totalActiveRequests > 0 { return .active }
        if activity.models.contains(where: { $0.isLoading }) { return .loading }
        if activity.models.isEmpty { return .idleNoModel }
        return .loadedIdle
    }

    var color: NSColor {
        switch self {
        case .offline: return NSColor(calibratedWhite: 0.55, alpha: 1)
        case .incompatible, .misconfigured:
            return NSColor(srgbRed: 0.96, green: 0.55, blue: 0.16, alpha: 1)
        case .idleNoModel: return NSColor(srgbRed: 0.30, green: 0.79, blue: 0.44, alpha: 1)
        case .loadedIdle, .loading: return NSColor(srgbRed: 0.98, green: 0.76, blue: 0.20, alpha: 1)
        case .active: return NSColor(srgbRed: 0.94, green: 0.32, blue: 0.29, alpha: 1)
        }
    }

    /// The three "we cannot vouch for this" states are drawn as an empty ring
    /// so they read differently from the filled states even for a colour-blind
    /// viewer. None of them may ever look like a healthy green dot.
    var isFilled: Bool { !isUncertain }

    /// True when the dot is reporting a problem with the connection rather
    /// than a fact about the server's workload.
    var isUncertain: Bool {
        self == .offline || self == .incompatible || self == .misconfigured
    }

    /// Loading is the only state that animates.
    var pulses: Bool { self == .loading }

    var label: String {
        switch self {
        case .offline: return "Offline"
        case .idleNoModel: return "No model"
        case .loadedIdle: return "Idle"
        case .loading: return "Loading"
        case .active: return "Active"
        case .incompatible: return "Unreadable"
        case .misconfigured: return "Not configured"
        }
    }

    var accessibilityDescription: String { "oMLX — \(label)" }
}
