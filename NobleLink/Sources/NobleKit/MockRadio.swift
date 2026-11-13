import Foundation

/// An in-memory transmitter for tests and for trying the tools without hardware.
///
/// Its behaviour follows the command handler found in the Noble NB4+ firmware
/// (1.0.22, function at 0x08086100), including the awkward parts:
///
/// * data areas are streamed sequentially – the offset in a 0x69 request is
///   echoed back but otherwise ignored;
/// * the read stream is only (re)started after a 0x64 query;
/// * writes to the active model are refused while a receiver is linked;
/// * a request whose sequence number equals the previous one is ignored.
public final class MockRadio: RadioTransport {
    public var productID: UInt16
    public var modelSize: Int
    public var systemSize: Int
    public var models: [Data]
    public var names: [Data]
    public var systemBlock: Data
    public var field1: UInt32 = 1
    public var replyC: UInt32 = 0
    public var layoutVersion: UInt32 = 0x0001_000B
    public var field3: UInt32 = 1
    public var firmwareVersion: (UInt8, UInt8, UInt8) = (1, 0, 22)
    public var uniqueID = "0039002E3133510A37383339"

    public var receiverLinked = false
    public var activeSlot = 0
    public var mode: UInt32 = 1

    // Fault injection.
    /// Drop the reply to the n-th request (1-based) to exercise timeouts.
    public var dropReplyToRequestNumber: Int?
    /// Corrupt one byte of the next model read (exercises validation + retry).
    public var corruptNextModelRead = false

    // Observation.
    public private(set) var requestCount = 0
    public private(set) var log: [Packet] = []
    public private(set) var announcedImport: Packet?
    public private(set) var commits = 0
    public private(set) var closed = false

    private var lastSeq: UInt32 = 0
    private var pending: [Data] = []
    private var readStreamActive = false
    private var readStream = Data()
    private var readPosition = 0
    private var writeBuffers: [UInt32: Data] = [:]
    private var stagedModels: [Int: Data] = [:]
    private var stagedSystem: Data?

    public init(productID: UInt16 = 0x8D09, modelCount: Int = 25, modelSize: Int = 0x42DC, systemSize: Int = 493) {
        self.productID = productID
        self.modelSize = modelSize
        self.systemSize = systemSize
        self.models = (0..<modelCount).map { MockRadio.blankModel(slot: $0, size: modelSize) }
        self.names = (0..<modelCount).map { Data(String(format: "Flysky %02d", $0 + 1).utf8) }
        self.systemBlock = MockRadio.blankSystem(size: systemSize)
    }

    /// Build a mock whose contents equal a backup file.
    public convenience init(loading file: BackupFile) {
        self.init(productID: UInt16(truncatingIfNeeded: file.productID), modelCount: file.models.count,
                  modelSize: file.modelSize, systemSize: Int(file.systemSize))
        for (i, m) in file.models.enumerated() {
            models[i] = m.data
            names[i] = m.nameBytes.prefix { $0 != 0 }.asData
        }
        if file.hasSystemBlock { systemBlock = file.systemSettings }
        field1 = file.storageField1
        layoutVersion = file.storageField2
        field3 = file.storageField3
    }

    static func blankModel(slot: Int, size: Int) -> Data {
        var d = ParameterRecord(owner: UInt8(slot), element: 0, id: KnownParameter.modelMagic, value: Data([0xA5])).encoded()
        var name = Data(String(format: "Flysky %02d", slot + 1).utf8)
        name.append(Data(count: 15 - name.count))
        d.append(ParameterRecord(owner: UInt8(slot), element: 0, id: KnownParameter.modelName, value: name).encoded())
        var id: UInt16 = 0x07D2
        while d.count + 11 <= size {
            let remaining = size - d.count
            // Finish exactly on the block boundary: records are 11 + extra bytes long.
            let extra = remaining < 22 ? remaining - 11 : 0
            d.append(ParameterRecord(owner: UInt8(slot), element: 0, id: id, value: Data(count: 1 + extra)).encoded())
            id += 1
        }
        precondition(d.count == size)
        return d
    }

    static func blankSystem(size: Int) -> Data {
        var d = ParameterRecord(owner: ParameterRecord.systemOwner, element: 0, id: KnownParameter.systemMagic,
                                value: Data([0xA5])).encoded()
        var id: UInt16 = 0x0065
        while d.count + 11 <= size {
            let remaining = size - d.count
            let extra = remaining < 22 ? remaining - 11 : 0
            d.append(ParameterRecord(owner: ParameterRecord.systemOwner, element: 0, id: id,
                                     value: Data(count: 1 + extra)).encoded())
            id += 1
        }
        precondition(d.count == size)
        return d
    }

    // MARK: RadioTransport

    public func write(report: Data) throws {
        guard !closed else { throw RadioError.ioFailed("mock is closed") }
        let p = Packet(report: report)
        log.append(p)
        // The firmware only acts when the sequence number changes.
        guard p.seq != lastSeq else { return }
        lastSeq = p.seq
        requestCount += 1
        guard let reply = handle(p) else { return }
        if dropReplyToRequestNumber == requestCount { return }
        pending.append(reply.encoded())
    }

