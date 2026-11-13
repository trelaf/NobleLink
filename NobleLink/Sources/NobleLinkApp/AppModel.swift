import Foundation
import SwiftUI
import NobleKit

/// Everything the window shows. All radio work happens on one serial queue;
/// published state is only touched on the main thread.
final class AppModel: ObservableObject {
    struct Connection: Equatable {
        var productID: UInt16
        var productName: String
        var detail: String
    }

    struct LoadedBackup {
        var url: URL
        var file: BackupFile
        var issues: [BackupFile.Issue]
    }

    /// One line of the restore plan. The plan has one row per slot on the
    /// transmitter, in order: a row's position *is* the slot it describes.
    struct PlanRow: Identifiable {
        let id: Int
        /// Index of the backup model placed in this slot, or nil for "leave the slot as it is".
        var fileIndex: Int?
        /// Whether that model will actually be written.
        var include: Bool
        /// Name the model will get (editable).
        var name: String
    }

    struct LoadedFirmware {
        var url: URL
        var package: FirmwarePackage
    }

    @Published var connection: Connection?
    @Published var deviceInfo: DeviceInfo?
    @Published var storage: StorageInfo?
    @Published var models: [ModelSlot] = []
    @Published var selectedSlots: Set<Int> = []

    @Published var busy = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var notice: String?

    @Published var backup: LoadedBackup?
    @Published var plan: [PlanRow] = []

    /// The transmitter's full contents as last read in this session (a backup or a
    /// safety copy). Lets the restore plan say which models are already identical.
    @Published var snapshot: BackupFile? { didSet { comparisonCache = [:] } }
    private var comparisonCache: [String: Int] = [:]

    /// How one row of the plan relates to what is on the transmitter now.
    enum RowStatus: Equatable {
        case unknown                    // transmitter not read
        case identical                  // same settings already in that slot
        case alreadyThere               // same model by name and slot; contents not compared
        case updates(Int)               // same model, this many settings differ
        case renames(String)            // same model, new name
        case replaces(String)           // a different model is in that slot
    }
    /// A setting (Settings pane), remembered between launches.
    @Published var restoreSystemSettings = UserDefaults.standard.bool(forKey: "restoreSystemSettings") {
        didSet { UserDefaults.standard.set(restoreSystemSettings, forKey: "restoreSystemSettings") }
    }
    @Published var lastRestore: RestoreReport?

    @Published var firmware: LoadedFirmware?
    @Published var firmwareError: String?

    @Published var releases: [Catalogue.Release] = []
    @Published var catalogueProduct: String?
    @Published var catalogueStatus: String?
    @Published var checkingCatalogue = false
    @Published var catalogueNotes: [String] = []
    /// Index of the release being downloaded, if any.
    @Published var downloadingRelease: Int?

    // View state kept here rather than in @State: the Command Line Tools
    // toolchain cannot expand the SwiftUI @State macro without Xcode.
    @Published var pane: Pane = .transmitter
    @Published var confirmingRestore = false
    @Published var confirmingResetAll = false
    @Published var confirmingResetSelected = false

    // MARK: Firmware installation state

    enum InstallPhase: Equatable {
        case idle
        case safetyBackup
        case waiting(String)          // what is seen while waiting for update mode
        case comparing
        case ready(String)            // summary; waiting for the user to confirm
        case installing
        case finished(String)
        case failed(String)
        case cancelled(String)

        var isActive: Bool {
            switch self {
            case .safetyBackup, .waiting, .comparing, .ready, .installing: return true
            default: return false
            }
        }
    }

    @Published var installPhase: InstallPhase = .idle
    @Published var installRehearsal = false
    @Published var installProgress: Double = 0
    @Published var installStatus = ""
    @Published var confirmingInstall = false
    var installTransport: RadioTransport?
    /// How the installer reaches the transmitter (replaced by simulators in the self-check).
    var openRadio: () -> (RadioTransport, UInt16)? = {
        guard let hid = try? HIDTransport.openFirst() else { return nil }
        return (hid, hid.description.productID)
    }
    /// Where safety copies go (overridden by the self-check).
    static var safetyDirectoryOverride: URL?
    var installUpdater: FirmwareUpdater?
    var installCancelRequested = false
    var installSafetyCopy: URL?

    @Published var traceEnabled = false
    @Published var log: [String] = []

    private let queue = DispatchQueue(label: "NobleLink.radio")
    private var cancelRequested = false
    private var pollTimer: Timer?
    private var lastSeenProduct: UInt16?

    /// The app's model, for the quit guard.
    static weak var current: AppModel?
    private let polling: Bool
    /// Speeds up the wait for update mode in the self-check.
    var waitPollInterval: TimeInterval = 1.5
    /// Timing for normal-mode conversations during installation (instant in the self-check).
    var installLinkTiming = LinkTiming()

