import SwiftUI

/// The dashboard's "Average Speed" panel: prompt processing and token
/// generation side by side, split by a hairline.
struct SpeedSection: View {
    let prefillTps: Double
    let generationTps: Double
    var dimmed: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(systemImage: "gauge.with.dots.needle.50percent", title: "Average Speed")

            HStack(spacing: 0) {
                speed(
                    title: "Prompt Processing",
                    note: "(excl. cached)",
                    value: prefillTps
                )
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                speed(title: "Token Generation", note: nil, value: generationTps)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .background(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .fill(Theme.card)
        )
    }

    private func speed(title: String, note: String?, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondary)
                if let note {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.faint)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Fmt.tps(value))
                    .font(Theme.number(17, weight: .semibold))
                    .foregroundStyle(dimmed ? Theme.secondary : Theme.value)
                Text("tok/s")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
