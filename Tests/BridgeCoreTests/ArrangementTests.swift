import CoreGraphics
import Testing
@testable import BridgeCore

// Index 1 is the MSI on the bottom-aligned desk from LayoutTests.
let bottomTop = msi.topMM

@Test func dragSnapsToNearestEdgeWithinReach() {
    // 3 mm short of top-aligned snaps to top-aligned; without snapping it stays put.
    #expect(Arrangement.place(1, at: 3, in: [lenovo, msi], snapMM: 5) == 0)
    #expect(Arrangement.place(1, at: 3, in: [lenovo, msi]) == 3)
    // 4 mm short of centered snaps to centered.
    let centered = (lenovo.heightMM - msi.heightMM) / 2
    #expect(abs(Arrangement.place(1, at: centered - 4, in: [lenovo, msi], snapMM: 5) - centered) < 0.001)
    // Nothing within reach: no snap.
    #expect(Arrangement.place(1, at: 8, in: [lenovo, msi], snapMM: 5) == 8)
}

@Test func dragStaysBesideTheOthers() {
    let reach = msi.heightMM * Arrangement.overhang
    #expect(Arrangement.place(1, at: -500, in: [lenovo, msi]) == -reach)
    #expect(abs(Arrangement.place(1, at: 900, in: [lenovo, msi]) - (lenovo.heightMM + reach - msi.heightMM)) < 0.001)
    #expect(Arrangement.place(0, at: 42, in: [lenovo]) == 42)
}

@Test func guidesMarkAlignedEdges() {
    #expect(Arrangement.guides([lenovo, msi]) == [lenovo.heightMM])
    var centered = msi
    centered.topMM = (lenovo.heightMM - msi.heightMM) / 2
    #expect(Arrangement.guides([lenovo, centered]) == [lenovo.heightMM / 2])
    var loose = msi
    loose.topMM = bottomTop - 10
    #expect(Arrangement.guides([lenovo, loose]).isEmpty)
}

@Test func wideDisplaySwapsBeforeTheRowEnds() {
    // A 27" (602 mm) left of a 14" laptop (302 mm): the 27" fits at left 0...302 and swaps past 151.
    #expect(Arrangement.order(widths: [602, 302], dragging: 0, toLeft: 150) == [0, 1])
    #expect(Arrangement.order(widths: [602, 302], dragging: 0, toLeft: 152) == [1, 0])
    // The laptop, starting at 602, swaps once its left edge passes the 27"'s midpoint.
    #expect(Arrangement.order(widths: [602, 302], dragging: 1, toLeft: 302) == [0, 1])
    #expect(Arrangement.order(widths: [602, 302], dragging: 1, toLeft: 300) == [1, 0])
}