    init(polling: Bool = true) {
        self.polling = polling
        AppModel.current = self
        guard polling else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    // MARK: Connection watching

    private func poll() {
        guard polling, !busy else { return }
        queue.async { [weak self] in
            let found = HIDTransport.connectedDevices().first
            DispatchQueue.main.async {
                guard let self, !self.busy else { return }
                if let d = found {
                    let c = Connection(productID: d.productID, productName: d.productName, detail: d.description)
                    if self.connection != c { self.connection = c }
                    if self.lastSeenProduct != d.productID {
                        self.lastSeenProduct = d.productID
                        self.refresh()
                    }
                } else if self.connection != nil {
                    self.connection = nil
                    self.lastSeenProduct = nil
                    self.deviceInfo = nil
                    self.storage = nil
                    self.models = []
                    self.selectedSlots = []
                    self.snapshot = nil
                }
            }
        }
    }

    // MARK: Running radio work

    private func append(log line: String) {
        DispatchQueue.main.async {
            self.log.append(line)
            if self.log.count > 5000 { self.log.removeFirst(self.log.count - 5000) }
        }
    }

    /// Open the transmitter, run `work` off the main thread, publish the outcome.
    private func perform(_ title: String, _ work: @escaping (RadioSession) throws -> Void,
                         completion: @escaping (Error?) -> Void = { _ in }) {
        guard !busy else { return }
        busy = true
        progress = 0
        status = title
        errorMessage = nil
        notice = nil
        cancelRequested = false
        let trace = traceEnabled
        append(log: "— \(title) —")
        queue.async {
            var failure: Error?
            do {
                let transport = try HIDTransport.openFirst()
                let session = RadioSession(transport: transport, productID: transport.description.productID)
                session.link.isCancelled = { self.cancelRequested }
                if trace { session.link.trace = { self.append(log: $0) } }
                defer {
                    session.leave()
                    transport.close()
                }
                try session.hello()
                try work(session)
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                self.busy = false
                self.status = ""
                if let failure {
                    if (failure as? RadioError) != .cancelled { self.errorMessage = "\(failure)" }
                    self.append(log: "! \(failure)")
                }
                completion(failure)
            }
        }
    }

    private func report(_ fraction: Double, _ message: String) {
        DispatchQueue.main.async {
            self.progress = fraction
            self.status = message
        }
    }

    func cancel() { cancelRequested = true }

    // MARK: Actions

    func refresh() {
        perform("Reading transmitter") { session in
            let info = try session.deviceInfo()
            let (storage, models) = try session.listModels(progress: self.report)
            DispatchQueue.main.async {
                self.deviceInfo = info
                self.storage = storage
                self.models = models
                self.selectedSlots = self.selectedSlots.filter { $0 < models.count }
            }
        }
    }

    /// Return slots to factory defaults (`nil` = every slot). The transmitter cannot
    /// delete a model; "removing" one means writing the default model into its slot.
    func resetModels(slots: [Int]?) {
        perform(slots == nil ? "Resetting all models" : "Resetting \(slots!.count) model(s)") { session in
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd_HHmmss"
            let safety = try AppModel.safetyBackupDirectory()
                .appendingPathComponent("before_reset_\(stamp.string(from: Date())).fsdll")
            let current = try session.backup(progress: { f, m in self.report(f * 0.5, "Safety backup – " + m) })
            try current.write(to: safety)
            self.append(log: "Safety backup saved to \(safety.path)")

            let targets = slots ?? Array(current.models.indices)
            let result = try session.resetModels(slots: targets, current: current, useStore: true,
                                                 progress: { f, m in self.report(0.5 + f * 0.5, m) })
            let (storage, models) = try session.listModels()
            DispatchQueue.main.async {
                self.storage = storage
                self.models = models
                self.selectedSlots = []
                self.snapshot = nil
                var text = "Reset \(result.entries.count) model(s) to factory defaults. What was there before is saved in "
                    + "\(safety.path)."
                if !result.allVerified { text += " Some settings read back differently – check the transmitter." }
                self.notice = text
            }
        }
    }

    func backUp(slots: [Int]?, to url: URL) {
        perform(slots == nil ? "Backing up all models" : "Backing up \(slots!.count) model(s)") { session in
            let file = try session.backup(slots: slots, progress: self.report)
            try file.write(to: url)
            // Remember what a factory-default model looks like on this firmware, for Reset.
            _ = FactoryDefaults.find(for: file, useStore: true)
            if slots == nil { DispatchQueue.main.async { self.snapshot = file } }
            let summary = "Saved \(file.models.count) model(s)"
                + (file.hasSystemBlock ? " and system settings" : "") + " to \(url.lastPathComponent)."
            DispatchQueue.main.async { self.notice = summary }
        }
    }

    func openBackup(_ url: URL) {
        do {
            let file = try BackupFile(contentsOf: url)
            backup = LoadedBackup(url: url, file: file, issues: file.validate())
            resetPlan()
            lastRestore = nil
            errorMessage = nil
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent): \(error)"
        }
    }

    // MARK: Restore plan

    private var slotCount: Int { max(storage?.modelCount ?? 0, backup?.file.models.count ?? 0, 25) }

    /// Every model back in the slot it was saved from, with its saved name.
    func resetPlan() {
        guard let file = backup?.file else { plan = []; return }
        var rows = (0..<slotCount).map { PlanRow(id: $0, fileIndex: nil, include: false, name: "") }
        var homeless: [Int] = []
        for (index, model) in file.models.enumerated() {
            let slot = Int(model.slot)
            if rows.indices.contains(slot), rows[slot].fileIndex == nil {
                rows[slot] = PlanRow(id: slot, fileIndex: index, include: true, name: model.name)
            } else {
                homeless.append(index)
            }
        }
        for index in homeless {
            if let free = rows.firstIndex(where: { $0.fileIndex == nil }) {
                rows[free] = PlanRow(id: rows[free].id, fileIndex: index, include: true, name: file.models[index].name)
            }
        }
        plan = rows
    }

