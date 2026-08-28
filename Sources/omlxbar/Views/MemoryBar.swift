import SwiftUI

/// Whole-process usage against the guard's soft and hard watermarks, or model memory
/// against installed RAM when enforcement is disabled.
struct MemoryBar: View {
    let presentation: MemoryPresentation

    private var barColor: Color {
        switch presentation.barLevel {
        case .green: return Theme.accentGreen
        case .yellow: return Theme.accentYellow
        case .amber: return Theme.accentAmber
        case .orange: return Theme.accentOrange
        case .red: return Theme.accentRed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(presentation.title)
                    .tileLabel()
                Spacer(minLength: 8)
                if let statusText = presentation.statusText {
                    HStack(spacing: 6) {
                        Text(Fmt.bytes(presentation.usedBytes))
                            .font(Theme.number(11))
                            .foregroundStyle(Theme.secondary)
                        Text(statusText)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.faint)
                    }
                } else {
                    Text(presentation.valueText)
                        .font(Theme.number(11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            GeometryReader { geo in
                let markerX = Swift.min(
                    Swift.max(0, geo.size.width - 1),
                    geo.size.width * presentation.softMarkerFraction
                )
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    if presentation.fraction > 0 {
                        Capsule()
                            .fill(barColor)
                            .frame(width: Swift.max(2, geo.size.width * presentation.fraction))
                    }
                    if presentation.softMarkerFraction > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.32))
                            .frame(width: 1)
                            .offset(x: markerX)
                    }
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .card()
    }
}
