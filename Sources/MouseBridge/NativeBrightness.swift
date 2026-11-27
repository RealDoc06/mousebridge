import BridgeCore
import CoreGraphics
import Foundation
import IOKit.hid
import OSLog

/// Gives DDC displays macOS's own brightness controls (the Display slider in Control Center and System Settings)
/// the way Apple's displays get them: a USB HID brightness device that shares the display's ContainerID. Each
/// display gets a `BrightnessDevice` and, unless its EDID already carries MouseBridge's ContainerID, a virtual EDID
/// that adds it (see `EDID`). macOS drops a virtual EDID when the display reconnects (it survives display sleep),
/// so `link` runs on every reload and patches again; that blanks the display for a moment.
@MainActor
final class NativeBrightness {
    /// Live devices by ContainerID. Kept across reloads, so macOS keeps its link to each display.
    private var devices: [UUID: BrightnessDevice] = [:]
    /// When each display waiting for its ContainerID was patched, so a display change in the meantime doesn't blank
    /// it again. Seeing the ContainerID, a refused patch or the display going away clears it, and it expires after
    /// `patchTimeout` (a replug inside the reload debounce drops the patch unseen). A display that never shows the
    /// ContainerID is patched again on display changes after that.
    private var patched: [UUID: ContinuousClock.Instant] = [:]
    private static let patchTimeout = Duration.seconds(10)
    private let log = Logger(subsystem: "it.realdoc06.mousebridge", category: "brightness")

    /// A display that answers DDC, as probed.
    struct Display: Sendable {
        let id: CGDirectDisplayID
        let ddc: DDC
        /// What macOS reads as its EDID, the virtual one once patched.
        let edid: [UInt8]
        let level: Double
    }

    /// Sets up each display's device and patches its EDID, and returns the devices of displays macOS has linked
    /// (their EDID carries the ContainerID). `onSet` gets macOS's changes as the display (as of the latest `link`)
    /// and the level (0...1), from the moment macOS links it.
    func link(_ displays: [Display], onSet: @escaping (CGDirectDisplayID, Double) -> Void) -> [CGDirectDisplayID: BrightnessDevice] {
        var linked: [CGDirectDisplayID: BrightnessDevice] = [:]
        var live: [UUID: BrightnessDevice] = [:]
        let owns = displays.map { EDID.ownContainerID(for: $0.edid) }
        for (display, own) in zip(displays, owns) {
            let current = EDID.containerID(in: display.edid)
            // A display with its own ContainerID (an Apple display) already has its brightness device. Displays with
            // byte-identical EDIDs would share one device, so they stay on DDC alone.
            guard current == nil || current == own, owns.count(where: { $0 == own }) == 1 else { continue }
            guard let device = devices[own] ?? BrightnessDevice(containerID: own, level: display.level, onSet: onSet) else {
                log.error("no brightness device: is com.apple.developer.hid.virtual.device in the provisioning profile?")
                continue
            }
            live[own] = device
            device.display = display.id // A reconnect can give the display another ID.
            if current != nil {
                linked[display.id] = device
                patched[own] = nil
            } else if patched[own].map({ .now - $0 > Self.patchTimeout }) ?? true, let edid = EDID.addingContainerID(own, to: display.edid) {
                patched[own] = .now
                Task.detached { [weak self, log] in
                    guard !display.ddc.setVirtualEDID(edid) else { return }
                    log.error("virtual EDID refused for \(own)")
                    await MainActor.run { self?.patched[own] = nil }
                }
            }
        }
        devices = live
        patched = patched.filter { live[$0.key] != nil }
        return linked
    }
}

/// A virtual USB Monitor Control device with one brightness control, like the one in Apple's displays. macOS reads
/// the level from it and writes the user's changes to it. Needs the com.apple.developer.hid.virtual.device
/// entitlement, without which `init` fails.
@MainActor
final class BrightnessDevice {
    /// The display it's linked to.
    var display: CGDirectDisplayID = kCGNullDirectDisplay
    /// True once macOS's slider has been given the display's level, or while that waits for macOS (see `Monitors`).
    var seeded = false
    /// The level macOS reads back (0...1, linear in luminance): the last it set, or the display's when created.
    private(set) var level: Double
    private let device: IOHIDUserDevice

