import Foundation

/// Storage layout reported by command 0x64.
public struct StorageInfo: Equatable, Sendable {
    public var field1: UInt32          // reply b
    public var replyC: UInt32          // reply c (not stored in backups)
    /// reply d: the firmware version, packed as major<<16 | minor<<8 | patch
    /// (0x00010016 = 1.0.22). Stored in backups; on import the firmware treats
    /// data saved by anything older than 1.0.11 as "old format" and converts it.
    public var layoutVersion: UInt32
    public var field3: UInt32          // payload +0
    public var totalSize: UInt32       // payload +4  = modelCount * modelSize + systemSize
    public var systemSize: UInt32      // payload +8
    public var modelCount: Int         // payload +12
    public var modelSize: UInt32       // payload +16

    init(reply: Packet) {
        field1 = reply.b
        replyC = reply.c
        layoutVersion = reply.d
        field3 = reply.payload.le32(0)
        totalSize = reply.payload.le32(4)
        systemSize = reply.payload.le32(8)
        modelCount = Int(reply.payload[reply.payload.startIndex + 12])
        modelSize = reply.payload.le32(16)
    }
}

public enum PackedVersion {
    /// 0x00010016 → "1.0.22"
    public static func string(_ v: UInt32) -> String { "\(v >> 16).\((v >> 8) & 0xFF).\(v & 0xFF)" }
    /// First firmware whose saved data is not treated as "old format" on import.
    public static let firstCurrentFormat: UInt32 = 0x0001_000B
}

public struct DeviceInfo: Equatable, Sendable {
    public var productID: UInt16
    public var productName: String
    /// Text the transmitter reports about itself (command 0x6F).
    /// The transmitter's unique chip ID (command 0x6F), 24 hex digits.
    public var uniqueID: String
    /// "major.minor.patch" of the running firmware.
    public var firmwareVersion: String?
    /// Version of the bootloader / hardware block, as the vendor tool formats it.
    public var bootVersion: String?
    public var versionBlock: Data

    public init(productID: UInt16, productName: String, uniqueID: String, firmwareVersion: String?,
                bootVersion: String?, versionBlock: Data) {
        self.productID = productID
        self.productName = productName
        self.uniqueID = uniqueID
        self.firmwareVersion = firmwareVersion
        self.bootVersion = bootVersion
        self.versionBlock = versionBlock
    }
}

public struct ModelSlot: Equatable, Sendable, Identifiable {
    public var slot: Int
    public var name: String
    public var nameBytes: Data
    public var nameField: UInt32
    public var id: Int { slot }

    public init(slot: Int, name: String, nameBytes: Data, nameField: UInt32) {
        self.slot = slot
        self.name = name
        self.nameBytes = nameBytes
        self.nameField = nameField
    }
}

public struct RestoreItem: Equatable, Sendable {
    /// Index into `BackupFile.models`.
    public var fileIndex: Int
    /// Slot on the transmitter to overwrite.
    public var targetSlot: Int
    public init(fileIndex: Int, targetSlot: Int) {
        self.fileIndex = fileIndex
        self.targetSlot = targetSlot
    }
}

public struct RestoreReport: Sendable {
    public struct Entry: Sendable {
        public var name: String
        public var targetSlot: Int
        /// nil when verification was not requested.
        public var verified: Bool?
        public var differences: Int
        /// True when the slot already held exactly these settings, so nothing was written.
        public var skipped = false
    }

    public var writtenCount: Int { entries.filter { !$0.skipped }.count }
    public var skippedCount: Int { entries.filter(\.skipped).count }
    public var entries: [Entry] = []
    public var systemSettingsWritten = false
    /// True when the backup was saved by a different firmware version than the
    /// one running now; the transmitter may then convert the data, and a
    /// read-back can legitimately differ from what was sent.
    public var layoutConverted = false
    /// True when the backup came from older firmware with a different set of
    /// settings, so it was imported setting by setting.
    public var crossVersion = false
    /// Cross-version only: per model, settings in the backup that this firmware
    /// no longer has (skipped), and settings this firmware has that the backup
    /// lacks (left as they were in the slot).
    public var settingsSkipped = 0
    public var settingsKeptFromSlot = 0
    public var allVerified: Bool { entries.allSatisfy { $0.verified != false } }
}

