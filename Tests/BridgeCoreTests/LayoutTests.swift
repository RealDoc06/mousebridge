import CoreGraphics
import Testing
@testable import BridgeCore

// The real desk: a 24.5" 1080p MSI left of a 27" 1440p Lenovo, bottom bezels level.
let lenovo = Display(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), widthMM: 602)
let msi = Display(frame: CGRect(x: -1920, y: 360, width: 1920, height: 1080), widthMM: 542, topMM: lenovo.heightMM - 1080 * 542 / 1920)
let desk = Layout(displays: [lenovo, msi])

/// Physical height of global row `y` above the desk (bottom bezel), in mm.
func mmAboveDesk(_ y: CGFloat, on d: Display) -> CGFloat { (d.frame.maxY - y) * d.mmPerPoint }

@Test func msiToLenovoKeepsPhysicalHeight() throws {
    let target = try #require(desk.remap(from: CGPoint(x: -2, y: 900), to: CGPoint(x: 0.5, y: 900), delta: CGVector(dx: 3, dy: 0)))
    #expect(target.x == Layout.landingInset)
    #expect(abs(mmAboveDesk(target.y, on: lenovo) - mmAboveDesk(900, on: msi)) < 0.5)
}

@Test func lenovoToMsiKeepsPhysicalHeight() throws {
    let target = try #require(desk.remap(from: CGPoint(x: 2, y: 1000), to: CGPoint(x: 0, y: 1000), delta: CGVector(dx: -3, dy: 0)))
    #expect(target.x == -1 - Layout.landingInset)
    #expect(abs(mmAboveDesk(target.y, on: msi) - mmAboveDesk(1000, on: lenovo)) < 0.5)
}

@Test func lenovoTopStripIsAWall() {
    // Above the MSI physically; macOS has no display left of rows 0..<360 either, so it clamps the cursor at x = 0.
    #expect(desk.remap(from: CGPoint(x: 1, y: 100), to: CGPoint(x: 0, y: 100), delta: CGVector(dx: -4, dy: 0)) == nil)
}

@Test func crossingMacOSMadePastTheWallClampsOntoTheNearestRow() {
    // The MSI raised 40 mm: the Lenovo's bottom rows are below it physically, though macOS has the MSI beside them.
    var raised = msi
    raised.topMM -= 40
    let layout = Layout(displays: [lenovo, raised])
    #expect(layout.remap(from: CGPoint(x: 2, y: 1400), to: CGPoint(x: -1, y: 1400), delta: CGVector(dx: -3, dy: 0)) == CGPoint(x: -1 - Layout.landingInset, y: 1439))
}

@Test func crossingFollowsArrangedTops() throws {
    // The MSI raised 40 mm off the desk: its bottom row now meets the Lenovo 40 mm above the bezel.
    var raised = msi
    raised.topMM -= 40
    let target = try #require(Layout(displays: [lenovo, raised])
        .remap(from: CGPoint(x: -2, y: 1439), to: CGPoint(x: 0.5, y: 1439), delta: CGVector(dx: 3, dy: 0)))
    #expect(abs(mmAboveDesk(target.y, on: lenovo) - 40) < 0.5)
}

@Test func crossingSkipsDisplayStackedBelowTheNeighbor() throws {
    // A laptop under the Lenovo, both starting at x = 0, spans the same physical heights as the Lenovo,
    // but has no rows beside the MSI, so the MSI's crossings still land on the Lenovo.
    let laptop = Display(frame: CGRect(x: 0, y: 1440, width: 1512, height: 982), widthMM: 302, topMM: 100)
    let target = try #require(Layout(displays: [laptop, lenovo, msi])
        .remap(from: CGPoint(x: -2, y: 900), to: CGPoint(x: 0.5, y: 900), delta: CGVector(dx: 3, dy: 0)))
    #expect(lenovo.frame.contains(target))
}

@Test func leavesOtherMovesAlone() {
    #expect(desk.remap(from: CGPoint(x: 1000, y: 500), to: CGPoint(x: 1004, y: 500), delta: CGVector(dx: 4, dy: 0)) == nil)
    #expect(desk.remap(from: CGPoint(x: 2558, y: 500), to: CGPoint(x: 2559.5, y: 500), delta: CGVector(dx: 4, dy: 0)) == nil)
}

@Test func staleStartAfterExternalWarpIsIgnored() {
    // Last seen on the MSI's right edge, then another app warped the cursor to the Lenovo's top-left.
    #expect(desk.remap(from: CGPoint(x: -2, y: 900), to: CGPoint(x: 5, y: 50), delta: CGVector(dx: 3, dy: 0)) == nil)
}

