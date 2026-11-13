import Foundation

/// A `.fsdll` model backup, the format FlySky Assistant writes.
///
///     [ model block 0 ][ model block 1 ] … [ system block ][ directory ]
///
/// * Every model block is `modelSize` bytes (0x42DC on the Noble NB4+) of
///   `ParameterRecord`s, copied verbatim from the transmitter.
/// * The system block is present only when *all* models were exported. The
///   vendor tool reads it in 256-byte chunks, so it is stored rounded up
///   (493 real bytes + 0xFF filler = 512 on the NB4+).
/// * The directory is always the last 3624 bytes: a 24-byte header and 100
///   fixed 36-byte entries.
///
/// Directory header (little-endian):
///
///     +0   productID        USB product ID of the transmitter (0x8D09 = Noble plus EN)
///     +4   storageField1    reply field `b` of command 0x64
///     +8   storageField2    reply field `d` of command 0x64 = firmware version (0x00010005 = 1.0.5)
///     +12  storageField3    first four payload bytes of the 0x64 reply
///     +16  modelCount
///     +20  systemSize       size of the system block in bytes (0 = not included)
///
/// Directory entry:
///
///     +0   name[20]         NUL padded
///     +20  slot             slot the model came from
///     +24  nameField        reply field `c` of command 0x6A (0x0E on the NB4+)
///     +28  offset           byte offset of the block in the file
///     +32  size             block size
public struct BackupFile: Equatable, Sendable {
    public static let maxEntries = 100
    public static let entrySize = 36
    public static let headerSize = 24
    public static let directorySize = headerSize + maxEntries * entrySize   // 3624

    public struct Model: Equatable, Sendable {
        /// Raw 20-byte name field exactly as stored.
        public var nameBytes: Data
        public var slot: UInt32
        public var nameField: UInt32
        public var data: Data

        public init(name: String, slot: UInt32, nameField: UInt32, data: Data) {
            self.nameBytes = BackupFile.encodeName(name)
            self.slot = slot
            self.nameField = nameField
            self.data = data
        }

        public init(nameBytes: Data, slot: UInt32, nameField: UInt32, data: Data) {
            var n = Data(nameBytes.prefix(20))
            if n.count < 20 { n.append(Data(count: 20 - n.count)) }
            self.nameBytes = n
            self.slot = slot
            self.nameField = nameField
            self.data = data
        }

        public var name: String { BackupFile.decodeName(nameBytes) }

        public func records() throws -> RecordStream { try RecordStream.parse(data) }

        /// The transmitter stores 14 name bytes (command 0x6A returns 14 + NUL, and
        /// the name record 0x07D1 is 15 bytes).
        public static let maxNameLength = 14

        /// nil when `name` can be stored as a model name, otherwise the reason it cannot.
        public static func nameProblem(_ name: String) -> String? {
            if name.isEmpty { return "The name is empty." }
            if name.utf8.count > maxNameLength { return "Names can be at most \(maxNameLength) characters." }
            if !name.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
                return "Only plain letters, digits and punctuation can be used in a name."
            }
            if name.hasPrefix(" ") || name.hasSuffix(" ") { return "The name starts or ends with a space." }
            return nil
        }