    /// True when the plan is the backup exactly as saved: every model ticked, in
    /// the slot it was saved from, under its saved name.
    var planMatchesBackup: Bool {
        guard let file = backup?.file else { return false }
        var seen = 0
        for (slot, row) in plan.enumerated() {
            guard let index = row.fileIndex else { continue }
            seen += 1
            if !row.include || Int(file.models[index].slot) != slot || isRenamed(row) { return false }
        }
        return seen == file.models.count
    }

    /// What differs from the backup as saved, for display.
    var planChanges: String {
        guard let file = backup?.file else { return "" }
        var moved = 0, renamed = 0, skipped = 0
        for (slot, row) in plan.enumerated() {
            guard let index = row.fileIndex else { continue }
            if !row.include { skipped += 1; continue }
            if Int(file.models[index].slot) != slot { moved += 1 }
            if isRenamed(row) { renamed += 1 }
        }
        var parts: [String] = []
        if moved > 0 { parts.append("\(moved) moved") }
        if renamed > 0 { parts.append("\(renamed) renamed") }
        if skipped > 0 { parts.append("\(skipped) left out") }
        return parts.joined(separator: ", ")
    }

    func movePlanRows(from source: IndexSet, to destination: Int) {
        plan.move(fromOffsets: source, toOffset: destination)
    }

    /// Ticked models first, in their current order – "put these in slots 1, 2, 3…".
    func moveTickedToTop() {
        plan = plan.filter { $0.include && $0.fileIndex != nil } + plan.filter { !($0.include && $0.fileIndex != nil) }
    }

    func setAllIncluded(_ on: Bool) {
        for i in plan.indices where plan[i].fileIndex != nil { plan[i].include = on }
    }

    func resetNames() {
        guard let file = backup?.file else { return }
        for i in plan.indices {
            if let index = plan[i].fileIndex { plan[i].name = file.models[index].name }
        }
    }

    /// Name currently stored on the transmitter in a slot, if known.
    func currentName(slot: Int) -> String? {
        models.first { $0.slot == slot }.map { $0.name.isEmpty ? "(unnamed)" : $0.name }
    }

    /// The name as it will be stored: what was typed, without stray spaces at either end.
    func effectiveName(_ row: PlanRow) -> String { row.name.trimmingCharacters(in: .whitespaces) }

    func status(slot: Int, row: PlanRow) -> RowStatus {
        guard let index = row.fileIndex, let file = backup?.file else { return .unknown }
        let original = file.models[index]
        let newName = effectiveName(row)
        let sameSlot = Int(original.slot) == slot
        guard let current = models.first(where: { $0.slot == slot })?.name else { return .unknown }

        // With a snapshot of the transmitter, compare the actual settings.
        if let now = snapshot?.models.first(where: { Int($0.slot) == slot }), now.name == current,
           now.data.count == original.data.count {
            let key = "\(index)|\(slot)|\(newName)"
            let differences: Int
            if let cached = comparisonCache[key] {
                differences = cached
            } else {
                var candidate = original
                if isRenamed(row), BackupFile.Model.nameProblem(newName) == nil,
                   let renamed = try? original.renamed(newName) { candidate = renamed }
                differences = max(RadioSession.settingDifferences(written: candidate.data, readBack: now.data),
                                  RadioSession.settingDifferences(written: now.data, readBack: candidate.data))
                comparisonCache[key] = differences
            }
            if differences == 0 { return .identical }
            if sameSlot && current == original.name {
                return isRenamed(row) && differences == 1 ? .renames(current) : .updates(differences)
            }
            return .replaces(current)
        }

        // Without one, only names are known.
        if sameSlot && current == original.name {
            return isRenamed(row) ? .renames(current) : .alreadyThere
        }
        return .replaces(current)
    }

    func isRenamed(_ row: PlanRow) -> Bool {
        guard let index = row.fileIndex, let file = backup?.file else { return false }
        return effectiveName(row) != file.models[index].name
    }

    var restoreItems: [RestoreItem] {
        plan.enumerated().compactMap { slot, row in
            guard row.include, let index = row.fileIndex else { return nil }
            return RestoreItem(fileIndex: index, targetSlot: slot)
        }
    }

    /// The backup with the edited names applied to the models that will be restored.
    func editedFile() throws -> BackupFile {
        guard var file = backup?.file else { throw RadioError.incompatible("Open a backup file first.") }
        for row in plan where row.include {
            guard let index = row.fileIndex, isRenamed(row) else { continue }
            file.models[index] = try file.models[index].renamed(effectiveName(row))
        }
        return file
    }