@Test func jitterAfterCrossingDoesNotBounceBack() throws {
    let landed = try #require(desk.remap(from: CGPoint(x: -2, y: 900), to: CGPoint(x: 0.5, y: 900), delta: CGVector(dx: 3, dy: 0)))
    let jitter = CGPoint(x: landed.x - 1, y: landed.y)
    #expect(desk.remap(from: landed, to: jitter, delta: CGVector(dx: -1, dy: 0)) == nil)
}

@Test func distanceToSharedEdgeOnlyCountsBorderingEdges() {
    #expect(desk.distanceToSharedEdge(CGPoint(x: 400, y: 500)) == 400)
    #expect(desk.distanceToSharedEdge(CGPoint(x: -300, y: 800)) == 300)
    #expect(desk.distanceToSharedEdge(CGPoint(x: -1900, y: 800)) == 1900) // MSI's left edge borders nothing
    #expect(Layout(displays: [lenovo]).distanceToSharedEdge(CGPoint(x: 5, y: 5)) == nil)
    #expect(desk.distanceToSharedEdge(CGPoint(x: 0, y: -400)) == 400) // above the edge, e.g. on a display stacked on top
}

@Test func crossingOntoAStackedDisplayIsLeftToMacOS() {
    // An iPad above the MSI also touches the Lenovo's left edge; macOS put the cursor on it, outside the row.
    #expect(desk.remap(from: CGPoint(x: 2, y: 100), to: CGPoint(x: -1, y: 100), delta: CGVector(dx: -3, dy: 0)) == nil)
}

/// The desk with an iPad 100 mm in from the Lenovo's left edge, below it or (macOS at y -1157) above it, though
/// macOS has it at x 1017.
private func stackedDesk(below: Bool = true) -> (layout: Layout, ipad: Display) {
    var m = msi, l = lenovo
    l.leftMM = m.widthMM
    let ipad = Display(
        frame: CGRect(x: 1017, y: below ? 1440 : -1157, width: 1543, height: 1157), widthMM: 265, leftMM: l.leftMM + 100
    )
    return (Layout(displays: [l, m], row: [m, l], stacked: [.init(ipad, below: below)]), ipad)
}

@Test func crossingDownLandsWhereTheStackedDisplayPhysicallyIs() throws {
    let (layout, ipad) = stackedDesk()
    // 30 mm in from the iPad's left edge, where macOS has no display below and clamps the cursor.
    let x = (100 + 30) / lenovo.mmPerPoint
    let target = try #require(layout.remap(from: CGPoint(x: x, y: 1438), to: CGPoint(x: x, y: 1439), delta: CGVector(dx: 0, dy: 2)))
    #expect(abs(target.x - (ipad.frame.minX + 30 / ipad.mmPerPoint)) < 0.01)
    #expect(target.y == ipad.frame.minY + Layout.landingInset)
}

@Test func crossingDownIsBlockedWhereNothingPhysicallyIs() {
    let (layout, _) = stackedDesk()
    // macOS crosses at x 2000, past the iPad's physical right edge: the cursor stays on the Lenovo.
    #expect(layout.remap(from: CGPoint(x: 2000, y: 1438), to: CGPoint(x: 2000, y: 1442), delta: CGVector(dx: 0, dy: 4)) == CGPoint(x: 2000, y: 1439))
    // Left of it, macOS clamps on its own.
    #expect(layout.remap(from: CGPoint(x: 300, y: 1438), to: CGPoint(x: 300, y: 1439), delta: CGVector(dx: 0, dy: 2)) == nil)
    // Away from the edge, nothing happens.
    #expect(layout.remap(from: CGPoint(x: 600, y: 700), to: CGPoint(x: 600, y: 704), delta: CGVector(dx: 0, dy: 4)) == nil)
}

@Test func crossingUpLandsOnTheRowDisplayInFront() throws {
    let (layout, ipad) = stackedDesk()
    let target = try #require(layout.remap(from: CGPoint(x: 1100, y: 1442), to: CGPoint(x: 1100, y: 1440), delta: CGVector(dx: 0, dy: -2)))
    let mm = 100 + (1100 - ipad.frame.minX) * ipad.mmPerPoint
    #expect(abs(target.x - mm / lenovo.mmPerPoint) < 0.01)
    #expect(target.y == lenovo.frame.maxY - 1 - Layout.landingInset)
}

@Test func distanceCountsTheEdgesTowardAStackedDisplay() {
    // Anywhere along the Lenovo's bottom, which the iPad is in front of; not the MSI's, which it isn't near.
    #expect(stackedDesk().layout.distanceToSharedEdge(CGPoint(x: 300, y: 1400)) == 40)
    #expect(stackedDesk().layout.distanceToSharedEdge(CGPoint(x: -1800, y: 1400))! > 1000)
}