        /// Characters the name field accepts, cut to the maximum length (for live editing).
        public static func sanitizedName(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F })
                .prefix(maxNameLength))
        }

        public enum EditError: Error, CustomStringConvertible {
            case badName(String)
            case noNameRecord
            case slotOutOfRange(Int)
            public var description: String {
                switch self {
                case let .badName(reason): return reason
                case .noNameRecord: return "The model data contains no name record, so it cannot be renamed."
                case let .slotOutOfRange(slot): return "Slot \(slot + 1) cannot be used."
                }
            }
        }

        /// A copy with a different name. The name lives in two places – the
        /// directory entry and record 0x07D1 inside the model data – and both are
        /// updated. The name record has a fixed size, so the block size is unchanged.
        public func renamed(_ newName: String) throws -> Model {
            if let problem = Model.nameProblem(newName) { throw EditError.badName(problem) }
            var stream = try records()
            guard let index = stream.records.firstIndex(where: { $0.id == KnownParameter.modelName }) else {
                throw EditError.noNameRecord
            }
            let width = stream.records[index].value.count
            var value = Data(newName.utf8.prefix(max(width - 1, 0)))
            value.append(Data(count: width - value.count))
            stream.records[index].value = value
            var copy = self
            copy.data = stream.encoded()
            copy.nameBytes = BackupFile.encodeName(newName)
            precondition(copy.data.count == data.count)
            return copy
        }

        /// A copy prepared for another slot: every record is re-tagged with that
        /// slot (and its check byte recomputed), exactly as the block would look
        /// had the transmitter produced it from that slot itself.
        public func retargeted(toSlot slot: Int) throws -> Model {
            guard slot >= 0, slot < 0xA0 else { throw EditError.slotOutOfRange(slot) }
            if UInt32(slot) == self.slot, let first = try? records().records.first, first.owner == UInt8(slot) {
                return self
            }
            var stream = try records()
            for i in stream.records.indices { stream.records[i].owner = UInt8(slot) }
            var copy = self
            copy.data = stream.encoded()
            copy.slot = UInt32(slot)
            precondition(copy.data.count == data.count)
            return copy
        }
    }

    public var productID: UInt32
    public var storageField1: UInt32
    public var storageField2: UInt32
    public var storageField3: UInt32
    /// Declared size of the system block (header +20). 0 when not included.
    public var systemSize: UInt32
    public var models: [Model]
    /// System block bytes exactly as stored between the models and the directory.
    public var systemBlock: Data

    public init(productID: UInt32, storageField1: UInt32, storageField2: UInt32, storageField3: UInt32,
                systemSize: UInt32, models: [Model], systemBlock: Data) {
        self.productID = productID
        self.storageField1 = storageField1
        self.storageField2 = storageField2
        self.storageField3 = storageField3
        self.systemSize = systemSize
        self.models = models
        self.systemBlock = systemBlock
    }

    public var modelSize: Int { models.first?.data.count ?? 0 }
    public var hasSystemBlock: Bool { systemSize > 0 && !systemBlock.isEmpty }

    /// The meaningful part of the system block (without the read-chunk filler).
    public var systemSettings: Data {
        hasSystemBlock ? systemBlock.prefix(Int(systemSize)).asData : Data()
    }

    public var productName: String { Products.name(forProductID: UInt16(truncatingIfNeeded: productID)) }

    /// Version of the firmware that produced this backup (header +8).
    public var savedByFirmware: String { PackedVersion.string(storageField2) }

    // MARK: Parsing

    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case tooSmall(Int)
        case badModelCount(UInt32)
        case entryOutOfRange(index: Int)
        case inconsistentSizes
        case leftoverBytes(Int)

        public var description: String {
            switch self {
            case let .tooSmall(n): return "file is only \(n) bytes; a backup is at least \(BackupFile.directorySize)"
            case let .badModelCount(n): return "directory claims \(n) models (limit is \(BackupFile.maxEntries))"
            case let .entryOutOfRange(i): return "directory entry \(i) points outside the file"
            case .inconsistentSizes: return "model blocks have differing sizes"
            case let .leftoverBytes(n): return "\(n) unexplained bytes between the model data and the directory"
            }
        }
    }

    public init(data: Data) throws {
        let data = Data(data)   // normalise indices
        guard data.count >= BackupFile.directorySize else { throw ParseError.tooSmall(data.count) }
        let bodyLength = data.count - BackupFile.directorySize
        let dir = data.subdata(in: bodyLength..<data.count)

        productID = dir.le32(0)
        storageField1 = dir.le32(4)
        storageField2 = dir.le32(8)
        storageField3 = dir.le32(12)
        let count = dir.le32(16)
        systemSize = dir.le32(20)
        guard count <= UInt32(BackupFile.maxEntries) else { throw ParseError.badModelCount(count) }

        var parsed: [Model] = []
        var modelsEnd = 0
        for i in 0..<Int(count) {
            let e = dir.subdata(in: BackupFile.headerSize + i * BackupFile.entrySize
                                ..< BackupFile.headerSize + (i + 1) * BackupFile.entrySize)
            let offset = Int(e.le32(28))
            let size = Int(e.le32(32))
            guard size > 0, offset >= 0, offset + size <= bodyLength else { throw ParseError.entryOutOfRange(index: i) }
            parsed.append(Model(nameBytes: e.subdata(in: 0..<20), slot: e.le32(20), nameField: e.le32(24),
                                data: data.subdata(in: offset..<(offset + size))))
            modelsEnd = max(modelsEnd, offset + size)
        }
        if let first = parsed.first, parsed.contains(where: { $0.data.count != first.data.count }) {
            throw ParseError.inconsistentSizes
        }
        models = parsed

        let rest = data.subdata(in: modelsEnd..<bodyLength)
        if systemSize == 0 {
            guard rest.isEmpty else { throw ParseError.leftoverBytes(rest.count) }
            systemBlock = Data()
        } else {
            guard rest.count >= Int(systemSize) else { throw ParseError.entryOutOfRange(index: -1) }
            systemBlock = rest
        }
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    // MARK: Serialising

    public func serialized() -> Data {
        precondition(models.count <= BackupFile.maxEntries)
        var out = Data()
        var dir = Data(capacity: BackupFile.directorySize)
        dir.appendLE(productID)
        dir.appendLE(storageField1)
        dir.appendLE(storageField2)
        dir.appendLE(storageField3)
        dir.appendLE(UInt32(models.count))
        dir.appendLE(systemSize)
        for m in models {
            dir.append(m.nameBytes)
            dir.appendLE(m.slot)
            dir.appendLE(m.nameField)
            dir.appendLE(UInt32(out.count))
            dir.appendLE(UInt32(m.data.count))
            out.append(m.data)
        }
        dir.append(Data(count: BackupFile.directorySize - dir.count))
        out.append(systemBlock)
        out.append(dir)
        return out
    }

    public func write(to url: URL) throws {
        try serialized().write(to: url, options: .atomic)
    }

    // MARK: Validation

    public struct Issue: Equatable, Sendable, CustomStringConvertible {
        public enum Severity: String, Sendable { case warning, error }
        public var severity: Severity
        public var message: String
        public var description: String { "\(severity.rawValue): \(message)" }
    }

    /// Structural checks. A file with any `.error` issue must not be written to a transmitter.
    public func validate() -> [Issue] {
        var issues: [Issue] = []
        func err(_ m: String) { issues.append(Issue(severity: .error, message: m)) }
        func warn(_ m: String) { issues.append(Issue(severity: .warning, message: m)) }

        if models.isEmpty { err("the backup contains no models") }
        for (i, m) in models.enumerated() {
            let label = "model \(i + 1) (\"\(m.name)\", slot \(m.slot))"
            do {
                let stream = try m.records()
                if stream.records.isEmpty {
                    err("\(label): no settings records found")
                    continue
                }
                if !stream.trailingIsPadding {
                    err("\(label): \(stream.trailing.count) bytes of unrecognised data after the last record")
                }
                if stream.records.first?.id != KnownParameter.modelMagic
                    || stream.records.first?.value != Data([0xA5]) {
                    warn("\(label): block does not start with the usual 0x07D0 = A5 marker")
                }
                let owners = Set(stream.records.map(\.owner))
                if owners.count != 1 {
                    err("\(label): records are tagged with several different slots \(owners.sorted())")
                } else if let o = owners.first, UInt32(o) != m.slot {
                    warn("\(label): records are tagged slot \(o) but the directory says slot \(m.slot)")
                }
                if let nameRecord = stream.records.first(where: { $0.id == KnownParameter.modelName }),
                   let recordName = nameRecord.stringValue, recordName != m.name {
                    warn("\(label): directory name differs from the name stored in the model (\"\(recordName)\")")
                }
            } catch {
                err("\(label): \(error)")
            }
        }
        if hasSystemBlock {
            do {
                let stream = try RecordStream.parse(systemBlock)
                if stream.consumed != Int(systemSize) {
                    warn("system block: records cover \(stream.consumed) bytes but the header says \(systemSize)")
                }
                if !stream.trailingIsPadding { err("system block: unrecognised data after the last record") }
                if stream.records.contains(where: { $0.owner != ParameterRecord.systemOwner }) {
                    err("system block: contains records that are not system settings")
                }
            } catch {
                err("system block: \(error)")
            }
        } else if systemSize != 0 {
            err("header declares a system block of \(systemSize) bytes but none is present")
        }
        return issues
    }

    public var isSafeToWrite: Bool { !validate().contains { $0.severity == .error } }

    // MARK: Names

    static func encodeName(_ name: String) -> Data {
        var bytes = Data(name.utf8.prefix(20))
        if bytes.count < 20 { bytes.append(Data(count: 20 - bytes.count)) }
        return bytes
    }

    static func decodeName(_ raw: Data) -> String {
        let trimmed = raw.prefix { $0 != 0 }
        if let s = String(data: Data(trimmed), encoding: .utf8) { return s }
        return String(data: Data(trimmed), encoding: .isoLatin1) ?? ""
    }
}
