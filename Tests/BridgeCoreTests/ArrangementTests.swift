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
    let half = msi.heightMM / 2
    #expect(Arrangement.place(1, at: -500, in: [lenovo, msi]) == -half)
    #expect(Arrangement.place(1, at: 900, in: [lenovo, msi]) == lenovo.heightMM - half)
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