@Test func crossingMacOSAlreadyMadeIsMovedToThePhysicalSpot() throws {
    let (layout, ipad) = stackedDesk()
    // macOS crossed at x 1100 (on its frame), physically 100 + 259 mm along the Lenovo, 259 - 100 into the iPad.
    let target = try #require(layout.remap(from: CGPoint(x: 1100, y: 1438), to: CGPoint(x: 1100, y: 1442), delta: CGVector(dx: 0, dy: 4)))
    #expect(abs(target.x - (ipad.frame.minX + (1100 * lenovo.mmPerPoint - 100) / ipad.mmPerPoint)) < 0.01)
}

@Test func crossingUpIsBlockedPastTheRowsEnd() {
    // The iPad placed from 1000 mm along the desk, hanging past the Lenovo's right end at 1144 mm.
    var m = msi, l = lenovo
    l.leftMM = m.widthMM
    let ipad = Display(frame: CGRect(x: 1017, y: 1440, width: 1543, height: 1157), widthMM: 265, leftMM: 1000)
    let layout = Layout(displays: [l, m], row: [m, l], stacked: [.init(ipad, below: true)])
    // 200 mm into the iPad is 1200 mm along the desk, past the Lenovo; macOS had moved the cursor onto the Lenovo.
    let x = 1017 + 200 / ipad.mmPerPoint
    #expect(layout.remap(from: CGPoint(x: x, y: 1442), to: CGPoint(x: x, y: 1438), delta: CGVector(dx: 0, dy: -4)) == CGPoint(x: x, y: 1440))
}

@Test func crossingWorksTheSameWithTheStackedDisplayAbove() throws {
    let (layout, ipad) = stackedDesk(below: false)
    let x = (100 + 30) / lenovo.mmPerPoint
    let up = try #require(layout.remap(from: CGPoint(x: x, y: 2), to: CGPoint(x: x, y: 0), delta: CGVector(dx: 0, dy: -2)))
    #expect(abs(up.x - (ipad.frame.minX + 30 / ipad.mmPerPoint)) < 0.01 && up.y == ipad.frame.maxY - 1 - Layout.landingInset)
    let down = try #require(layout.remap(from: CGPoint(x: up.x, y: -3), to: CGPoint(x: up.x, y: -1), delta: CGVector(dx: 0, dy: 2)))
    #expect(abs(down.x - x) < 0.01 && down.y == Layout.landingInset)
}

@Test func stackedDisplayUnderTheSeamCrossesBackToEitherSide() throws {
    // The iPad physically under the seam: 400...665 mm along the desk, the MSI ending at 542 mm.
    var m = msi, l = lenovo
    l.leftMM = m.widthMM
    let ipad = Display(frame: CGRect(x: -773, y: 1440, width: 1543, height: 1157), widthMM: 265, leftMM: 400)
    let layout = Layout(displays: [l, m], row: [m, l], stacked: [.init(ipad, below: true)])
    let up = { (mm: CGFloat) in
        let x = ipad.frame.minX + (mm - 400) / ipad.mmPerPoint
        return layout.remap(from: CGPoint(x: x, y: 1442), to: CGPoint(x: x, y: 1440), delta: CGVector(dx: 0, dy: -2))
    }
    #expect(try #require(up(450)).x < 0) // onto the MSI
    #expect(try #require(up(600)).x >= 0) // onto the Lenovo
}

@Test func crossingPrefersTheStackedDisplayMacOSEntered() throws {
    // A laptop and an iPad below the Lenovo whose desk spans overlap; macOS put the cursor on the iPad.
    var l = lenovo
    l.leftMM = msi.widthMM
    let laptop = Display(frame: CGRect(x: 0, y: 1440, width: 1000, height: 600), widthMM: 300, leftMM: l.leftMM)
    let ipad = Display(frame: CGRect(x: 1100, y: 1440, width: 1543, height: 1157), widthMM: 265, leftMM: l.leftMM + 200)
    let layout = Layout(displays: [l, msi], row: [msi, l], stacked: [.init(laptop, below: true), .init(ipad, below: true)])
    let x = 250 / lenovo.mmPerPoint // macOS moved it to x 1101, 259 mm along the Lenovo: in front of both
    let target = try #require(layout.remap(from: CGPoint(x: x, y: 1438), to: CGPoint(x: 1101, y: 1442), delta: CGVector(dx: 0, dy: 4)))
    #expect(ipad.frame.contains(target))
}
