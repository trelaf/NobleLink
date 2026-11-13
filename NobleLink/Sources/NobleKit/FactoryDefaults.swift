import Foundation

/// What a factory-default model looks like, learned from the transmitter's own data.
///
/// The transmitter always has all of its model slots; a model cannot be deleted,
/// only returned to defaults. There is no USB command for that, so "removing" a
/// model means writing a default model into its slot. The default is taken from
/// slots the user never touched: they are named "Flysky NN" (NN = slot number)
/// and are identical to each other apart from that name.
public struct FactoryDefaults: Sendable {
    /// Settings that differ between untouched slots and are therefore ignored when
    /// deciding whether two default-named models are the same:
    /// * 0x07D1 – the name;
    /// * 0x0FDB – a 32-byte field that, on firmware 1.0.22, comes back filled with
    ///   leftovers of the transmitter's own export buffer (fragments of the name
    ///   record and of check bytes), so it varies with the slot without meaning anything.
    public static let ignoredSettings: Set<UInt16> = [KnownParameter.modelName, 0x0FDB]

    public var productID: UInt32
    public var firmwareVersion: UInt32      // packed, as in the backup header
    public var storageField1: UInt32
    public var storageField3: UInt32
    public var model: BackupFile.Model

    public static func defaultName(slot: Int) -> String { String(format: "Flysky %02d", slot + 1) }

    private struct Key: Hashable { let id: UInt16; let element: UInt8 }

    private static func signature(_ model: BackupFile.Model) -> [Key: Data]? {
        guard let stream = try? model.records(), !stream.records.isEmpty, stream.trailingIsPadding else { return nil }
        var out: [Key: Data] = [:]
        for r in stream.records where !ignoredSettings.contains(r.id) {
            out[Key(id: r.id, element: r.element)] = r.value
        }
        return out
    }

    /// Find the factory default in a backup: at least two models that still carry
    /// their default name and agree on every setting. Returns nil when the backup
    /// does not contain two such models (then nothing can be said with confidence).
    public static func detect(in file: BackupFile) -> FactoryDefaults? {
        let candidates = file.models.filter { $0.name == defaultName(slot: Int($0.slot)) }
        var groups: [(signature: [Key: Data], members: [BackupFile.Model])] = []
        for model in candidates {
            guard let sig = signature(model) else { continue }
            if let i = groups.firstIndex(where: { $0.signature == sig }) {
                groups[i].members.append(model)
            } else {
                groups.append((sig, [model]))
            }
        }
        guard let best = groups.max(by: { $0.members.count < $1.members.count }), best.members.count >= 2,
              let representative = best.members.last else { return nil }
        return FactoryDefaults(productID: file.productID, firmwareVersion: file.storageField2,
                               storageField1: file.storageField1, storageField3: file.storageField3,
                               model: representative)
    }

    /// True when `model` holds exactly the default settings (whatever it is called).
    public func matches(_ model: BackupFile.Model) -> Bool {
        guard let a = FactoryDefaults.signature(self.model), let b = FactoryDefaults.signature(model) else { return false }
        return a == b
    }

    /// A backup file containing default models for the given slots, each with its
    /// default name, ready to be handed to `RadioSession.restore`.
    public func resetFile(slots: [Int]) throws -> (file: BackupFile, items: [RestoreItem]) {
        var models: [BackupFile.Model] = []
        var items: [RestoreItem] = []
        for (i, slot) in slots.enumerated() {
            let fresh = try model.renamed(FactoryDefaults.defaultName(slot: slot)).retargeted(toSlot: slot)
            models.append(fresh)
            items.append(RestoreItem(fileIndex: i, targetSlot: slot))
        }
        let file = BackupFile(productID: productID, storageField1: storageField1, storageField2: firmwareVersion,
                              storageField3: storageField3, systemSize: 0, models: models, systemBlock: Data())
        return (file, items)
    }

    /// Why this template cannot be used on a transmitter, or nil when it can.
    public func problem(deviceProductID: UInt16, info: StorageInfo) -> String? {
        if UInt16(truncatingIfNeeded: productID) != deviceProductID {
            return "The stored default model comes from a different transmitter model."
        }
        if firmwareVersion != info.layoutVersion {
            return "The stored default model was captured on firmware \(PackedVersion.string(firmwareVersion)), "
                + "but the transmitter now runs \(PackedVersion.string(info.layoutVersion))."
        }
        if model.data.count != Int(info.modelSize) {
            return "The stored default model does not match this firmware's model size."
        }
        return nil
    }

    // MARK: Remembering the template

    /// Kept as an ordinary one-model backup file so it can be inspected with the usual tools.
    public func asBackupFile() -> BackupFile {
        BackupFile(productID: productID, storageField1: storageField1, storageField2: firmwareVersion,
                   storageField3: storageField3, systemSize: 0, models: [model], systemBlock: Data())
    }

    public init(productID: UInt32, firmwareVersion: UInt32, storageField1: UInt32, storageField3: UInt32,
                model: BackupFile.Model) {
        self.productID = productID
        self.firmwareVersion = firmwareVersion
        self.storageField1 = storageField1
        self.storageField3 = storageField3
        self.model = model
    }

    public init?(templateFile file: BackupFile) {
        guard file.models.count == 1, let model = file.models.first else { return nil }
        self.init(productID: file.productID, firmwareVersion: file.storageField2,
                  storageField1: file.storageField1, storageField3: file.storageField3, model: model)
    }

    public static func storeDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("NobleLink/DefaultModels", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func storeURL(productID: UInt32, firmwareVersion: UInt32) throws -> URL {
        try storeDirectory().appendingPathComponent(
            String(format: "default_%04X_%@.fsdll", productID, PackedVersion.string(firmwareVersion)))
    }

    /// Remember this template for later (for when every slot is in use).
    public func remember() {
        guard let url = try? FactoryDefaults.storeURL(productID: productID, firmwareVersion: firmwareVersion) else { return }
        try? asBackupFile().write(to: url)
    }

    public static func remembered(productID: UInt32, firmwareVersion: UInt32) -> FactoryDefaults? {
        guard let url = try? storeURL(productID: productID, firmwareVersion: firmwareVersion),
              let file = try? BackupFile(contentsOf: url) else { return nil }
        return FactoryDefaults(templateFile: file)
    }

    /// The template to use for a transmitter whose current contents are `current`:
    /// what its own untouched slots show, else what was remembered for this firmware.
    public static func find(for current: BackupFile, useStore: Bool) -> FactoryDefaults? {
        if let found = detect(in: current) {
            if useStore { found.remember() }
            return found
        }
        return useStore ? remembered(productID: current.productID, firmwareVersion: current.storageField2) : nil
    }
}

extension RadioSession {
    /// Return slots to factory defaults by writing the default model into each.
    /// `current` must be a backup of the transmitter as it is now (it doubles as
    /// the safety copy and as the source of the default model).
    public func resetModels(slots: [Int], current: BackupFile, useStore: Bool = false,
                            progress: ProgressHandler? = nil) throws -> RestoreReport {
        guard let defaults = FactoryDefaults.find(for: current, useStore: useStore) else {
            throw RadioError.incompatible("Cannot tell what a factory-default model looks like on this firmware: "
                + "that is learned from at least two untouched \"Flysky NN\" models, and none were found now or earlier.")
        }
        let (file, items) = try defaults.resetFile(slots: slots)
        return try restore(file: file, items: items, current: current, progress: progress)
    }
}