public typealias ProgressHandler = (_ fraction: Double, _ message: String) -> Void

/// High-level operations. The command sequences mirror FlySky Assistant 4.0.1
/// (`GetOutPutListThread`, `OutputThread`, `InputThread`) with two deliberate
/// differences, both derived from the transmitter firmware's handler:
///
/// 1. Data chunks (0x69) are sent exactly once and never repeated. The
///    transmitter ignores the offset field and streams sequentially, so a
///    repeated chunk request would silently shift everything after it.
/// 2. Before every area read we issue command 0x64, which is what resets the
///    transmitter's stream position.
public final class RadioSession {
    public let link: RadioLink
    public let productID: UInt16

    public init(link: RadioLink, productID: UInt16) {
        self.link = link
        self.productID = productID
    }

    public convenience init(transport: RadioTransport, productID: UInt16, timing: LinkTiming = LinkTiming()) {
        self.init(link: RadioLink(transport: transport, timing: timing), productID: productID)
    }

    // MARK: Basic commands

    /// What the vendor tool sends right after opening the device.
    public func hello() throws {
        try link.send(Packet(command: .setMode, b: Mode.idle.rawValue))
        link.drain()
    }

    public func setMode(_ mode: Mode, waitForEcho: Bool = true) throws {
        let p = Packet(command: .setMode, b: mode.rawValue)
        if waitForEcho {
            _ = try link.request(p, what: "enter mode \(mode)") {
                $0.command == Command.setMode.rawValue && $0.b == mode.rawValue
            }
        } else {
            try link.send(p)
        }
    }

    /// Return the transmitter to its normal state. Never throws: used on the way out.
    public func leave() {
        try? link.send(Packet(command: .setMode, b: Mode.idle.rawValue))
        link.drain()
    }

    /// Throws `.receiverActive` when a receiver is linked (the transmitter then
    /// refuses to overwrite the active model, and the vendor tool refuses everything).
    public func requireReceiverOff() throws {
        let reply = try link.request(Packet(command: .receiverStatus), what: "receiver status")
        if reply.b & 1 != 0 { throw RadioError.receiverActive }
    }

    public func storageInfo() throws -> StorageInfo {
        let reply = try link.request(Packet(command: .storageInfo), what: "storage layout") {
            $0.command == Command.storageInfo.rawValue && $0.a == 0
        }
        let info = StorageInfo(reply: reply)
        guard info.modelSize > 0, info.modelCount > 0, info.modelCount <= BackupFile.maxEntries,
              info.modelSize < 4 * 1024 * 1024 else {
            throw RadioError.unexpected("implausible storage layout \(info)")
        }
        return info
    }

    public func deviceInfo() throws -> DeviceInfo {
        let v = try link.request(Packet(command: .getVersion), what: "version")
        let block = v.payload.prefix(0x30).asData
        func byte(_ i: Int) -> UInt8 { block[block.startIndex + i] }
        // Same formatting as GetDeviceInfoThread::run.
        let bootBlank = (0..<4).allSatisfy { byte($0) == 0xFF }
        let boot = bootBlank ? nil : "\(byte(2)).\(byte(0))"
        let fwBlank = byte(0x2E) == 0xFF && byte(0x2B) == 0xFF && byte(0x28) == 0xFF
        let fw = fwBlank ? nil : "\(byte(0x2E)).\(byte(0x2B)).\(byte(0x28))"

        var name = ""
        if let n = try? link.request(Packet(command: .uniqueID), what: "unique ID") {
            let raw = n.payload.prefix(0x60).prefix { $0 != 0 }
            name = String(data: Data(raw), encoding: .utf8) ?? String(data: Data(raw), encoding: .isoLatin1) ?? ""
        }
        return DeviceInfo(productID: productID, productName: Products.name(forProductID: productID),
                          uniqueID: name, firmwareVersion: fw, bootVersion: boot, versionBlock: block)
    }

