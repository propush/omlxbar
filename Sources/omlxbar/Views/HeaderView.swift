import SwiftUI

/// Top of the overlay: the state pill, whichever model is actually working, and
/// the machine it is running on.
struct HeaderView: View {
    let state: ServerState
    let activeModelNames: [String]
    let device: DeviceInfoDTO
    let uptime: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                statePill

                if let subject {
                    Text(subject)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)
            }

            HStack(spacing: 5) {
                if !device.summary.isEmpty {
                    Text(device.summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.faint)
                }
                if !state.isUncertain, uptime > 0 {
                    if !device.summary.isEmpty {
                        Text("·").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                    }
                    Text("up \(Fmt.duration(uptime))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The model worth naming next to the state: the busy one, or the only
    /// loaded one. With several loaded and none busy, the count reads better.
    private var subject: String? {
        switch activeModelNames.count {
        case 0: return nil
        case 1: return activeModelNames[0]
        default: return "\(activeModelNames.count) models loaded"
        }
    }

    private var statePill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.forState(state))
                .frame(width: 7, height: 7)
            Text(state.label)
                .font(Theme.caption(9.5))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(Color.forState(state))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.forState(state).opacity(0.13))
        )
    }
}
