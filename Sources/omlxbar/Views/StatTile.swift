import SwiftUI

/// One of the dashboard's stat cards: uppercase caption above a large number.
struct StatTile: View {
    let label: String
    let value: String
    /// Cache Efficiency is the visual anchor of the row and is rendered larger.
    var emphasized: Bool = false
    var dimmed: Bool = false

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(label)
                .tileLabel()
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(value)
                .font(Theme.number(emphasized ? 27 : 19, weight: emphasized ? .bold : .semibold))
                .foregroundStyle(dimmed ? Theme.secondary : Theme.value)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, emphasized ? 14 : 12)
        .padding(.horizontal, 8)
        .card()
    }
}

/// Section header bar — glyph, uppercase title, optional trailing note.
struct SectionHeader: View {
    let systemImage: String
    let title: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text(title)
                .tileLabel(10)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.sectionBar)
    }
}