    public func modelName(slot: Int) throws -> ModelSlot {
        let reply = try link.request(Packet(command: .modelName, b: UInt32(slot)), what: "name of model \(slot + 1)") {
            $0.command == Command.modelName.rawValue && $0.a == 0 && ($0.b == UInt32(slot) || $0.b == 0xFF)
        }
        if reply.b == 0xFF { throw RadioError.refused("model slot \(slot + 1) does not exist") }
        let length = min(Int(reply.c), 20)
        let raw = reply.payload.prefix(length).prefix { $0 != 0 }.asData
        return ModelSlot(slot: slot, name: BackupFile.decodeName(raw), nameBytes: raw, nameField: reply.c)
    }

    // MARK: Listing

    public func listModels(progress: ProgressHandler? = nil) throws -> (info: StorageInfo, models: [ModelSlot]) {
        try setMode(.modelList)
        try requireReceiverOff()
        let info = try storageInfo()
        var models: [ModelSlot] = []
        for slot in 0..<info.modelCount {
            progress?(Double(slot) / Double(info.modelCount), "Reading model names")
            models.append(try modelName(slot: slot))
        }
        progress?(1, "Done")
        return (info, models)
    }

    // MARK: Reading data

    /// Read `length` bytes of one area as a single uninterrupted stream.
    private func readAreaOnce(area: UInt32, length: Int, what: String,
                              chunkProgress: ((Int) -> Void)?) throws -> Data {
        // 0x64 resets the transmitter's stream state (see class comment).
        _ = try link.request(Packet(command: .storageInfo), what: "storage layout") {
            $0.command == Command.storageInfo.rawValue && $0.a == 0
        }
        link.drain()
        var out = Data(capacity: length)
        var offset = 0
        while offset < length {
            let n = min(Packet.payloadSize, length - offset)
            let req = Packet(command: .dataBlock, a: 0, b: area, c: UInt32(offset), d: UInt32(n))
            let reply = try link.exchangeOnce(req, what: "\(what), offset \(offset)", timeout: link.timing.chunkTimeout) {
                $0.command == Command.dataBlock.rawValue && $0.a == 0 && $0.c == UInt32(offset)
            }
            guard reply.b == area else { throw RadioError.refused("\(what): area \(area) is not readable") }
            guard reply.d == UInt32(n) else { throw RadioError.unexpected("\(what): short chunk at offset \(offset)") }
            out.append(reply.payload.prefix(n))
            offset += n
            chunkProgress?(offset)
        }
        return out
    }

    /// Read and validate a model block, retrying the whole block from the start
    /// if it arrives damaged.
    public func readModelBlock(slot: Int, size: Int, attempts: Int = 3,
                               chunkProgress: ((Int) -> Void)? = nil) throws -> Data {
        var lastError: Error = RadioError.unexpected("no attempt made")
        for attempt in 1...attempts {
            do {
                let data = try readAreaOnce(area: DataArea.model(slot: slot), length: size,
                                            what: "model \(slot + 1)", chunkProgress: chunkProgress)
                if data.prefix(21).allSatisfy({ $0 == 0xFF }) {
                    throw RadioError.corruptData("model \(slot + 1) came back empty (all 0xFF)")
                }
                let stream = try RecordStream.parse(data)
                guard !stream.records.isEmpty, stream.trailingIsPadding else {
                    throw RadioError.corruptData("model \(slot + 1) does not parse as settings records")
                }
                return data
            } catch let e as RadioError where e == .cancelled {
                throw e
            } catch {
                lastError = error
                link.trace?("! attempt \(attempt) for model \(slot + 1) failed: \(error)")
                link.drain()
            }
        }
        throw lastError
    }

    /// Read the transmitter-wide settings block the way the vendor tool does:
    /// in whole 256-byte chunks, so the result is rounded up and 0xFF-filled.
    public func readSystemBlock(info: StorageInfo, attempts: Int = 3) throws -> Data {
        let rounded = (Int(info.systemSize) + Packet.payloadSize - 1) / Packet.payloadSize * Packet.payloadSize
        var lastError: Error = RadioError.unexpected("no attempt made")
        for attempt in 1...attempts {
            do {
                let data = try readAreaOnce(area: DataArea.global, length: rounded, what: "system settings",
                                            chunkProgress: nil)
                let stream = try RecordStream.parse(data)
                guard stream.consumed == Int(info.systemSize), stream.trailingIsPadding else {
                    throw RadioError.corruptData("system settings do not parse as settings records")
                }
                return data
            } catch let e as RadioError where e == .cancelled {
                throw e
            } catch {
                lastError = error
                link.trace?("! attempt \(attempt) for system settings failed: \(error)")
                link.drain()
            }
        }
        throw lastError
    }

