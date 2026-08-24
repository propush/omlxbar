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
        case .idleNoModel: return NSColor(srgbRed: 0.30, green: 0.79, blue: 0.44, alpha: 1)
        case .loadedIdle, .loading: return NSColor(srgbRed: 0.98, green: 0.76, blue: 0.20, alpha: 1)
        case .active: return NSColor(srgbRed: 0.94, green: 0.32, blue: 0.29, alpha: 1)
        }
    }

    /// Offline is drawn as an empty ring so it reads differently from the
    /// filled states even for a colour-blind viewer.
    var isFilled: Bool { self != .offline }

    /// Loading is the only state that animates.
    var pulses: Bool { self == .loading }

    var label: String {
        switch self {
        case .offline: return "Offline"
        case .idleNoModel: return "No model"
        case .loadedIdle: return "Idle"
        case .loading: return "Loading"
        case .active: return "Active"
        }
    }

    var accessibilityDescription: String { "oMLX — \(label)" }
}
