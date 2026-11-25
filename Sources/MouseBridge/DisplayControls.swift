import CoreGraphics
import Foundation

/// HDR switching through SkyLight's private API, the call behind System Settings' HDR toggle.
enum HDR {
    private typealias Query = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias Set = @convention(c) (CGDirectDisplayID, Bool, Int32, Int32) -> CGError
    nonisolated(unsafe) private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let supports = dlsym(skyLight, "SLSDisplaySupportsHDRMode").map { unsafeBitCast($0, to: Query.self) }
    private static let enabled = dlsym(skyLight, "SLSDisplayIsHDRModeEnabled").map { unsafeBitCast($0, to: Query.self) }
    private static let set = dlsym(skyLight, "SLSDisplaySetHDRModeEnabled").map { unsafeBitCast($0, to: Set.self) }

    static func isSupported(_ id: CGDirectDisplayID) -> Bool { set != nil && supports?(id) == true }
    static func isEnabled(_ id: CGDirectDisplayID) -> Bool { enabled?(id) == true }
    static func setEnabled(_ id: CGDirectDisplayID, _ on: Bool) { _ = set?(id, on, 0, 0) }
}

/// Software dimming for displays without DDC: scales the gamma ramp's maximum.
enum Gamma {
    static func dim(_ id: CGDirectDisplayID, to level: Double) {
        let max = Float(level)
        CGSetDisplayTransferByFormula(id, 0, max, 1, 0, max, 1, 0, max, 1)
    }

    /// Puts every display back on its ColorSync profile. Called on quit.
    static func restore() { CGDisplayRestoreColorSyncSettings() }
}