    // MARK: Backup

    /// Read models into a `BackupFile`. `slots == nil` means everything, and
    /// (like the vendor tool) only a full backup includes the system settings.
    public func backup(slots: [Int]? = nil, progress: ProgressHandler? = nil) throws -> BackupFile {
        try requireReceiverOff()
        try setMode(.modelTransfer)
        let info = try storageInfo()
        let wanted = slots ?? Array(0..<info.modelCount)
        guard !wanted.isEmpty, wanted.allSatisfy({ $0 >= 0 && $0 < info.modelCount }) else {
            throw RadioError.unexpected("slot out of range (transmitter has \(info.modelCount) models)")
        }
        let full = Set(wanted) == Set(0..<info.modelCount) && wanted.count == info.modelCount

        progress?(0, "Reading model names")
        let names = try wanted.map { try modelName(slot: $0) }

        var systemBlock = Data()
        if full {
            progress?(0, "Reading system settings")
            systemBlock = try readSystemBlock(info: info)
        }

        let totalBytes = Double(wanted.count * Int(info.modelSize))
        var models: [BackupFile.Model] = []
        for (i, slot) in wanted.enumerated() {
            let label = "Reading \(names[i].name.isEmpty ? "model \(slot + 1)" : names[i].name)"
            let done = Double(i * Int(info.modelSize))
            progress?(done / totalBytes, label)
            let data = try readModelBlock(slot: slot, size: Int(info.modelSize)) { bytes in
                progress?((done + Double(bytes)) / totalBytes, label)
            }
            models.append(BackupFile.Model(nameBytes: names[i].nameBytes, slot: UInt32(slot),
                                           nameField: names[i].nameField, data: data))
        }
        // Leave the stream position reset.
        _ = try? storageInfo()
        progress?(1, "Done")
        return BackupFile(productID: UInt32(productID), storageField1: info.field1,
                          storageField2: info.layoutVersion, storageField3: info.field3,
                          systemSize: full ? info.systemSize : 0, models: models, systemBlock: systemBlock)
    }

    // MARK: Restore

    private func writeArea(area: UInt32, data: Data, what: String, chunkProgress: ((Int) -> Void)?) throws {
        var offset = 0
        let bytes = Data(data)
        while offset < bytes.count {
            let n = min(Packet.payloadSize, bytes.count - offset)
            let chunk = bytes.subdata(in: offset..<(offset + n))
            let req = Packet(command: .dataBlock, a: 1, b: area, c: UInt32(offset), d: UInt32(n), payload: chunk)
            let reply = try link.exchangeOnce(req, what: "\(what), offset \(offset)", timeout: link.timing.chunkTimeout) {
                $0.command == Command.dataBlock.rawValue && $0.a == 1 && $0.c == UInt32(offset)
            }
            if reply.b == 0xFF {
                throw RadioError.refused("\(what): the transmitter will not overwrite the model that is "
                    + "currently in use while a receiver is linked")
            }
            guard reply.b == area, reply.d == UInt32(n) else {
                throw RadioError.unexpected("\(what): write not acknowledged at offset \(offset)")
            }
            offset += n
            chunkProgress?(offset)
        }
    }

    /// How a backup's data format relates to the transmitter's.
    public enum FormatRelation: Equatable, Sendable {
        /// Same model size: the data goes back exactly as saved.
        case same
        /// Saved by older firmware with a different set of settings. The
        /// transmitter imports it setting by setting (matched by ID): settings it
        /// knows are applied, settings it no longer has are skipped, and new
        /// settings keep the value already in the slot. FlySky's own advice after a
        /// firmware update – back up, update, import – relies on exactly this.
        case olderFirmware(file: String, device: String)
        /// Saved by newer firmware than the transmitter runs. Not supported.
        case newerFirmware(file: String, device: String)
    }

