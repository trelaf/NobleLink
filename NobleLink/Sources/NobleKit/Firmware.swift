import Foundation

/// The main (internal flash) firmware image of a Noble-series transmitter.
///
/// Facts established from `Noble Plus-EN V1.0.22(.FCC).bin`:
/// * plain ARM Cortex-M image linked at 0x08008000 (a bootloader owns 0x08000000…);
/// * +0xF88: u32 length of the image excluding the trailing CRC;
/// * +0xF8C: version – patch at +0, minor at +3, major at +6;
/// * last two bytes: CRC-16/CCITT-FALSE (little-endian) of everything before them.
public struct FirmwareImage: Sendable {
    public static let loadAddress: UInt32 = 0x0800_8000
    static let lengthOffset = 0xF88
    static let versionOffset = 0xF8C

    public let data: Data

    public init(data: Data) { self.data = Data(data) }

    public var storedCRC: UInt16? { data.count >= 2 ? data.le16(data.count - 2) : nil }
    public var computedCRC: UInt16 { Checksums.crc16CCITT(data.dropLast(2).asData) }
    public var crcIsValid: Bool { storedCRC == computedCRC }

    public var stackPointer: UInt32? { data.count >= 8 ? data.le32(0) : nil }
    public var resetVector: UInt32? { data.count >= 8 ? data.le32(4) : nil }

    public var declaredLength: UInt32? {
        data.count >= FirmwareImage.lengthOffset + 4 ? data.le32(FirmwareImage.lengthOffset) : nil
    }

    public var version: String? {
        guard data.count >= FirmwareImage.versionOffset + 8 else { return nil }
        let b = data.subdata(in: FirmwareImage.versionOffset..<(FirmwareImage.versionOffset + 8))
        return "\(b[6]).\(b[3]).\(b[0])"
    }

    /// Product strings embedded in the image ("Noble+ EN", …) – a sanity check
    /// that an image is meant for a given transmitter.
    public func contains(text: String) -> Bool {
        data.range(of: Data(text.utf8)) != nil
    }

    public struct Check: Sendable, CustomStringConvertible {
        public var ok: Bool
        public var message: String
        public var description: String { (ok ? "ok    " : "FAIL  ") + message }
    }

    public func checks() -> [Check] {
        var out: [Check] = []
        out.append(Check(ok: data.count > 0x1000 && data.count < 2 * 1024 * 1024,
                         message: "size \(data.count) bytes"))
        if let sp = stackPointer, let rv = resetVector {
            out.append(Check(ok: sp & 0xFFF0_0000 == 0x2000_0000,
                             message: String(format: "initial stack pointer 0x%08X is in RAM", sp)))
            let end = FirmwareImage.loadAddress + UInt32(data.count)
            out.append(Check(ok: rv & 1 == 1 && rv >= FirmwareImage.loadAddress && rv < end,
                             message: String(format: "reset vector 0x%08X points into the image", rv)))
        }
        if let len = declaredLength {
            out.append(Check(ok: Int(len) == data.count - 2,
                             message: "declared length \(len) matches file size minus CRC"))
        }
        out.append(Check(ok: crcIsValid,
                         message: String(format: "CRC16 stored 0x%04X, computed 0x%04X", storedCRC ?? 0, computedCRC)))
        return out
    }

    public var isValid: Bool { checks().allSatisfy(\.ok) }
}

/// Everything one update needs: the firmware and (optionally) the image for the
/// external flash that holds fonts, pictures and translations.
public struct FirmwarePackage: Sendable {
    public var firmware: FirmwareImage
    /// Written to the external flash starting at address 0x80000.
    public var resource: Data?
    public var source: String

    public static let resourceBaseAddress: UInt32 = 0x80000

    public var resourceCRC32: UInt32? { resource.map { FirmwarePackage.resourceChecksum($0) } }

    /// The updater calls `ComputeCRC32(0xFFFFFFFF, data)`, and that routine inverts
    /// its seed before use – so the register starts at 0, not at the usual
    /// 0xFFFFFFFF. The result is still inverted at the end.
    public static func resourceChecksum(_ data: Data) -> UInt32 {
        Checksums.crc32(data, seed: 0xFFFF_FFFF)
    }

