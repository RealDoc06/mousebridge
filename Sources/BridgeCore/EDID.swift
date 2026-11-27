import CryptoKit
import Foundation

/// The ContainerID side of native brightness. macOS gives a display its brightness slider when a USB HID brightness
/// device shares the display's ContainerID, which an EDID carries in a DisplayID ContainerID data block (Apple's
/// own displays ship one). Other displays get one through a virtual EDID with an extra DisplayID extension block.
public enum EDID {
    /// The ContainerID in the EDID's DisplayID extension blocks, if any.
    public static func containerID(in edid: [UInt8]) -> UUID? {
        guard edid.count >= 128 else { return nil }
        for start in stride(from: 128, to: min(edid.count, 128 * (Int(edid[126]) + 1)), by: 128) where start + 128 <= edid.count && edid[start] == 0x70 {
            // DisplayID section: version, payload length, product type, extension count, then data blocks.
            let end = min(start + 5 + Int(edid[start + 2]), start + 127)
            var block = start + 5
            while block + 3 <= end {
                let length = Int(edid[block + 2])
                if edid[block] == containerTag, length == 16, block + 3 + 16 <= end {
                    return UUID(uuid: uuidBytes(edid[(block + 3)...]))
                }
                block += 3 + length
            }
        }
        return nil
    }

    /// The EDID with a DisplayID 2.0 extension block appended that carries `id`, or nil if it isn't an EDID with
    /// room for another block.
    public static func addingContainerID(_ id: UUID, to edid: [UInt8]) -> [UInt8]? {
        guard edid.count >= 128, edid.count == 128 * (Int(edid[126]) + 1), edid[126] < 254 else { return nil }
        var base = Array(edid[..<128])
        base[126] += 1
        base[127] = checksum(base[..<127])
        let u = id.uuid
        let payload = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        // DisplayID 2.0, 19 bytes of data blocks, the base EDID's product type, no extensions; then the block.
        var section: [UInt8] = [0x20, 19, 0, 0, containerTag, 0, 16] + payload
        section.append(checksum(section[...]))
        var block = [0x70] + section + [UInt8](repeating: 0, count: 126 - section.count)
        block.append(checksum(block[...]))
        return base + edid[128...] + block
    }

    /// The ContainerID MouseBridge gives a display: hashed from the base block, which identifies the display (its
    /// serial number included) and which the patch leaves alone but for the extension count and checksum, so the
    /// ID stays the same across reconnects and before and after patching. Two displays with byte-identical base
    /// blocks (no serial numbers) would share one, so `NativeBrightness` leaves those out.
    public static func ownContainerID(for edid: [UInt8]) -> UUID {
        var bytes = Array(SHA256.hash(data: edid.prefix(126)).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x80 // RFC 9562 version 8 (custom), so it can't pass for a real one
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: uuidBytes(bytes[...]))
    }

    /// DisplayID 2.0 ContainerID data block tag.
    private static let containerTag: UInt8 = 0x29

    /// The byte that makes `bytes` and it sum to 0 mod 256, as EDID and DisplayID checksums do.
    private static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        UInt8((256 - bytes.reduce(0) { ($0 + Int($1)) % 256 }) % 256)
    }

    private static func uuidBytes(_ b: ArraySlice<UInt8>) -> uuid_t {
        let i = b.startIndex
        return (b[i], b[i + 1], b[i + 2], b[i + 3], b[i + 4], b[i + 5], b[i + 6], b[i + 7],
                b[i + 8], b[i + 9], b[i + 10], b[i + 11], b[i + 12], b[i + 13], b[i + 14], b[i + 15])
    }
}
