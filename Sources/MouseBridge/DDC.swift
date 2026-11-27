import CoreGraphics
import Foundation
import IOKit

/// DDC/CI over Apple Silicon's private IOAVService I2C API, the same route MonitorControl and m1ddc use.
/// Reads and writes VCP codes (brightness, volume) on an external display, and sets the EDID macOS sees for it.
final class DDC: @unchecked Sendable {
    enum VCP: UInt8 {
        case brightness = 0x10
        case volume = 0x62
    }

    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    nonisolated(unsafe) private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static let create = dlsym(iokit, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: Create.self) }
    private static let read = dlsym(iokit, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: Transfer.self) }
    private static let write = dlsym(iokit, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: Transfer.self) }
    private typealias CopyEDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
    private typealias SetVirtualEDID = @convention(c) (CFTypeRef, UInt32, CFData?) -> IOReturn
    private static let copyEDID = dlsym(iokit, "IOAVServiceCopyEDID").map { unsafeBitCast($0, to: CopyEDID.self) }
    private static let setVirtualEDID = dlsym(iokit, "IOAVServiceSetVirtualEDIDMode").map { unsafeBitCast($0, to: SetVirtualEDID.self) }

    private let service: CFTypeRef
    /// Serializes I2C traffic; monitors misbehave when requests overlap.
    private let queue = DispatchQueue(label: "ddc")
    private let lock = NSLock()
    /// Latest unsent value per VCP code, guarded by `lock`.
    private var pending: [VCP: UInt16] = [:]

    private init(service: CFTypeRef) { self.service = service }

    /// Finds the DDC channel of every external display, keyed by CGDirectDisplayID.
    /// Each DCPAVServiceProxy sits under the framebuffer whose EDID identifies the display.
    static func discover() -> [CGDirectDisplayID: DDC] {
        guard let create else { return [:] }
        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        let externals = activeDisplays().filter { CGDisplayIsBuiltin($0) == 0 }
        var found: [CGDirectDisplayID: DDC] = [:]
        var owner: CGDirectDisplayID?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let name = registryName(entry)
            if name.contains("AppleCLCD2") || name.contains("IOMobileFramebufferShim") {
                let product = Product(framebuffer: entry)
                owner = externals.first { Product($0) == product && found[$0] == nil }
            } else if name == "DCPAVServiceProxy", let id = owner,
                      property(entry, "Location") as? String == "External",
                      let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                found[id] = DDC(service: service)
                owner = nil
            }
        }
        return found
    }

    /// Current and maximum value of a VCP code, or nil if the display does not answer.
    func get(_ vcp: VCP) -> (value: UInt16, max: UInt16)? {
        queue.sync {
            var request: [UInt8] = [0x82, 0x01, vcp.rawValue]
            for _ in 0..<3 {
                guard send(&request) else { continue }
                usleep(40_000)
                var reply = [UInt8](repeating: 0, count: 12)
                guard let read = Self.read, read(service, 0x37, 0x51, &reply, 12) == kIOReturnSuccess,
                      reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp.rawValue else { continue }
                return (UInt16(reply[8]) << 8 | UInt16(reply[9]), UInt16(reply[6]) << 8 | UInt16(reply[7]))
            }
            return nil
        }
    }

    /// Sets a VCP code. Fire and forget: monitors rarely acknowledge writes.
    /// Rapid calls (a dragged slider) coalesce so only the latest value is sent.
    func set(_ vcp: VCP, _ value: UInt16) {
        let idle = lock.withLock {
            defer { pending[vcp] = value }
            return pending[vcp] == nil
        }
        guard idle else { return }
        queue.async { [self] in
            guard let value = lock.withLock({ pending.removeValue(forKey: vcp) }) else { return }
            var request: [UInt8] = [0x84, 0x03, vcp.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)]
            _ = send(&request)
        }
    }

    /// The EDID macOS uses for the display, the virtual one while one is set.
    func edid() -> [UInt8]? {
        var data: Unmanaged<CFData>?
        guard let copy = Self.copyEDID, copy(service, &data) == kIOReturnSuccess, let data = data?.takeRetainedValue() else { return nil }
        return [UInt8](data as Data)
    }

    /// Makes macOS use `edid` for the display instead of its own, until it reconnects or wakes from sleep. The
    /// display goes black for a moment while macOS takes it up.
    func setVirtualEDID(_ edid: [UInt8]) -> Bool {
        Self.setVirtualEDID?(service, 1, Data(edid) as CFData) == kIOReturnSuccess
    }

    /// Appends the DDC checksum to a payload and writes it, retrying once.
    private func send(_ payload: inout [UInt8]) -> Bool {
        guard let write = Self.write else { return false }
        var packet = payload
        packet.append(payload.reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 })
        for _ in 0..<2 {
            if write(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess { return true }
            usleep(10_000)
        }
        return false
    }

    private static func registryName(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &buffer)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    fileprivate static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

/// Active display IDs in CoreGraphics order.
func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids
}

/// A display model as its EDID names it, which both CoreGraphics and IORegistry framebuffers report.
struct Product: Hashable {
    let vendor: UInt32
    let model: UInt32

    init(_ id: CGDirectDisplayID) {
        vendor = CGDisplayVendorNumber(id)
        model = CGDisplayModelNumber(id)
    }

    /// The display a framebuffer drives, from its `DisplayAttributes`. Nil when nothing is attached.
    init?(framebuffer entry: io_registry_entry_t) {
        let product = (DDC.property(entry, "DisplayAttributes") as? [String: Any])?["ProductAttributes"] as? [String: Any]
        guard let vendor = product?["LegacyManufacturerID"] as? UInt32, let model = product?["ProductID"] as? UInt32 else { return nil }
        self.vendor = vendor
        self.model = model
    }
}
