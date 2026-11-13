import Foundation

/// One setting, as the transmitter serialises it inside a model block or the
/// system-settings block:
///
///     0D 0A | length (BE16) | 15 | owner | element | id (BE16) | value … | xor
///
/// `length` counts everything after itself (5 header bytes + value + check byte).
/// `xor` is the XOR of every preceding byte of the record, including `0D 0A`.
/// `owner` is the model slot (0…) or 0xA0 for the system block. `element` is an
/// array index for settings that exist once per channel / per condition.
public struct ParameterRecord: Equatable, Sendable {
    public static let marker: [UInt8] = [0x0D, 0x0A]
    public static let typeByte: UInt8 = 0x15
    public static let systemOwner: UInt8 = 0xA0

    public var owner: UInt8
    public var element: UInt8
    public var id: UInt16
    public var value: Data

    public init(owner: UInt8, element: UInt8, id: UInt16, value: Data) {
        self.owner = owner
        self.element = element
        self.id = id
        self.value = value
    }

    public var encodedSize: Int { 4 + 5 + value.count + 1 }

    public func encoded() -> Data {
        var out = Data(ParameterRecord.marker)
        let length = UInt16(5 + value.count + 1)
        out.append(UInt8(length >> 8))
        out.append(UInt8(length & 0xFF))
        out.append(ParameterRecord.typeByte)
        out.append(owner)
        out.append(element)
        out.append(UInt8(id >> 8))
        out.append(UInt8(id & 0xFF))
        out.append(value)
        out.append(Checksums.xor8(out))
        return out
    }

    /// Integer view of the value for 1/2/4-byte settings (little-endian).
    public var unsignedValue: UInt32? {
        switch value.count {
        case 1: return UInt32(value[value.startIndex])
        case 2: return UInt32(value.le16(0))
        case 4: return value.le32(0)
        default: return nil
        }
    }

    /// The value as text when it looks like a NUL-padded printable string.
    public var stringValue: String? {
        guard value.count >= 4 else { return nil }
        let trimmed = value.prefix { $0 != 0 }
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        guard value.dropFirst(trimmed.count).allSatisfy({ $0 == 0 }) else { return nil }
        return String(decoding: trimmed, as: UTF8.self)
    }
}

public enum RecordStreamError: Error, CustomStringConvertible, Equatable {
    case badChecksum(offset: Int, id: UInt16)
    case truncated(offset: Int)
    case unexpectedType(offset: Int, type: UInt8)

    public var description: String {
        switch self {
        case let .badChecksum(offset, id):
            return String(format: "record 0x%04X at offset %d has a bad checksum", id, offset)
        case let .truncated(offset):
            return "record at offset \(offset) runs past the end of the block"
        case let .unexpectedType(offset, type):
            return String(format: "record at offset %d has unexpected type byte 0x%02X", offset, type)
        }
    }
}

public struct RecordStream: Sendable {
    public var records: [ParameterRecord]
    /// Number of bytes consumed by `records`.
    public var consumed: Int
    /// Whatever follows the last record (padding).
    public var trailing: Data

    /// True when the bytes after the last record are only 0xFF / 0x00 filler.
    public var trailingIsPadding: Bool { trailing.allSatisfy { $0 == 0xFF || $0 == 0x00 } }

    /// Parse records until the data stops looking like one. Throws only for a
    /// record that starts correctly but is damaged.
    public static func parse(_ data: Data) throws -> RecordStream {
        let bytes = [UInt8](data)
        var records: [ParameterRecord] = []
        var off = 0
        while off + 4 <= bytes.count, bytes[off] == 0x0D, bytes[off + 1] == 0x0A {
            let length = Int(bytes[off + 2]) << 8 | Int(bytes[off + 3])
            guard length >= 6 else { break }
            guard off + 4 + length <= bytes.count else { throw RecordStreamError.truncated(offset: off) }
            let body = bytes[(off + 4)..<(off + 4 + length)]
            let b = Array(body)
            guard b[0] == ParameterRecord.typeByte else {
                throw RecordStreamError.unexpectedType(offset: off, type: b[0])
            }
            let id = UInt16(b[3]) << 8 | UInt16(b[4])
            let check = Checksums.xor8(bytes[off..<(off + 4 + length - 1)])
            guard check == b[length - 1] else { throw RecordStreamError.badChecksum(offset: off, id: id) }
            records.append(ParameterRecord(owner: b[1], element: b[2], id: id, value: Data(b[5..<(length - 1)])))
            off += 4 + length
        }
        return RecordStream(records: records, consumed: off, trailing: Data(bytes[off...]))
    }

    public func encoded() -> Data {
        var out = Data()
        for r in records { out.append(r.encoded()) }
        out.append(trailing)
        return out
    }
}

/// Setting IDs whose meaning is known. Everything else is carried opaquely.
public enum KnownParameter {
    /// First record of every model block; value 0xA5 marks an initialised slot.
    public static let modelMagic: UInt16 = 0x07D0
    /// Model name, NUL padded.
    public static let modelName: UInt16 = 0x07D1
    /// First record of the system block; value 0xA5.
    public static let systemMagic: UInt16 = 0x0064
}