    public static func formatRelation(file: BackupFile, info: StorageInfo) -> FormatRelation {
        guard file.modelSize != Int(info.modelSize) else { return .same }
        let f = file.savedByFirmware, d = PackedVersion.string(info.layoutVersion)
        return file.storageField2 < info.layoutVersion ? .olderFirmware(file: f, device: d) : .newerFirmware(file: f, device: d)
    }

    /// Why a backup cannot be written to this transmitter, or nil.
    ///
    /// Backups from older firmware are refused unless `allowOlderFirmware` is set:
    /// the transmitter matches settings by number, and firmware updates renumber
    /// some of them (1.0.22 → 1.0.31 moved the values of 0x0845…0x0851 up by one
    /// or two numbers and re-laid 0x108E…0x1095). Such values would land in the
    /// wrong settings. A firmware update converts the models already on the
    /// transmitter correctly, so the right source is a backup made on the
    /// firmware that is running.
    public static func sizeProblem(file: BackupFile, info: StorageInfo, allowOlderFirmware: Bool = false) -> String? {
        switch formatRelation(file: file, info: info) {
        case .same:
            return nil
        case let .newerFirmware(f, d):
            return "This backup was saved by firmware \(f), which is newer than the \(d) the transmitter runs, "
                + "and its models are laid out differently. Restoring it is not supported."
        case let .olderFirmware(f, d):
            if allowOlderFirmware { return nil }
            return "This backup was saved by firmware \(f); the transmitter runs \(d), which numbers some settings "
                + "differently. Restoring it would put those values into the wrong settings. Use a backup made on "
                + "\(d) (a firmware update converts the models on the transmitter itself)."
        }
    }

    /// Checks that do not touch the transmitter.
    public static func preflight(file: BackupFile, items: [RestoreItem], deviceProductID: UInt16,
                                 allowSameFamily: Bool) throws {
        guard !items.isEmpty else { throw RadioError.incompatible("Nothing selected to restore.") }
        let problems = file.validate().filter { $0.severity == .error }
        guard problems.isEmpty else {
            throw RadioError.incompatible("The backup file is damaged and will not be written: "
                + problems.map(\.message).joined(separator: "; "))
        }
        switch Products.compatibility(fileProductID: UInt16(truncatingIfNeeded: file.productID),
                                      deviceProductID: deviceProductID) {
        case .same: break
        case .sameFamily:
            guard allowSameFamily else {
                throw RadioError.incompatible("The backup comes from a \(file.productName) but the connected "
                    + "transmitter is a \(Products.name(forProductID: deviceProductID)). They are the same "
                    + "family; confirm explicitly to restore across models.")
            }
        case .incompatible:
            throw RadioError.incompatible("The backup comes from a \(file.productName), which is not compatible "
                + "with the connected \(Products.name(forProductID: deviceProductID)).")
        }
        guard items.allSatisfy({ file.models.indices.contains($0.fileIndex) }) else {
            throw RadioError.incompatible("Selection refers to a model that is not in the backup.")
        }
        guard Set(items.map(\.targetSlot)).count == items.count else {
            throw RadioError.incompatible("Two models are assigned to the same slot.")
        }
    }