    /// Reasons the current plan cannot be restored, or nil when it can.
    var restoreBlocker: String? {
        guard backup != nil else { return "Open a backup file first." }
        for (slot, row) in plan.enumerated() where row.include && row.fileIndex != nil {
            if isRenamed(row), let problem = BackupFile.Model.nameProblem(effectiveName(row)) {
                return "Slot \(slot + 1): \(problem)"
            }
        }
        guard let connection else { return "Connect the transmitter." }
        if let storage, let file = backup?.file, let problem = RadioSession.sizeProblem(file: file, info: storage) {
            return problem
        }
        do {
            try RadioSession.preflight(file: try editedFile(), items: restoreItems,
                                       deviceProductID: connection.productID, allowSameFamily: false)
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// Write the plan as a new backup file: every model from the backup, with the
    /// edited names, tagged with the slot it has been placed in, in slot order.
    func saveArrangedCopy(to url: URL) {
        do {
            guard var file = backup?.file else { return }
            var arranged: [BackupFile.Model] = []
            for (slot, row) in plan.enumerated() {
                guard let index = row.fileIndex else { continue }
                var model = file.models[index]
                if isRenamed(row) { model = try model.renamed(effectiveName(row)) }
                arranged.append(try model.retargeted(toSlot: slot))
            }
            file.models = arranged
            try file.write(to: url)
            notice = "Saved the arranged backup to \(url.lastPathComponent). The original file is unchanged."
        } catch {
            errorMessage = "Could not save: \(error)"
        }
    }

    /// Exercises the plan logic without a window or a transmitter. Returns true when every check holds.
    static func planSelfCheck(backupPath: String) -> Bool {
        var ok = true
        func check(_ condition: Bool, _ what: String) {
            print((condition ? "ok    " : "FAIL  ") + what)
            if !condition { ok = false }
        }
        let m = AppModel(polling: false)
        m.openBackup(URL(fileURLWithPath: backupPath))
        guard let file = m.backup?.file else { print("FAIL  could not open \(backupPath)"); return false }
        check(m.plan.count >= file.models.count, "one row per slot (\(m.plan.count))")
        check(m.restoreItems.count == file.models.count, "everything ticked initially")
        check(m.restoreItems.allSatisfy { Int(file.models[$0.fileIndex].slot) == $0.targetSlot }, "models start in their own slots")
        check(m.planMatchesBackup, "as opened, the plan is the backup exactly as saved")
        check((try? m.editedFile())?.serialized() == file.serialized(), "…and what would be sent is the backup, byte for byte")

        // Row wording. Pretend the transmitter currently holds exactly this backup.
        m.models = file.models.map { ModelSlot(slot: Int($0.slot), name: $0.name, nameBytes: Data($0.name.utf8), nameField: 14) }
        check(m.status(slot: 0, row: m.plan[0]) == .alreadyThere, "names only: a model going to its own slot is 'already in this slot'")
        m.snapshot = file
        check(m.plan.enumerated().allSatisfy { m.status(slot: $0.offset, row: $0.element) == .identical },
              "with the transmitter read: every unchanged model is 'already on the transmitter'")
        let savedName = m.plan[0].name
        m.plan[0].name = "Other Name"
        check(m.status(slot: 0, row: m.plan[0]) == .renames(savedName), "a renamed model 'renames' what is there")
        m.plan[0].name = savedName
        m.movePlanRows(from: IndexSet(integer: 0), to: 2)
        if case .replaces = m.status(slot: 0, row: m.plan[0]) { check(true, "a different model in a slot 'replaces' it") }
        else { check(false, "a different model in a slot 'replaces' it") }
        var changed = file
        if var stream = try? changed.models[3].records(), stream.records.count > 8 {
            stream.records[8].value = Data(stream.records[8].value.map { $0 ^ 0x01 })
            changed.models[3].data = stream.encoded()
            m.snapshot = changed
            check(m.status(slot: 3, row: m.plan[3]) == .updates(1), "a model edited on the transmitter since the backup shows '1 setting differs'")
        }
        m.snapshot = nil
        m.models = []
        m.resetPlan()

        // Untick all but two, move them to the top, rename one.
        m.setAllIncluded(false)
        let a = min(9, file.models.count - 1), b = min(1, file.models.count - 1)
        for i in m.plan.indices where m.plan[i].fileIndex == a || m.plan[i].fileIndex == b { m.plan[i].include = true }
        m.moveTickedToTop()
        check(m.restoreItems.map(\.targetSlot) == Array(0..<m.restoreItems.count), "ticked models move to slots 1, 2, …")
        check(Set(m.plan.compactMap(\.fileIndex)).count == file.models.count, "no model is lost or duplicated by moving")
        m.movePlanRows(from: IndexSet(integer: 0), to: 2)
        check(m.restoreItems.count == 2 && Set(m.restoreItems.map(\.targetSlot)) == [0, 1], "dragging swaps the first two slots")
        m.plan[0].name = BackupFile.Model.sanitizedName("Renamed Model With Long Name")
        check(m.plan[0].name.utf8.count == BackupFile.Model.maxNameLength, "typed names are cut to 14 characters")
        let edited = try? m.editedFile()
        check(edited != nil && edited!.validate().filter { $0.severity == .error }.isEmpty, "edited backup validates")
        if let edited, let index = m.plan[0].fileIndex {
            check(edited.models[index].name == "Renamed Model", "edited name is applied, without the stray space")
            check(((try? edited.models[index].records())?.records.first { $0.id == KnownParameter.modelName }?.stringValue)
                  == "Renamed Model", "…including the name record inside the model data")
        }
        m.plan[0].name = ""
        check(m.restoreBlocker?.contains("empty") == true, "an empty name blocks the restore")
        m.resetNames()

        // End to end against the simulated transmitter.
        if let edited = try? m.editedFile() {
            // A blank simulated transmitter with the same storage layout as the backup.
            let mock = MockRadio(productID: UInt16(truncatingIfNeeded: file.productID), modelCount: 25,
                                 modelSize: file.modelSize, systemSize: max(Int(file.systemSize), 64))
            let session = RadioSession(transport: mock, productID: mock.productID, timing: .instant)
            let report = try? session.restore(file: edited, items: m.restoreItems)
            check(report?.allVerified == true, "plan restores and verifies on the simulated transmitter")
            for item in m.restoreItems {
                check(mock.names[item.targetSlot] == Data(file.models[item.fileIndex].name.utf8),
                      "slot \(item.targetSlot + 1) now holds \(file.models[item.fileIndex].name)")
            }
        }

        // Arranged copy.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("noblelink_plan_check.fsdll")
        m.saveArrangedCopy(to: out)
        if let arranged = try? BackupFile(contentsOf: out) {
            check(arranged.models.count == file.models.count && arranged.validate().isEmpty, "arranged copy is a valid backup")
            check(arranged.models.map { Int($0.slot) } == arranged.models.map { Int($0.slot) }.sorted(), "…in slot order")
        } else {
            check(false, "arranged copy could be written and read")
        }
        try? FileManager.default.removeItem(at: out)
        check(!m.planMatchesBackup && !m.planChanges.isEmpty, "changes are reported (\(m.planChanges))")
        m.resetPlan()
        check(m.planMatchesBackup, "Revert to Backup restores the plan as saved")
        return ok
    }

    /// Drives the installer end to end against a simulated transmitter and
    /// bootloader – no window, no USB. Returns true when every check holds.
    static func installSelfCheck(newUpdater: String, oldUpdater: String) -> Bool {
        var ok = true
        func check(_ condition: Bool, _ what: String) {
            print((condition ? "ok    " : "FAIL  ") + what)
            if !condition { ok = false }
        }
        guard let new = try? FirmwarePackage.load(url: URL(fileURLWithPath: newUpdater)),
              let old = try? FirmwarePackage.load(url: URL(fileURLWithPath: oldUpdater)),
              let oldResource = old.resource, let newResource = new.resource else {
            print("FAIL  could not load the updater files"); return false
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("noblelink_install_check_\(UUID().uuidString)")
        safetyDirectoryOverride = tmp
        defer { try? FileManager.default.removeItem(at: tmp); safetyDirectoryOverride = nil }

        func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return condition()
        }

        /// A transmitter that runs its normal firmware for `normalOpens` connections
        /// and then shows up as `boot`.
        func scenario(productID: UInt16 = 0x8D09, normalOpens: Int, boot: MockBootloader) -> AppModel {
            let m = AppModel(polling: false)
            m.waitPollInterval = 0.05
            m.installLinkTiming = .instant
            m.connection = Connection(productID: productID, productName: Products.name(forProductID: productID), detail: "simulated")
            m.deviceInfo = DeviceInfo(productID: productID, productName: Products.name(forProductID: productID), uniqueID: "",
                                      firmwareVersion: "1.0.22", bootVersion: nil, versionBlock: Data())
            m.firmware = LoadedFirmware(url: URL(fileURLWithPath: newUpdater), package: new)
            var opens = 0
            m.openRadio = {
                opens += 1
                if opens <= normalOpens { let r = MockRadio(productID: productID); return (r, productID) }
                return (boot, productID)
            }
            return m
        }

        // A. Rehearsal: compares, restarts, writes nothing.
        do {
            let boot = MockBootloader(flashContents: oldResource)
            let m = scenario(normalOpens: 2, boot: boot)
            check(m.installBlocker == nil, "rehearsal: nothing blocks installing 1.0.31 over 1.0.22")
            m.startInstall(rehearsal: true)
            let done = waitUntil(30) { if case .finished = m.installPhase { return true }; return false }
            check(done, "rehearsal finishes (\(m.installPhase))")
            check(boot.resetSeen && boot.appErasedFor == nil && boot.eraseLog.isEmpty && boot.flashWrites == 0,
                  "rehearsal restarts the transmitter and erases or writes nothing")
            check(((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).isEmpty, "rehearsal makes no safety copy")
            check(!m.busy, "app is idle again")
        }

        // B. Full installation.
        do {
            let boot = MockBootloader(flashContents: oldResource)
            let m = scenario(normalOpens: 3, boot: boot)
            m.startInstall(rehearsal: false)
            let ready = waitUntil(60) { if case .ready = m.installPhase { return true }; return false }
            check(ready, "install: reaches the confirmation step (\(m.installPhase))")
            check(boot.appErasedFor == nil && boot.flashWrites == 0, "…without having erased or written anything")
            check(m.busy, "…and the app stays busy (no polling) while the bootloader is open")
            let copies = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
            check(copies.count == 1 && (try? BackupFile(contentsOf: copies[0]))?.validate().isEmpty == true,
                  "a valid safety copy of all models was saved first")
            m.confirmInstall()
            let finished = waitUntil(120) { if case .finished = m.installPhase { return true }; return false }
            check(finished, "install finishes (\(m.installPhase))")
            check(boot.app == new.firmware.data, "firmware written intact")
            check(boot.flash.prefix(newResource.count) == newResource, "resources written intact")
            check(boot.resetSeen && boot.requests.last?.command == Command.reset.rawValue, "restart sent last")
            check(!m.busy && m.installTransport == nil, "app is idle again and has released the transmitter")
        }

        // C. Declining at the confirmation step.
        do {
            let boot = MockBootloader(flashContents: oldResource)
            let m = scenario(normalOpens: 1, boot: boot)
            m.startInstall(rehearsal: false)
            _ = waitUntil(60) { if case .ready = m.installPhase { return true }; return false }
            m.cancelInstall()
            let cancelled = waitUntil(10) { if case .cancelled = m.installPhase { return true }; return false }
            check(cancelled && boot.resetSeen && boot.appErasedFor == nil && boot.flashWrites == 0,
                  "cancelling at the confirmation step restarts the transmitter and changes nothing")
        }

        // D. Firmware for another model is refused before anything happens.
        do {
            let boot = MockBootloader(flashContents: oldResource)
            let m = scenario(productID: 0x8D0A, normalOpens: 1, boot: boot)
            check(m.installBlocker?.contains("built for") == true, "the screen refuses EN firmware for an EU transmitter")
            m.startInstall(rehearsal: false)
            let failed = waitUntil(10) { if case .failed = m.installPhase { return true }; return false }
            check(failed && boot.requests.isEmpty, "…and so does the installer itself, before contacting the bootloader")
        }

        // E. Cancelling while waiting for update mode.
        do {
            let boot = MockBootloader(flashContents: oldResource)
            let m = scenario(normalOpens: 1_000_000, boot: boot)
            m.waitPollInterval = 0.2
            m.startInstall(rehearsal: true)
            _ = waitUntil(10) { if case .waiting = m.installPhase { return true }; return false }
            m.cancelInstall()
            let cancelled = waitUntil(10) { if case .cancelled = m.installPhase { return true }; return false }
            check(cancelled && boot.requests.isEmpty && !m.busy, "cancelling while waiting stops cleanly")
        }
        return ok
    }

    static func safetyBackupDirectory() throws -> URL {
        if let dir = safetyDirectoryOverride {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("NobleLink/SafetyBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func restore() {
        guard backup != nil, let file = try? editedFile() else { return }
        let items = restoreItems
        let includeSystem = restoreSystemSettings
        perform("Restoring \(items.count) model(s)") { session in
            // Always keep a copy of what is about to be overwritten.
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd_HHmmss"
            let safety = try AppModel.safetyBackupDirectory()
                .appendingPathComponent("before_restore_\(stamp.string(from: Date())).fsdll")
            let current = try session.backup(progress: { f, m in self.report(f * 0.4, "Safety backup – " + m) })
            try current.write(to: safety)
            self.append(log: "Safety backup saved to \(safety.path)")

            let result = try session.restore(file: file, items: items, includeSystemSettings: includeSystem,
                                             current: current,
                                             progress: { f, m in self.report(0.4 + f * 0.6, m) })
            let (storage, models) = try session.listModels()
            DispatchQueue.main.async {
                self.lastRestore = result
                self.storage = storage
                self.models = models
                // The safety copy is the transmitter's contents only if nothing was written.
                self.snapshot = result.writtenCount == 0 && !result.systemSettingsWritten ? current : nil
                var text: String
                if result.writtenCount == 0 && !result.systemSettingsWritten {
                    text = "Nothing needed changing: all \(result.skippedCount) model(s) are already identical on the transmitter."
                } else {
                    text = "Restored \(result.writtenCount) model(s)."
                    if result.skippedCount > 0 {
                        text += " \(result.skippedCount) were already identical and left untouched."
                    }
                    text += " A safety copy of the previous state is in \(safety.deletingLastPathComponent().path)."
                    if result.crossVersion {
                        text += " The backup came from older firmware: per model, \(result.settingsSkipped) setting(s) "
                            + "it no longer has were skipped and \(result.settingsKeptFromSlot) new one(s) kept their values."
                    }
                }
                if !result.allVerified {
                    text += result.layoutConverted
                        ? " Some settings read back differently; the backup was saved by different firmware, which the transmitter may convert, so check the models."
                        : " Some settings read back differently – check the models before use."
                }
                self.notice = text
            }
        }
    }

    func openFirmware(_ url: URL) {
        do {
            firmware = LoadedFirmware(url: url, package: try FirmwarePackage.load(url: url))
            firmwareError = nil
        } catch {
            firmware = nil
            firmwareError = "\(error)"
        }
    }

    /// Product to look up when asking FlySky's catalogue.
    var productForCatalogue: String {
        connection?.productName ?? backup?.file.productName ?? "Noble plus EN"
    }

    /// Ask FlySky which firmware it publishes. Only runs when the user asks.
    func checkCatalogue() {
        guard !checkingCatalogue else { return }
        let product = productForCatalogue
        let installed = deviceInfo?.firmwareVersion
        checkingCatalogue = true
        catalogueStatus = "Asking FlySky…"
        catalogueNotes = []
        DispatchQueue.global(qos: .userInitiated).async {
            let listing = Catalogue.fetchAll(productName: product)
            DispatchQueue.main.async {
                self.checkingCatalogue = false
                self.catalogueProduct = product
                self.releases = listing.releases
                self.catalogueNotes = listing.failures.map { "\($0.0.rawValue) could not be read: \($0.1)" }
                if let newest = listing.newestVersion {
                    if let installed, let c = Catalogue.compare(newest, installed) {
                        self.catalogueStatus = c > 0
                            ? "Version \(newest) is available; the transmitter runs \(installed)."
                            : c == 0 ? "The transmitter is up to date (\(installed))."
                            : "The transmitter runs \(installed), newer than anything FlySky lists."
                    } else {
                        self.catalogueStatus = "Newest firmware for \(product): \(newest)."
                    }
                } else {
                    self.catalogueStatus = listing.releases.isEmpty
                        ? "No firmware could be found for \(product)." : "No version information found."
                }
            }
        }
    }

    /// Download a website release (Windows updater .exe) to ~/Downloads, verify it
    /// and open it in the "Firmware file" box.
    func downloadRelease(_ release: Catalogue.Release) {
        guard downloadingRelease == nil else { return }
        downloadingRelease = release.index
        firmwareError = nil
        let product = productForCatalogue
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { () -> URL in
                let (data, pkg) = try Catalogue.downloadUpdater(release)
                guard pkg.firmware.isValid, pkg.firmware.version == release.version else {
                    throw RadioError.corruptData("the downloaded file does not contain a valid firmware \(release.version ?? "")")
                }
                let dir = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
                let url = dir.appendingPathComponent(Catalogue.suggestedFileName(release, product: product))
                try data.write(to: url, options: .atomic)
                return url
            }
            DispatchQueue.main.async {
                self.downloadingRelease = nil
                switch outcome {
                case let .success(url):
                    self.openFirmware(url)
                    self.notice = "Downloaded firmware \(release.title) to \(url.path). Its contents check out."
                case let .failure(error):
                    self.firmwareError = "Download failed: \(error)"
                }
            }
        }
    }

    // MARK: Installing firmware

    /// Why the open firmware file cannot be installed, or nil.
    var installBlocker: String? {
        guard let fw = firmware else { return "Open or download a firmware file first." }
        let pkg = fw.package
        guard pkg.firmware.isValid else { return "This firmware file failed its integrity checks." }
        guard pkg.resource != nil else {
            return "This file holds only the firmware; installing needs FlySky's updater (.exe), which also carries the resource image."
        }
        guard let connection else { return "Connect the transmitter by USB and switch it on." }
        if pkg.isBuilt(for: connection.productName) == false {
            return "This firmware is built for \(pkg.builtFor ?? "another transmitter"), not the connected \(connection.productName)."
        }
        if let cmp = compareFirmwareToInstalled(), cmp < 0 {
            return "This firmware is older than the installed one. Going back is not offered here "
                + "(FlySky: on hardware 1.2, 1.0.31 cannot be downgraded to 1.0.22 or below)."
        }
        return nil
    }

    private func setInstall(_ phase: InstallPhase, _ status: String? = nil, progress: Double? = nil) {
        DispatchQueue.main.async {
            self.installPhase = phase
            if let status { self.installStatus = status }
            if let progress { self.installProgress = progress }
            if !phase.isActive { self.busy = false }
        }
    }

    /// Start a rehearsal (read-only) or an installation. Both begin the same way:
    /// optional safety backup, wait for update mode, compare.
    func startInstall(rehearsal: Bool) {
        guard !busy, !installPhase.isActive, let fw = firmware else { return }
        busy = true
        errorMessage = nil
        notice = nil
        installRehearsal = rehearsal
        installCancelRequested = false
        installSafetyCopy = nil
        installProgress = 0
        let pkg = fw.package
        let trace = traceEnabled
        append(log: rehearsal ? "— Firmware rehearsal (\(pkg.firmware.version ?? "?")) —"
                              : "— Firmware installation (\(pkg.firmware.version ?? "?")) —")
        queue.async {
            // 1. If the transmitter is running normally, check it and (for a real
            //    installation) keep a copy of everything on it.
            if let (hid, productID) = self.openRadio() {
                let session = RadioSession(transport: hid, productID: productID, timing: self.installLinkTiming)
                if trace { session.link.trace = { self.append(log: $0) } }
                if let info = try? session.deviceInfo(), (try? session.storageInfo()) != nil {
                    if pkg.isBuilt(for: info.productName) == false {
                        session.leave(); hid.close()
                        self.setInstall(.failed("This firmware is built for \(pkg.builtFor ?? "another transmitter"), "
                            + "not the connected \(info.productName). Nothing was changed."))
                        return
                    }
                    if !rehearsal {
                        self.setInstall(.safetyBackup, "Saving all models first (an update can reset them)", progress: 0)
                        do {
                            let stamp = DateFormatter()
                            stamp.dateFormat = "yyyy-MM-dd_HHmmss"
                            let url = try AppModel.safetyBackupDirectory()
                                .appendingPathComponent("before_firmware_\(stamp.string(from: Date())).fsdll")
                            let copy = try session.backup(progress: { f, m in
                                self.setInstall(.safetyBackup, "Safety backup – " + m, progress: f)
                            })
                            try copy.write(to: url)
                            self.installSafetyCopy = url
                            self.append(log: "Safety backup saved to \(url.path)")
                        } catch {
                            session.leave(); hid.close()
                            self.setInstall(.failed("The safety backup failed, so nothing else was done: \(error)"))
                            return
                        }
                    }
                    session.leave()
                }
                hid.close()
            }

            // 2. Wait for the bootloader.
            self.setInstall(.waiting(UpdateMode.describe(.noDevice)), UpdateMode.instruction, progress: 0)
            let found = UpdateMode.waitForBootloader(
                timeout: 300,
                pollInterval: self.waitPollInterval,
                open: { self.openRadio()?.0 },
                trace: trace ? { self.append(log: $0) } : nil,
                isCancelled: { self.installCancelRequested },
                status: { seen, _ in self.setInstall(.waiting(UpdateMode.describe(seen)), UpdateMode.instruction) })
            guard let hid = found else {
                self.setInstall(self.installCancelRequested
                    ? .cancelled("Cancelled before anything was changed.")
                    : .failed("The transmitter did not enter update mode within 5 minutes. Nothing was changed."))
                return
            }
            self.append(log: "Update mode detected: \((hid as? HIDTransport)?.description.description ?? "transmitter")")

            // 3. Compare (read-only).
            let session = BootloaderSession(transport: hid)
            if trace { session.trace = { self.append(log: $0) } }
            session.isCancelled = { self.installCancelRequested }
            let updater = FirmwareUpdater(session: session)
            self.setInstall(.comparing, "Comparing the transmitter with the new firmware", progress: 0)
            do {
                let probe = try updater.probe(package: pkg, progress: { f, m in self.setInstall(.comparing, m, progress: f) })
                let summary = "Bootloader \(probe.identity.bootloaderVersion), installed firmware "
                    + "\(probe.identity.firmwareVersion ?? "none"). \(probe.differingBlocks.count) of "
                    + "\(probe.imageBlockCRCs.count) resource blocks will be rewritten."
                self.append(log: summary)
                guard probe.identity.bootloaderWord <= BootloaderSession.newestKnownBootloader else {
                    updater.restart(); hid.close()
                    self.setInstall(.failed("This transmitter's bootloader (\(probe.identity.bootloaderVersion)) is newer than "
                        + "the update procedure knows. Nothing was changed; the transmitter was restarted."))
                    return
                }
                if rehearsal {
                    updater.restart(); hid.close()
                    self.setInstall(.finished("Rehearsal complete – nothing was changed. \(summary) "
                        + "The transmitter has been restarted into its normal firmware."))
                    self.refreshSoon()
                    return
                }
                self.installTransport = hid
                self.installUpdater = updater
                self.setInstall(.ready(summary))
            } catch {
                updater.restart(); hid.close()
                self.setInstall(self.installCancelRequested
                    ? .cancelled("Cancelled – nothing was changed; the transmitter was restarted.")
                    : .failed("Could not compare with the transmitter: \(error). Nothing was changed; it was restarted."))
            }
        }
    }

    /// The user confirmed: erase and write.
    func confirmInstall() {
        guard case .ready = installPhase, let updater = installUpdater, let hid = installTransport,
              let pkg = firmware?.package else { return }
        installPhase = .installing
        installProgress = 0
        let version = pkg.firmware.version ?? "?"
        queue.async {
            do {
                try updater.run(package: pkg, progress: { f, m in self.setInstall(.installing, m, progress: f) })
                hid.close()
                self.installTransport = nil
                self.installUpdater = nil
                var text = "Firmware \(version) is installed and verified; the transmitter is restarting. "
                    + "Check the models, calibrate the sticks, and make a fresh backup."
                if let copy = self.installSafetyCopy { text += " The models from before are saved in \(copy.lastPathComponent)." }
                self.setInstall(.finished(text), progress: 1)
                self.refreshSoon()
            } catch {
                hid.close()
                self.installTransport = nil
                self.installUpdater = nil
                self.setInstall(.failed("The installation did not complete: \(error). The transmitter's bootloader is "
                    + "not affected by an update, so it stays in update mode: leave it connected and press Install again."))
            }
        }
    }

    /// Cancel while waiting, or decline at the confirmation step.
    func cancelInstall() {
        switch installPhase {
        case .waiting, .comparing, .safetyBackup:
            installCancelRequested = true
        case .ready:
            let updater = installUpdater, hid = installTransport
            installTransport = nil
            installUpdater = nil
            queue.async {
                updater?.restart()
                hid?.close()
                self.setInstall(.cancelled("Cancelled – nothing was changed. The transmitter has been restarted into its normal firmware."))
                self.refreshSoon()
            }
        default:
            break
        }
    }

    func dismissInstall() {
        if !installPhase.isActive { installPhase = .idle }
    }

    /// After the transmitter restarts, read it again.
    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            self.lastSeenProduct = nil
            self.deviceInfo = nil
            self.snapshot = nil
            self.poll()
        }
    }

    /// -1 older, 0 same, 1 newer than what is installed; nil if unknown.
    func compareFirmwareToInstalled() -> Int? {
        guard let file = firmware?.package.firmware.version, let installed = deviceInfo?.firmwareVersion else { return nil }
        let a = file.split(separator: ".").compactMap { Int($0) }
        let b = installed.split(separator: ".").compactMap { Int($0) }
        guard a.count == 3, b.count == 3 else { return nil }
        for (x, y) in zip(a, b) where x != y { return x > y ? 1 : -1 }
        return 0
    }
}
