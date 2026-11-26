import CoreGraphics
import Testing
@testable import BridgeCore

// Index 1 is the MSI on the bottom-aligned desk from LayoutTests.

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

@Test func guidesProjectOtherEdgesOntoEachDisplay() {
    // Centered MSI: the Lenovo shows the MSI's top, center and bottom rows; the MSI only the Lenovo's center.
    var centered = msi
    centered.topMM = (lenovo.heightMM - msi.heightMM) / 2
    let onLenovo = Arrangement.guides(on: 0, in: [lenovo, centered]).map(\.row)
    #expect(onLenovo.count == 3)
    #expect(abs(onLenovo[1] - 720) < 0.001)
    #expect(abs(onLenovo[0] - centered.topMM / lenovo.mmPerPoint) < 0.001)
    #expect(Arrangement.guides(on: 1, in: [lenovo, centered]).map { ($0.row * 1000).rounded() / 1000 } == [540])
    #expect(Arrangement.guides(on: 1, in: [lenovo, centered]).map(\.source) == [0])
    // Bottom-aligned: the shared bottom shows on both, at each display's last row.
    #expect(Arrangement.guides(on: 1, in: [lenovo, msi]).last.map { abs($0.row - 1080) < 0.001 } == true)
}

@Test func wideDisplaySwapsBeforeTheRowEnds() {
    // A 27" (602 mm) left of a 14" laptop (302 mm): the 27" fits at left 0...302 and swaps past 151.
    #expect(Arrangement.order(widths: [602, 302], dragging: 0, toLeft: 150) == [0, 1])
    #expect(Arrangement.order(widths: [602, 302], dragging: 0, toLeft: 152) == [1, 0])
    // The laptop, starting at 602, swaps once its left edge passes the 27"'s midpoint.
    #expect(Arrangement.order(widths: [602, 302], dragging: 1, toLeft: 302) == [0, 1])
    #expect(Arrangement.order(widths: [602, 302], dragging: 1, toLeft: 300) == [1, 0])
}

@Test func tallDisplayCoversAShortOneAnyWay() throws {
    // A 32" (708 x 398 mm) beside a 14" laptop panel (302 x 196 mm) top-aligned at 0.
    let laptop = Display(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), widthMM: 302)
    let big = Display(frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), widthMM: 708)
    let bottomAligned = laptop.heightMM - big.heightMM
    #expect(abs(Arrangement.place(1, at: bottomAligned, in: [laptop, big]) - bottomAligned) < 0.001)
    #expect(Arrangement.place(1, at: 0, in: [laptop, big]) == 0)
    // The canvas bounds hold either display at its furthest reach.
    let bounds = Arrangement.bounds([laptop, big])
    let reach = try #require(Arrangement.reach(1, in: [laptop, big]))
    #expect(bounds.contains(reach.lowerBound) && bounds.contains(reach.upperBound + big.heightMM))
}

@Test func dragNeverPullsADisplayBackIntoReach() {
    // The MSI left 200 mm below the Lenovo (say, by an older arrangement) stays put on a sideways-only drag.
    var low = msi
    low.topMM = 200
    #expect(Arrangement.place(1, at: 200, in: [lenovo, low]) == 200)
}

@Test func stackedDisplayTouchesItsHost() {
    // An iPad (1543 x 1157 pt) placed 1236 pt into the Lenovo, below and above it.
    let size = CGSize(width: 1543, height: 1157)
    #expect(Arrangement.origin(stacking: size, leftMM: 1236 * lenovo.mmPerPoint, below: true, on: lenovo) == CGPoint(x: 1236, y: 1440))
    #expect(Arrangement.origin(stacking: size, leftMM: 0, below: false, on: lenovo) == CGPoint(x: 0, y: -1157))
}

@Test func stackedDisplayLandsOnTheMostOverlapped() {
    let row: [(left: CGFloat, width: CGFloat)] = [(0, 542), (542, 602)]
    #expect(Arrangement.host(left: 420, width: 265, in: row) == 1)
    #expect(Arrangement.host(left: 300, width: 265, in: row) == 0)
    // In points, an iPad below both shares more columns with the Lenovo; one beside the row touches neither.
    let frames = [msi.frame, CGRect(x: 0, y: 360, width: 2560, height: 1080)]
    #expect(Arrangement.host(of: CGRect(x: -500, y: 1440, width: 1543, height: 1157), among: frames) == 1)
    #expect(Arrangement.host(of: CGRect(x: 2560, y: 360, width: 1543, height: 1157), among: frames) == nil)
}