    /// Write models from a backup to the transmitter.
    ///
    /// - Parameter includeSystemSettings: also write the transmitter-wide settings
    ///   block. The vendor tool does this only when 20 or more models are imported
    ///   from the same product, and (through what looks like an offset bug) sends
    ///   it shifted by 23 bytes. We send the block exactly as it was read.
    /// - Parameter current: a backup of the transmitter as it is right now (the safety
    ///   copy). Slots that already hold exactly the settings about to be written are
    ///   then left untouched instead of being rewritten with identical data.
    public func restore(file: BackupFile, items: [RestoreItem], includeSystemSettings: Bool = false,
                        allowSameFamily: Bool = false, allowOlderFirmware: Bool = false, verify: Bool = true,
                        current: BackupFile? = nil, progress: ProgressHandler? = nil) throws -> RestoreReport {
        try RadioSession.preflight(file: file, items: items, deviceProductID: productID,
                                   allowSameFamily: allowSameFamily)
        try requireReceiverOff()
        try setMode(.modelTransfer)
        let info = try storageInfo()
        if let problem = RadioSession.sizeProblem(file: file, info: info, allowOlderFirmware: allowOlderFirmware) {
            throw RadioError.incompatible(problem)
        }
        guard items.allSatisfy({ $0.targetSlot >= 0 && $0.targetSlot < info.modelCount }) else {
            throw RadioError.incompatible("Target slot out of range (transmitter has \(info.modelCount) models).")
        }
        if includeSystemSettings {
            guard file.hasSystemBlock else {
                throw RadioError.incompatible("This backup does not contain system settings.")
            }
            guard file.systemSize == info.systemSize else {
                throw RadioError.incompatible("System settings in the backup are \(file.systemSize) bytes but this "
                    + "transmitter uses \(info.systemSize).")
            }
        }

        // Tag each model's records with the slot it is going to. A block read from
        // slot N always carries N, so this is what the transmitter itself would produce;
        // FlySky's tool sends the original tag unchanged, which is only right if the
        // firmware ignores it.
        let prepared = try items.map { try file.models[$0.fileIndex].retargeted(toSlot: $0.targetSlot) }

        // Which of them would change nothing?
        var identical = [Bool](repeating: false, count: items.count)
        if let current {
            for (i, item) in items.enumerated() {
                if let now = current.models.first(where: { Int($0.slot) == item.targetSlot }) {
                    identical[i] = RadioSession.sameSettings(prepared[i].data, now.data)
                }
            }
        }
        if !includeSystemSettings, !identical.contains(false) {
            var untouched = RestoreReport()
            untouched.entries = zip(items, prepared).map {
                .init(name: $1.name, targetSlot: $0.targetSlot, verified: true, differences: 0, skipped: true)
            }
            progress?(1, "Nothing to change")
            return untouched
        }

        try setMode(.modelList)

        // Announce the import. `d` carries the layout version of the incoming data;
        // the firmware compares it with its own and converts older layouts.
        var announce = Data(count: 20)
        let size = UInt32(file.modelSize)
        announce.replaceSubrange(16..<20, with: [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF),
                                                 UInt8((size >> 16) & 0xFF), UInt8((size >> 24) & 0xFF)])
        _ = try link.request(Packet(command: .storageInfo, a: 1, b: file.storageField1, c: file.productID,
                                    d: file.storageField2, payload: announce), what: "announce import") {
            $0.command == Command.storageInfo.rawValue && $0.a == 1
        }
        link.drain()

        var report = RestoreReport()
        report.layoutConverted = file.storageField2 != info.layoutVersion
        if case .olderFirmware = RadioSession.formatRelation(file: file, info: info) { report.crossVersion = true }
        if includeSystemSettings {
            progress?(0, "Writing system settings")
            try writeArea(area: DataArea.global, data: file.systemSettings, what: "system settings", chunkProgress: nil)
            report.systemSettingsWritten = true
        }

        let totalBytes = Double(max(identical.filter { !$0 }.count, 1) * file.modelSize)
        var writtenSoFar = 0
        for (i, item) in items.enumerated() {
            let model = prepared[i]
            if identical[i] {
                report.entries.append(.init(name: model.name, targetSlot: item.targetSlot, verified: true,
                                            differences: 0, skipped: true))
                continue
            }
            let label = "Writing \(model.name) to slot \(item.targetSlot + 1)"
            let done = Double(writtenSoFar * file.modelSize)
            writtenSoFar += 1
            progress?(done / totalBytes * 0.9, label)
            try writeArea(area: DataArea.model(slot: item.targetSlot), data: model.data,
                          what: "model \(item.targetSlot + 1)") { bytes in
                progress?((done + Double(bytes)) / totalBytes * 0.9, label)
            }
            // Name: a = 1, b = slot, c = 0x14, payload = name bytes.
            let name = model.nameBytes.prefix { $0 != 0 }.asData
            try link.send(Packet(command: .modelName, a: 1, b: UInt32(item.targetSlot), c: 0x14, payload: name))
            _ = try link.receive(until: Date().addingTimeInterval(link.timing.requestTimeout)) {
                $0.command == Command.modelName.rawValue
            }
            report.entries.append(.init(name: model.name, targetSlot: item.targetSlot, verified: nil, differences: 0))
        }

