import Foundation
import Testing
@testable import BridgeCore

/// The MSI G255F's EDID: base block and one CTA-861 extension, no ContainerID.
private let msiEDID: [UInt8] = {
    let hex = "00ffffffffffff003669c03b000000002423010380361f78ef2cf1a7564e9f240e50543fcf0081809500b30001010101010101010101023a801871382d40582c45001f2e2100001e000000fd0030b41edc1e000a202020202020000000fc004d53492047323535460a202020000000ff004243304d3330353930373932360132020326f14a01020304901112049f3f2309070783010000e200c7e305030067030c00000038420000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b9"
    return stride(from: 0, to: hex.count, by: 2).map { i in
        UInt8(hex[hex.index(hex.startIndex, offsetBy: i)...].prefix(2), radix: 16)!
    }
}()

@Test func containerIDRoundTripsThroughAnAppendedDisplayIDBlock() throws {
    #expect(EDID.containerID(in: msiEDID) == nil)
    let id = EDID.ownContainerID(for: msiEDID)
    let patched = try #require(EDID.addingContainerID(id, to: msiEDID))

    #expect(patched.count == 384 && patched[126] == 2)
    #expect(EDID.containerID(in: patched) == id)
    // Each 128-byte block still sums to 0, and the display keeps its ID once patched.
    for block in stride(from: 0, to: patched.count, by: 128) {
        #expect(patched[block..<block + 128].reduce(0) { ($0 + Int($1)) % 256 } == 0)
    }
    #expect(EDID.ownContainerID(for: patched) == id)
}