    /// The range declared to macOS, in hundredths of a nit like Apple's displays. Levels are fractions of it, so
    /// the real luminance doesn't matter.
    private static let maxNits = 400
    private static let maxValue = Double(maxNits * 100)
    private static let reportID: UInt32 = 1

    /// Monitor page (0x80) collection with a VESA Virtual Controls (0x82) brightness (0x10) feature: 16 bits from
    /// 0 to `maxValue`, physically 0 to `maxNits` cd/m².
    private static let descriptor: [UInt8] = {
        let value = UInt32(maxValue), nits = UInt16(maxNits)
        return [0x05, 0x80, 0x09, 0x01, 0xA1, 0x01, 0x85, UInt8(reportID), 0x05, 0x82, 0x09, 0x10,
                0x15, 0x00, 0x27, UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16), 0x00,
                0x35, 0x00, 0x46, UInt8(nits & 0xFF), UInt8(nits >> 8),
                0x67, 0xE1, 0x00, 0x00, 0x01, 0x55, 0x00, 0x75, 0x10, 0x95, 0x01, 0xB1, 0x02, 0x65, 0x00, 0xC0]
    }()

    /// `onSet` runs on the main thread with `display` and each level macOS sets.
    init?(containerID: UUID, level: Double, onSet: @escaping (CGDirectDisplayID, Double) -> Void) {
        let properties: [String: Any] = [
            kIOHIDReportDescriptorKey: Data(Self.descriptor),
            kIOHIDVendorIDKey: 0x1209, kIOHIDProductIDKey: 0x0001, // pid.codes test IDs
            kIOHIDProductKey: "MouseBridge Brightness", kIOHIDManufacturerKey: "MouseBridge",
            kIOHIDTransportKey: "USB",
            "kUSBContainerID": containerID.uuidString.lowercased(),
        ]
        guard let device = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, properties as CFDictionary, 0) else { return nil }
        self.device = device
        self.level = level
        // Reports carry the report ID byte, then the 16-bit value.
        IOHIDUserDeviceRegisterGetReportBlock(device) { [weak self] type, id, report, length in
            guard type == kIOHIDReportTypeFeature, id == Self.reportID, length.pointee >= 3 else { return kIOReturnUnsupported }
            guard let level = MainActor.assumeIsolated({ self?.level }) else { return kIOReturnNotReady }
            let value = UInt16((level * Self.maxValue).rounded())
            report[0] = UInt8(Self.reportID)
            report[1] = UInt8(value & 0xFF)
            report[2] = UInt8(value >> 8)
            length.pointee = 3
            return kIOReturnSuccess
        }
        IOHIDUserDeviceRegisterSetReportBlock(device) { [weak self] type, id, report, length in
            guard type == kIOHIDReportTypeFeature, id == Self.reportID, length >= 3 else { return kIOReturnUnsupported }
            let level = min(Double(UInt16(report[1]) | UInt16(report[2]) << 8) / Self.maxValue, 1)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.level = level
                onSet(self.display, level)
            }
            return kIOReturnSuccess
        }
        // The device must outlive its cancellation, which ends after the last report.
        IOHIDUserDeviceSetCancelHandler(device) { withExtendedLifetime(device) {} }
        IOHIDUserDeviceSetDispatchQueue(device, .main)
        IOHIDUserDeviceActivate(device)
    }

    isolated deinit { IOHIDUserDeviceCancel(device) }
}

/// macOS's brightness for displays with its slider, through DisplayServices' private API.
enum SystemBrightness {
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias Can = @convention(c) (CGDirectDisplayID) -> Bool
    nonisolated(unsafe) private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let setLinear = dlsym(displayServices, "DisplayServicesSetLinearBrightness").map { unsafeBitCast($0, to: Set.self) }
    private static let canChange = dlsym(displayServices, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: Can.self) }

    /// True once macOS gives the display its slider, a moment after it links a `BrightnessDevice`. Until then it
    /// ignores `set`.
    static func isLinked(_ id: CGDirectDisplayID) -> Bool { canChange?(id) == true }

    /// Sets the display's luminance to `level` (0...1, linear, as `BrightnessDevice` reports it). False if macOS
    /// refused.
    static func set(_ id: CGDirectDisplayID, _ level: Double) -> Bool { setLinear?(id, Float(level)) == 0 }
}
