import SwiftUI

/// Colours and type carried over from the oMLX web dashboard so the overlay
/// reads as the same product in a smaller frame.
enum Theme {
    static let ground = Color(red: 0.055, green: 0.055, blue: 0.055)   // #0E0E0E
    static let card = Color(red: 0.082, green: 0.082, blue: 0.082)     // #151515
    static let sectionBar = Color(red: 0.118, green: 0.118, blue: 0.118) // #1E1E1E
    static let hairline = Color.white.opacity(0.08)

    static let label = Color.white.opacity(0.45)
    static let secondary = Color.white.opacity(0.55)
    static let value = Color.white
    static let faint = Color.white.opacity(0.30)

    static let accentGreen = Color(red: 0.30, green: 0.79, blue: 0.44)
    static let accentYellow = Color(red: 0.98, green: 0.76, blue: 0.20)
    static let accentAmber = Color(red: 0.96, green: 0.62, blue: 0.04)
    static let accentRed = Color(red: 0.94, green: 0.32, blue: 0.29)
    /// Reserved for "we cannot vouch for what is on screen" — never for a
    /// fact about the server's workload.
    static let accentOrange = Color(red: 0.96, green: 0.55, blue: 0.16)

    static let corner: CGFloat = 12
    static let overlayWidth: CGFloat = 380

    /// Uppercase, tracked-out tile and section labels.
    static func caption(_ size: CGFloat = 9.5) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
}

extension Color {
    static func forState(_ state: ServerState) -> Color {
        switch state {
        case .offline: return Color(white: 0.55)
        case .incompatible, .misconfigured: return Theme.accentOrange
        case .idleNoModel: return Theme.accentGreen
        case .loadedIdle, .loading: return Theme.accentYellow
        case .active: return Theme.accentRed
        }
    }
}

/// The dashboard's rounded card: darker fill, one-pixel hairline border.
struct CardBackground: ViewModifier {
    var fill: Color = Theme.card

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func card(fill: Color = Theme.card) -> some View {
        modifier(CardBackground(fill: fill))
    }

    /// Uppercase tracked label, as used for every stat caption in the dashboard.
    func tileLabel(_ size: CGFloat = 9.5) -> some View {
        font(Theme.caption(size))
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(Theme.label)
    }
}