@Test func stackedDropStaysClearOfTheTallerNeighbor() {
    // An iPad dropped above the MSI straddling the seam would cover the Lenovo's top strip: it slides left to clear it.
    let size = CGSize(width: 1543, height: 1157)
    let origin = Arrangement.origin(stacking: size, leftMM: 400, below: false, on: msi, clearOf: [lenovo.frame])
    #expect(origin == CGPoint(x: -1543, y: 360 - 1157))
    // Dropped past the host's end with nothing in the way, it still keeps a column on the host.
    #expect(Arrangement.origin(stacking: size, leftMM: 900, below: true, on: msi)?.x == -1)
}

@Test func stackedDropThatFitsNowhereIsRefused() {
    // A 1543 pt iPad above a 1280 pt display whose taller neighbors both reach into those rows.
    let host = Display(frame: CGRect(x: 0, y: 360, width: 1280, height: 720), widthMM: 300)
    let neighbors = [CGRect(x: -1000, y: 0, width: 1000, height: 1080), CGRect(x: 1280, y: 0, width: 1000, height: 1080)]
    let size = CGSize(width: 1543, height: 1157)
    #expect(Arrangement.origin(stacking: size, leftMM: 0, below: false, on: host, clearOf: neighbors) == nil)
}

@Test func stackedGuidesMarkTheOtherDisplaysPhysicalEdges() {
    // A 265 mm iPad 100 mm in from the Lenovo's left edge along the desk, wherever macOS has it.
    var desk = lenovo
    desk.leftMM = 542
    let ipad = Display(frame: CGRect(x: 1017, y: 1440, width: 1543, height: 1157), widthMM: 265, leftMM: 642)
    let onLenovo = Arrangement.columns(on: desk, of: ipad)
    #expect(onLenovo.count == 3 && abs(onLenovo[0] - 100 / lenovo.mmPerPoint) < 0.001)
    // On the iPad, only the Lenovo's center (301 mm in) falls on it, 201 mm in from the iPad's left edge.
    #expect(Arrangement.columns(on: ipad, of: desk).map { ($0 * ipad.mmPerPoint).rounded() } == [201])
}

@Test func rowMapDrawsEachColumnAtItsDisplaysScale() {
    // The MSI from 0 mm, the Lenovo from 542 mm. An iPad at x -773...770 covers 773 pt of the MSI and 770 of the Lenovo.
    let map = RowMap([(msi, 0), (lenovo, msi.widthMM)])
    #expect(abs(map.mm(-773) - (msi.widthMM - 773 * msi.mmPerPoint)) < 0.001)
    #expect(abs(map.mm(770) - (msi.widthMM + 770 * lenovo.mmPerPoint)) < 0.001)
    #expect(abs(map.mm(0) - msi.widthMM) < 0.001)
    #expect(abs(map.x(map.mm(-773)) + 773) < 0.001)
    #expect(abs(map.x(map.mm(3000)) - 3000) < 0.001) // past the end, at the Lenovo's scale
}

@Test func defaultSpotKeepsTheOverlapMacOSHas() {
    // An iPad (1543 pt, 265 mm) hanging off the Lenovo's left edge, sharing 243 pt (57 mm at the Lenovo's scale):
    // at the Lenovo's scale alone it would sit entirely left of it.
    let left = Arrangement.defaultLeft(of: CGRect(x: -1300, y: 1440, width: 1543, height: 1157), widthMM: 265, on: lenovo)
    #expect(abs(left + 265 - 243 * lenovo.mmPerPoint) < 0.001)
    // Under it, it's simply where macOS has it at the Lenovo's scale.
    let under = Arrangement.defaultLeft(of: CGRect(x: 1017, y: 1440, width: 1543, height: 1157), widthMM: 265, on: lenovo)
    #expect(abs(under - 1017 * lenovo.mmPerPoint) < 0.001)
}
