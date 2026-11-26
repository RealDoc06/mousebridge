import SwiftUI

/// The menu's look: a dark window with titled sections over grouped cards.
enum Theme {
    static let window = Color(white: 0.145)
    static let card = Color(white: 0.176)
    static let stroke = Color.white.opacity(0.06)
    static let track = Color(white: 0.26)
    static let padding: CGFloat = 12
    static let cardPadding: CGFloat = 10
    static let cardRadius: CGFloat = 10
    /// Concentric with the cards: their radius plus the window padding.
    static let windowRadius = cardRadius + padding
}

/// A section of the menu: a bold header row (title plus any icon buttons) over a card holding the content.
struct Panel<Header: View, Content: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) { header }
                .font(.system(size: 14, weight: .bold))
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .frame(height: 20)
                .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(Theme.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.stroke) }
        }
    }
}

/// A card row with a label and a 0...1 level drawn as a meter, set by clicking or dragging along it.
struct LevelRow: View {
    let label: String
    let value: Double
    let set: @MainActor (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 72, alignment: .leading)
            Meter(value: value, set: set)
            Text(value, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityRepresentation { Slider(value: Binding(get: { value }, set: set)) { Text(label) } }
    }
}

private struct Meter: View {
    let value: Double
    let set: @MainActor (Double) -> Void

    private static let endReach: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Color.accentColor).frame(width: max(6, geo.size.width * value))
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            // The last few points at each end count as the end, so 0% and 100% are easy to hit.
            .gesture(DragGesture(minimumDistance: 0).onChanged {
                set(min(max(($0.location.x - Self.endReach) / (geo.size.width - 2 * Self.endReach), 0), 1))
            })
        }
        .frame(height: 16)
    }
}

/// A card row with a label and a switch at the trailing edge.
struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { Text(label).frame(maxWidth: .infinity, alignment: .leading) }
            .toggleStyle(.switch)
            .controlSize(.mini)
    }
}

/// A small label in a filled rounded box, for a fact about a card such as how brightness is set.
struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 4, style: .continuous))
    }
}