    public func read(timeout: TimeInterval) throws -> Data? {
        guard !closed else { throw RadioError.ioFailed("mock is closed") }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    public func close() { closed = true }

    // MARK: Firmware behaviour

    private var totalSize: Int { models.count * modelSize + systemSize }

    private func handle(_ p: Packet) -> Packet? {
        var r = Packet(seq: p.seq, command: p.command)
        switch Command(rawValue: p.command) {
        case .getVersion:
            var block = Data(count: 0x30)
            block[0] = 3; block[2] = 1
            block[0x28] = firmwareVersion.2; block[0x2B] = firmwareVersion.1; block[0x2E] = firmwareVersion.0
            return Packet(seq: p.seq, command: p.command, payload: block)

        case .setMode:
            guard p.a == 0 else { return nil }
            mode = p.b
            r.b = p.b
            return r

        case .receiverStatus:
            guard p.a == 0 else { return nil }
            r.b = receiverLinked ? 1 : 0
            return r

        case .uniqueID:
            guard p.a == 0 else { return nil }
            r.b = 0x60
            return Packet(seq: p.seq, command: p.command, b: 0x60, payload: Data(uniqueID.utf8))

        case .storageInfo:
            readStreamActive = false
            if p.a == 0 {
                var payload = Data()
                payload.appendLE(field3)
                payload.appendLE(UInt32(totalSize))
                payload.appendLE(UInt32(systemSize))
                payload.appendLE(UInt32(models.count))
                payload.appendLE(UInt32(modelSize))
                return Packet(seq: p.seq, command: p.command, a: 0, b: field1, c: replyC, d: layoutVersion, payload: payload)
            }
            announcedImport = p
            r.a = p.a
            return r

        case .dataBlock:
            return handleDataBlock(p)

        case .modelName:
            r.a = p.a
            r.b = p.b
            guard Int(p.b) < models.count else { r.b = 0xFF; return r }
            if p.a == 0 {
                var name = names[Int(p.b)].prefix(14).asData
                name.append(0)
                return Packet(seq: p.seq, command: p.command, a: 0, b: p.b, c: 0x0E, d: 0, payload: name)
            }
            names[Int(p.b)] = p.payload.prefix(14).prefix { $0 != 0 }.asData
            return r

        case .commit:
            guard p.a == 0 else { return nil }
            commits += 1
            // Data that did not fill a whole area (a backup from other firmware) is
            // applied the way the firmware does it: record by record, matched by ID.
            for (area, buffer) in writeBuffers where area >= 2 && Int(area) - 2 < models.count {
                let slot = Int(area) - 2
                models[slot] = MockRadio.merge(incoming: buffer, into: models[slot], slot: slot)
            }
            writeBuffers.removeAll()
            for (slot, data) in stagedModels { models[slot] = data }
            if let s = stagedSystem { systemBlock = s }
            stagedModels.removeAll()
            stagedSystem = nil
            r.b = 0
            return r

        default:
            return nil   // unknown commands are not answered (e.g. 0x76 on this firmware)
        }
    }

    /// Firmware import, per record (FUN_0808d898 in 1.0.22): known settings take the
    /// incoming value (cut or zero-padded to the length the firmware uses), unknown
    /// ones are ignored, settings missing from the incoming data keep their value.
    static func merge(incoming: Data, into current: Data, slot: Int) -> Data {
        guard var target = try? RecordStream.parse(current) else { return current }
        // Parse leniently: stop at the first damaged record, as the firmware would skip it.
        var values: [String: Data] = [:]
        if let stream = try? RecordStream.parse(incoming) {
            for r in stream.records { values["\(r.id)/\(r.element)"] = r.value }
        }
        for i in target.records.indices {
            let r = target.records[i]
            guard let v = values["\(r.id)/\(r.element)"] else { continue }
            var value = Data(v.prefix(r.value.count))
            if value.count < r.value.count { value.append(Data(count: r.value.count - value.count)) }
            target.records[i].value = value
            target.records[i].owner = UInt8(slot)
        }
        return target.encoded()
    }

    private func handleDataBlock(_ p: Packet) -> Packet {
        let n = min(Int(p.d), 0x100)
        var r = Packet(seq: p.seq, command: p.command, a: p.a, b: p.b, c: p.c, d: UInt32(n))
        guard p.b < 0x1B else { r.d = 0; return r }

        if p.a == 0 {
            if !readStreamActive {
                readStreamActive = true
                readPosition = 0
                switch p.b {
                case 0:
                    readStream = models.reduce(Data(), +) + systemBlock
                case 1:
                    readStream = systemBlock
                default:
                    let slot = Int(p.b) - 2
                    readStream = slot < models.count ? models[slot] : Data()
                    if corruptNextModelRead, readStream.count > 40 {
                        readStream[40] ^= 0x55
                        corruptNextModelRead = false
                    }
                }
            }
            var chunk = Data()
            for _ in 0..<n {
                chunk.append(readPosition < readStream.count ? readStream[readStream.startIndex + readPosition] : 0xFF)
                readPosition += 1
            }
            if totalSize <= Int(p.c) + n { readStreamActive = false }
            return Packet(seq: p.seq, command: p.command, a: 0, b: p.b, c: p.c, d: UInt32(n), payload: chunk)
        }

        // Write.
        if receiverLinked && (p.b == 0 || Int(p.b) == activeSlot + 2) {
            r.b = 0xFF
            return r
        }
        var buffer = writeBuffers[p.b] ?? Data()
        buffer.append(p.payload.prefix(n))
        let expected = p.b == 1 ? systemSize : (p.b == 0 ? totalSize : modelSize)
        if Int(p.c) + n == expected {
            // Complete: the firmware parses and applies what it accumulated.
            if p.b == 1 {
                stagedSystem = buffer
            } else if p.b >= 2 {
                stagedModels[Int(p.b) - 2] = buffer
            }
            writeBuffers[p.b] = nil
        } else {
            writeBuffers[p.b] = buffer
        }
        return r
    }
}
