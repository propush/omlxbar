import Foundation

enum Fmt {
    /// Thousands grouped with a thin space — "2 910 564" — matching the oMLX
    /// dashboard's rendering of token counts.
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = "\u{2009}"
        f.groupingSize = 3
        f.maximumFractionDigits = 0
        return f
    }()

    static func int(_ value: Int) -> String {
        grouped.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Compact form for narrow columns: 2.9M, 41.7K.
    static func compactInt(_ value: Int) -> String {
        switch abs(value) {
        case 1_000_000_000...:
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...:
            return String(format: "%.0fK", Double(value) / 1_000)
        default:
            return int(value)
        }
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    /// "838.8 tok/s" — the numeric part only; views append the unit so they can
    /// style it at a lighter weight.
    static func tps(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// Sampling parameter: trims the trailing zeroes off 0.70 / 1.00.
    static func param(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%g", value)
    }

    static func bytes(_ value: Int) -> String {
        guard value > 0 else { return "0 GB" }
        let gb = Double(value) / 1_073_741_824
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(value) / 1_048_576)
    }

    /// Short duration: "42s", "7m 12s", "2h 04m", "3d 5h".
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        if total < 86400 { return "\(total / 3600)h \(String(format: "%02d", (total % 3600) / 60))m" }
        return "\(total / 86400)d \((total % 86400) / 3600)h"
    }
}
