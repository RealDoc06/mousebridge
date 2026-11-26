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

@Test func lenovoTopStripCrossesOntoMsiTopRow() throws {
    // macOS has no display left of rows 0..<360, so it clamps the cursor at x = 0.
    let target = try #require(desk.remap(from: CGPoint(x: 1, y: 100), to: CGPoint(x: 0, y: 100), delta: CGVector(dx: -4, dy: 0)))
    #expect(target == CGPoint(x: -1 - Layout.landingInset, y: 360))
}

@Test func crossingFollowsArrangedTops() throws {
    // The MSI raised 40 mm off the desk: its bottom row now meets the Lenovo 40 mm above the bezel.
    var raised = msi
    raised.topMM -= 40
    let target = try #require(Layout(displays: [lenovo, raised])
        .remap(from: CGPoint(x: -2, y: 1439), to: CGPoint(x: 0.5, y: 1439), delta: CGVector(dx: 3, dy: 0)))
    #expect(abs(mmAboveDesk(target.y, on: lenovo) - 40) < 0.5)
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