    public init(firmware: FirmwareImage, resource: Data?, source: String) {
        self.firmware = firmware
        self.resource = resource
        self.source = source
    }

    public enum LoadError: Error, CustomStringConvertible {
        case notRecognised(String)
        public var description: String {
            switch self { case let .notRecognised(m): return m }
        }
    }

    /// Load either a raw `.bin` (optionally with a separate resource `.bin`) or one
    /// of FlySky's Windows `…UpdateFirmware….exe` files, which carry both images
    /// as RCDATA resources 900 (firmware) and 901 (resource flash).
    public static func load(url: URL, resourceURL: URL? = nil) throws -> FirmwarePackage {
        let data = try Data(contentsOf: url)
        if data.count > 0x40, data[0] == 0x4D, data[1] == 0x5A {
            let res = try PEResources(data: data)
            guard let fw = res.rcdata[900] else {
                throw LoadError.notRecognised("\(url.lastPathComponent) is a Windows program but has no firmware "
                    + "resource (RCDATA 900); it is not a FlySky transmitter updater.")
            }
            return FirmwarePackage(firmware: FirmwareImage(data: fw), resource: res.rcdata[901],
                                   source: url.lastPathComponent)
        }
        let resource = try resourceURL.map { try Data(contentsOf: $0) }
        return FirmwarePackage(firmware: FirmwareImage(data: data), resource: resource, source: url.lastPathComponent)
    }
}

/// Just enough of the PE format to pull RCDATA resources out of an updater .exe.
struct PEResources {
    var rcdata: [Int: Data] = [:]

    init(data: Data) throws {
        let d = Data(data)
        func fail(_ m: String) -> FirmwarePackage.LoadError { .notRecognised("not a valid Windows executable: \(m)") }
        guard d.count > 0x40 else { throw fail("too small") }
        let pe = Int(d.le32(0x3C))
        guard pe + 24 < d.count, d[pe] == 0x50, d[pe + 1] == 0x45 else { throw fail("no PE header") }
        let sectionCount = Int(d.le16(pe + 6))
        let optionalSize = Int(d.le16(pe + 20))
        var sections: [(va: Int, vsize: Int, raw: Int, rsize: Int, name: String)] = []
        var so = pe + 24 + optionalSize
        for _ in 0..<sectionCount {
            guard so + 40 <= d.count else { throw fail("truncated section table") }
            let name = String(decoding: d.subdata(in: so..<(so + 8)).prefix { $0 != 0 }, as: UTF8.self)
            sections.append((Int(d.le32(so + 12)), Int(d.le32(so + 8)), Int(d.le32(so + 20)), Int(d.le32(so + 16)), name))
            so += 40
        }
        guard let rsrc = sections.first(where: { $0.name == ".rsrc" }) else { throw fail("no resource section") }
        let base = rsrc.raw
        func offset(rva: Int) -> Int? {
            for s in sections where rva >= s.va && rva < s.va + max(s.vsize, s.rsize) { return s.raw + rva - s.va }
            return nil
        }
        // Three directory levels: type → name → language.
        func entries(_ dirOffset: Int) throws -> [(id: Int, target: Int, isDir: Bool)] {
            let o = base + dirOffset
            guard o + 16 <= d.count else { throw fail("truncated resource directory") }
            let count = Int(d.le16(o + 12)) + Int(d.le16(o + 14))
            var out: [(Int, Int, Bool)] = []
            for i in 0..<count {
                let e = o + 16 + i * 8
                guard e + 8 <= d.count else { throw fail("truncated resource directory") }
                let name = d.le32(e), target = d.le32(e + 4)
                out.append((Int(name & 0x7FFF_FFFF), Int(target & 0x7FFF_FFFF), target & 0x8000_0000 != 0))
            }
            return out
        }
        for type in try entries(0) where type.id == 10 && type.isDir {
            for name in try entries(type.target) where name.isDir {
                guard let lang = try entries(name.target).first, !lang.isDir else { continue }
                let e = base + lang.target
                guard e + 16 <= d.count else { continue }
                let rva = Int(d.le32(e)), size = Int(d.le32(e + 4))
                guard let fo = offset(rva: rva), fo + size <= d.count else { continue }
                rcdata[name.id] = d.subdata(in: fo..<(fo + size))
            }
        }
    }
}