        // Commit. Reply b == 1 means "still saving, ask again".
        progress?(0.9, "Saving on the transmitter")
        let deadline = Date().addingTimeInterval(link.timing.commitTimeout)
        var committed = false
        while Date() < deadline {
            let reply = try link.request(Packet(command: .commit), what: "commit")
            if reply.b == 0 { committed = true; break }
            Thread.sleep(forTimeInterval: min(0.2, link.timing.resendInterval))
        }
        guard committed else { throw RadioError.timeout("commit") }

        if verify {
            for (i, item) in items.enumerated() where !identical[i] {
                progress?(0.9 + 0.1 * Double(i) / Double(items.count), "Verifying slot \(item.targetSlot + 1)")
                let readBack = try readModelBlock(slot: item.targetSlot, size: Int(info.modelSize))
                let diff = RadioSession.settingDifferences(written: prepared[i].data, readBack: readBack,
                                                           ignoreMissing: report.crossVersion)
                if report.crossVersion, i == 0 {
                    let (skipped, kept) = RadioSession.settingCoverage(backup: prepared[i].data, transmitter: readBack)
                    report.settingsSkipped = skipped
                    report.settingsKeptFromSlot = kept
                }
                report.entries[i].verified = diff == 0
                report.entries[i].differences = diff
            }
            _ = try? storageInfo()
        }
        progress?(1, "Done")
        return report
    }

    /// True when two model blocks hold exactly the same settings (same set of
    /// settings, same values), whatever slot their records are tagged with.
    public static func sameSettings(_ a: Data, _ b: Data) -> Bool {
        settingDifferences(written: a, readBack: b) == 0 && settingDifferences(written: b, readBack: a) == 0
    }

    /// Number of settings whose value differs, ignoring which slot the records
    /// are tagged with (the tag legitimately changes when restoring to another slot).
    /// Settings only in the backup (skipped on import) and only on the transmitter (kept).
    public static func settingCoverage(backup: Data, transmitter: Data) -> (skipped: Int, kept: Int) {
        guard let a = try? RecordStream.parse(backup), let b = try? RecordStream.parse(transmitter) else { return (0, 0) }
        struct Key: Hashable { let id: UInt16; let element: UInt8 }
        let ka = Set(a.records.map { Key(id: $0.id, element: $0.element) })
        let kb = Set(b.records.map { Key(id: $0.id, element: $0.element) })
        return (ka.subtracting(kb).count, kb.subtracting(ka).count)
    }

    /// - Parameter ignoreMissing: do not count settings the transmitter does not
    ///   have (a backup from older firmware may contain settings that were dropped).
    public static func settingDifferences(written: Data, readBack: Data, ignoreMissing: Bool = false) -> Int {
        guard let a = try? RecordStream.parse(written), let b = try? RecordStream.parse(readBack) else { return Int.max }
        struct Key: Hashable { let id: UInt16; let element: UInt8 }
        var expected: [Key: Data] = [:]
        for r in a.records { expected[Key(id: r.id, element: r.element)] = r.value }
        var actual: [Key: Data] = [:]
        for r in b.records { actual[Key(id: r.id, element: r.element)] = r.value }
        var diff = 0
        // Settings the transmitter has but the backup lacks are not differences:
        // newer firmware simply knows more settings.
        for (k, v) in expected where actual[k] != v {
            if ignoreMissing, actual[k] == nil { continue }
            // 0x0FDB is a text field whose bytes after the terminating NUL are leftovers
            // of the transmitter's export buffer; only the text itself is compared.
            if k.id == 0x0FDB, let other = actual[k], v.prefix(while: { $0 != 0 }) == other.prefix(while: { $0 != 0 }) {
                continue
            }
            diff += 1
        }
        return diff
    }
}
