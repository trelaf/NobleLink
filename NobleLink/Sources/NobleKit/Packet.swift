import Foundation

/// One 280-byte HID report exchanged with the transmitter.
///
/// Layout (all integers little-endian), recovered from `USBManager::onFunctionSend`,
/// `onFunctionSendReport` and `readBuffReport` in FlySky Assistant 4.0.1:
///
///     offset  size  field
///          0     4  seq      host counter; starts at 2, +1 per report, wraps to 2 after 100000
///          4     4  command
///          8     4  a        direction for 0x6x commands (0 = read, 1 = write); address for bootloader commands
///         12     4  b
///         16     4  c
///         20     4  d
///         24   256  payload  zero padded
public struct Packet: Equatable, Sendable {
    public static let headerSize = 24
    public static let payloadSize = 256
    public static let reportSize = headerSize + payloadSize   // 280

    public var seq: UInt32
    public var command: UInt32
    public var a: UInt32
    public var b: UInt32
    public var c: UInt32
    public var d: UInt32
    /// Always exactly `payloadSize` bytes.
    public private(set) var payload: Data

    public init(seq: UInt32 = 0, command: UInt32, a: UInt32 = 0, b: UInt32 = 0, c: UInt32 = 0, d: UInt32 = 0,
                payload: Data = Data()) {
        precondition(payload.count <= Packet.payloadSize, "payload larger than one report")
        self.seq = seq
        self.command = command
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        var p = Data(payload)
        if p.count < Packet.payloadSize {
            p.append(Data(count: Packet.payloadSize - p.count))
        }
        self.payload = p
    }

    public init(command: Command, a: UInt32 = 0, b: UInt32 = 0, c: UInt32 = 0, d: UInt32 = 0, payload: Data = Data()) {
        self.init(seq: 0, command: command.rawValue, a: a, b: b, c: c, d: d, payload: payload)
    }

    /// Serialise to the 280 bytes that go on the wire (without a report-ID prefix).
    public func encoded() -> Data {
        var out = Data(capacity: Packet.reportSize)
        for v in [seq, command, a, b, c, d] { out.appendLE(v) }
        out.append(payload)
        return out
    }

    /// Parse a received report. Short reports are zero-extended; a single leading
    /// report-ID byte (281-byte report) is dropped.
    public init(report: Data) {
        var r = Data(report)
        if r.count == Packet.reportSize + 1 { r = r.dropFirst().asData }
        if r.count < Packet.reportSize { r.append(Data(count: Packet.reportSize - r.count)) }
        self.seq = r.le32(0)
        self.command = r.le32(4)
        self.a = r.le32(8)
        self.b = r.le32(12)
        self.c = r.le32(16)
        self.d = r.le32(20)
        self.payload = r.subdata(in: r.startIndex + 24 ..< r.startIndex + Packet.reportSize)
    }

    public var summary: String {
        let name = Command(rawValue: command).map { "\($0)" } ?? "?"
        return String(format: "seq=%u cmd=0x%02X(%@) a=%u b=%u c=%u d=%u", seq, command, name, a, b, c, d)
    }
}

/// Command numbers. Names are ours; meanings are inferred from how the vendor
/// application uses each one (see docs/PROTOCOL.md).
public enum Command: UInt32, Sendable, CustomStringConvertible {
    // Low numbers: firmware-update ("bootloader style") commands.
    case getVersion = 0x01          // payload: version bytes
    case eraseFirmware = 0x03       // a = image size
    case eraseFlashBlock = 0x04     // a = address, b = 2
    case writeBlock = 0x05          // a = address/offset, b = length, c = 1 (internal) / 2 (external flash)
    case verifyFlashCRC32 = 0x06    // a = address, b = length, c = 0xFFFFFFFF; reply c = CRC32
    case reset = 0x07
    case verifyFirmwareCRC16 = 0x08 // reply c = CRC16

    // 0x64+: application commands.
    case storageInfo = 0x64         // a=0 read layout; a=1 announce an import
    case dataBlock = 0x69           // a = 0 read / 1 write, b = area, c = offset, d = length
    case modelName = 0x6A           // a = 0 read / 1 write, b = slot
    case commit = 0x6B              // reply b: 0 = done, 1 = busy
    case setMode = 0x6C             // b = Mode
    case receiverStatus = 0x6D      // reply b bit0 = a receiver is linked/on
    case uniqueID = 0x6F            // payload: the MCU unique ID as 24 hex digits ("%08X%08X%08X")
    case receiverInfo = 0x70
    case productInfo = 0x71
    case receiverControl = 0x72
    case receiverWrite = 0x73
    case receiverQuery = 0x74
    case receiverErase = 0x75
    case modelOrder = 0x76          // a = 0 read / 1 write; payload: slot table

    public var description: String {
        switch self {
        case .getVersion: return "getVersion"
        case .eraseFirmware: return "eraseFirmware"
        case .eraseFlashBlock: return "eraseFlashBlock"
        case .writeBlock: return "writeBlock"
        case .verifyFlashCRC32: return "verifyFlashCRC32"
        case .reset: return "reset"
        case .verifyFirmwareCRC16: return "verifyFirmwareCRC16"
        case .storageInfo: return "storageInfo"
        case .dataBlock: return "dataBlock"
        case .modelName: return "modelName"
        case .commit: return "commit"
        case .setMode: return "setMode"
        case .receiverStatus: return "receiverStatus"
        case .uniqueID: return "uniqueID"
        case .receiverInfo: return "receiverInfo"
        case .productInfo: return "productInfo"
        case .receiverControl: return "receiverControl"
        case .receiverWrite: return "receiverWrite"
        case .receiverQuery: return "receiverQuery"
        case .receiverErase: return "receiverErase"
        case .modelOrder: return "modelOrder"
        }
    }
}

/// Argument `b` of `Command.setMode` (0x6C).
public enum Mode: UInt32, Sendable {
    case idle = 1            // sent on connect and whenever the vendor app leaves a page
    case firmwareUpdate = 2
    case modelTransfer = 3   // sent before reading or writing model data
    case modelList = 4       // sent before listing models and at the start of an import
    case deviceInfo = 6
}

/// Area selector, argument `b` of `Command.dataBlock` (0x69).
public enum DataArea {
    /// The transmitter-wide ("system") settings block.
    public static let global: UInt32 = 1
    /// Model slot `n` lives in area `n + 2`.
    public static func model(slot: Int) -> UInt32 { UInt32(slot + 2) }
}

// MARK: - Little-endian helpers

extension Data {
    var asData: Data { Data(self) }

    public func le32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    public func le16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func be16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }

    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
