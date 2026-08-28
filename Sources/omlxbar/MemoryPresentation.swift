import Foundation

enum MemoryDisplayMode: Equatable {
    case guarded
    case unguarded
}

enum MemoryBarLevel: Equatable {
    case green
    case yellow
    case amber
    case orange
    case red

    init(fraction: Double) {
        switch fraction {
        case 0.90...: self = .red
        case 0.80...: self = .orange
        case 0.70...: self = .amber
        case 0.60...: self = .yellow
        default: self = .green
        }
    }
}

/// Resolves oMLX's two memory-reporting regimes into one coherent display.
/// The guard constrains whole-process memory; without it, the legacy card shows
/// resident model memory against installed RAM.
struct MemoryPresentation {
    private static let bytesPerGiB = 1_073_741_824

    let mode: MemoryDisplayMode
    let title: String
    let usedBytes: Int
    let softBytes: Int
    let hardBytes: Int
    let barLimitBytes: Int
    let fraction: Double
    let softMarkerFraction: Double
    let statusText: String?
    let barLevel: MemoryBarLevel

    init(activity: ActiveModelsDTO, deviceMemoryGB: Int, guardEnabled: Bool?) {
        let pressure = activity.memoryPressure
        let hasLiveGuard = pressure.enabled && pressure.hardBytes > 0

        if guardEnabled ?? hasLiveGuard {
            let processBytes = max(0, pressure.currentBytes)
            mode = .guarded
            title = "Process Memory"
            usedBytes = processBytes > 0 ? processBytes : max(0, activity.modelMemoryUsed)
            softBytes = max(0, pressure.softBytes)
            hardBytes = max(0, pressure.hardBytes)
            barLimitBytes = hardBytes
            statusText = hardBytes > 0 ? nil : "Guard limit unavailable"
        } else {
            mode = .unguarded
            title = "Model Memory"
            usedBytes = max(0, activity.modelMemoryUsed)
            softBytes = 0
            hardBytes = 0
            barLimitBytes = Self.installedMemoryBytes(deviceMemoryGB)
            statusText = "Enforcer disabled"
        }

        fraction = Self.fraction(value: usedBytes, limit: barLimitBytes)
        softMarkerFraction = mode == .guarded
            ? Self.fraction(value: softBytes, limit: hardBytes)
            : 0
        barLevel = MemoryBarLevel(fraction: fraction)
    }

    var valueText: String {
        guard mode == .guarded, hardBytes > 0 else { return Fmt.bytes(usedBytes) }
        return "\(Fmt.pressureBytes(usedBytes)) / \(Fmt.pressureBytes(softBytes)) soft / "
            + "\(Fmt.pressureBytes(hardBytes)) hard"
    }

    var diagnosticSummary: String {
        switch mode {
        case .guarded where hardBytes > 0:
            return "process memory \(valueText)"
        case .guarded:
            return "process memory \(Fmt.bytes(usedBytes)) used, guard limit unavailable"
        case .unguarded:
            return "model memory \(Fmt.bytes(usedBytes)) used, ceiling none (enforcer disabled)"
        }
    }

    private static func installedMemoryBytes(_ gigabytes: Int) -> Int {
        guard gigabytes > 0 else { return 0 }
        let (bytes, overflow) = gigabytes.multipliedReportingOverflow(by: bytesPerGiB)
        return overflow ? Int.max : bytes
    }

    private static func fraction(value: Int, limit: Int) -> Double {
        guard value > 0, limit > 0 else { return 0 }
        return min(1, Double(value) / Double(limit))
    }
}
