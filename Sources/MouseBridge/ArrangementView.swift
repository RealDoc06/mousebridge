import BridgeCore
import SwiftUI

/// The displays at real scale, side by side as on the desk. Dragging one up or down sets where it physically
/// sits, which the cursor bridge maps crossings by. Dragging it past a neighbor reorders macOS's arrangement.
/// With guides on, edges that line up get a yellow line and drags snap to them.
struct ArrangementView: View {
    let desk: Desk
    /// Label for each display, by display ID.
    let names: [CGDirectDisplayID: String]
    let width: CGFloat

    @State private var drag: Drag?

    private struct Drag: Equatable {
        let id: CGDirectDisplayID
        var offset: CGSize
    }

    /// Snap reach in points on screen, so it feels the same at any scale.
    private static let snapPoints: CGFloat = 6

    var body: some View {
        let scale = width / desk.screens.map(\.display.widthMM).reduce(0, +)
        let (displays, order) = arranged(scale: scale)
        let home = lefts(Array(displays.indices)), slots = lefts(order)
        // The canvas is framed around the saved arrangement, so it holds still while a display is dragged.
        let saved = desk.screens.map(\.display)
        let top = saved.map(\.topMM).min() ?? 0
        let bottom = saved.map { $0.topMM + $0.heightMM }.max() ?? 0
        let heightMM = max((saved.map(\.heightMM).max() ?? 0) * 1.5, bottom - top)
        let originMM = (top + bottom - heightMM) / 2

        ZStack(alignment: .topLeading) {
            ForEach(Array(desk.screens.enumerated()), id: \.element.id) { i, screen in
                let d = displays[i]
                let dragged = drag?.id == screen.id
                // The dragged display follows the pointer; the others slide into the order it makes.
                let x = dragged ? home[i] + (drag?.offset.width ?? 0) / scale : slots[i]
                tile(d, name: names[screen.id] ?? "Display", dragged: dragged)
                    .frame(width: d.widthMM * scale, height: d.heightMM * scale)
                    .offset(x: min(max(x * scale, 0), width - d.widthMM * scale), y: (d.topMM - originMM) * scale)
                    .animation(dragged ? nil : .snappy(duration: 0.2), value: order)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { drag = Drag(id: screen.id, offset: $0.translation) }
                            .onEnded { _ in commit(scale: scale) }
                    )
            }
            if desk.guides {
                ForEach(Arrangement.guides(displays), id: \.self) { mm in
                    Rectangle().fill(.yellow)
                        .frame(width: width, height: 1)
                        .offset(y: (mm - originMM) * scale - 0.5)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: width, height: heightMM * scale, alignment: .topLeading)
    }

    private func tile(_ d: Display, name: String, dragged: Bool) -> some View {
        let inches = Double(hypot(d.widthMM, d.heightMM) / 25.4)
        return RoundedRectangle(cornerRadius: 4)
            .fill(dragged ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.12))
            .strokeBorder(Color.primary.opacity(dragged ? 0.6 : 0.25))
            .overlay {
                VStack(spacing: 1) {
                    Text(name).font(.caption.weight(.medium))
                    Text("\(inches.formatted(.number.precision(.fractionLength(0...1))))\"")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(4)
            }
            .padding(1) // a hairline gap between neighbors
            .contentShape(Rectangle())
    }

    /// The displays with the dragged one moved, and the left-to-right order (indices into `desk.screens`)
    /// its horizontal position gives.
    private func arranged(scale: CGFloat) -> (displays: [Display], order: [Int]) {
        var displays = desk.screens.map(\.display)
        let identity = Array(displays.indices)
        guard let drag, let i = desk.screens.firstIndex(where: { $0.id == drag.id }) else { return (displays, identity) }
        displays[i].topMM = Arrangement.place(
            i, at: displays[i].topMM + drag.offset.height / scale, in: displays,
            snapMM: desk.guides ? Self.snapPoints / scale : nil
        )
        guard desk.canReorder else { return (displays, identity) }
        let home = lefts(identity)
        let center = { (j: Int) in home[j] + displays[j].widthMM / 2 + (j == i ? drag.offset.width / scale : 0) }
        return (displays, identity.sorted { center($0) < center($1) })
    }

    /// Left edge (mm) of each display when laid out in `order`, indexed like `desk.screens`.
    private func lefts(_ order: [Int]) -> [CGFloat] {
        var lefts = [CGFloat](repeating: 0, count: order.count)
        var x: CGFloat = 0
        for j in order {
            lefts[j] = x
            x += desk.screens[j].display.widthMM
        }
        return lefts
    }

    private func commit(scale: CGFloat) {
        guard let id = drag?.id, let i = desk.screens.firstIndex(where: { $0.id == id }) else { return }
        let (displays, order) = arranged(scale: scale)
        withAnimation(.snappy(duration: 0.2)) {
            desk.setTop(displays[i].topMM, of: id)
            if order != Array(displays.indices) { desk.reorder(order.map { desk.screens[$0].id }) }
            drag = nil
        }
    }
}
