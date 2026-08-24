import SwiftUI

/// Model memory in use against the enforcer ceiling, or against installed RAM
/// when the memory enforcer is disabled (which is what the dashboard shows as
/// "Enforcer disabled").
struct MemoryBar: View {
    let used: Int
    let max: Int
    let pressure: MemoryPressureDTO
    /// Installed RAM, used as the denominator when there is no ceiling.
    let deviceMemoryGB: Int
    /// The dashboard's "Enforcer disabled" note tracks the global
    /// memory.prefill_memory_guard flag, not memory_pressure.enabled — the
    /// latter is true even with no ceiling configured.
    let enforcerEnabled: Bool

    private var denominator: Int {
        if max > 0 { return max }
        if deviceMemoryGB > 0 { return deviceMemoryGB * 1_073_741_824 }
        return 0
    }

    private var fraction: Double {
        guard denominator > 0 else { return 0 }
        return Swift.min(1, Swift.max(0, Double(used) / Double(denominator)))
    }

    private var barColor: Color {
        switch pressure.pressureLevel {
        case "hard", "critical": return Theme.accentRed
        case "soft", "warn", "warning": return Theme.accentYellow
        default: return Theme.accentGreen
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Model Memory")
                    .tileLabel()
                Spacer(minLength: 8)
                if enforcerEnabled, denominator > 0, max > 0 {
                    Text("\(Fmt.bytes(used)) / \(Fmt.bytes(denominator))")
                        .font(Theme.number(11))
                        .foregroundStyle(Theme.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text(Fmt.bytes(used))
                            .font(Theme.number(11))
                            .foregroundStyle(Theme.secondary)
                        Text("Enforcer disabled")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.faint)
                    }
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule()
                        .fill(barColor)
                        .frame(width: Swift.max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .card()
    }
}
