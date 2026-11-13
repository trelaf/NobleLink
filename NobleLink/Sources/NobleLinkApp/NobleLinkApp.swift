import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NobleKit

/// Refuses to quit while firmware is being written.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppModel.current, model.installPhase.isActive else { return .terminateNow }
        let alert = NSAlert()
        if model.installPhase == .installing {
            alert.messageText = "Firmware is being written"
            alert.informativeText = "Quitting now would leave the transmitter without working firmware until "
                + "the update is run again. Wait until it finishes."
            alert.addButton(withTitle: "Keep Running")
            alert.runModal()
            return .terminateCancel
        }
        alert.messageText = "A firmware update is in progress"
        alert.informativeText = "Nothing has been written yet. Quit anyway? The transmitter may stay in update mode "
            + "until it is switched off and on."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main
struct NobleLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        // Headless check of the restore-plan logic, used by scripts/check_app_logic.sh:
        //   NOBLELINK_PLAN_CHECK=/path/to/backup.fsdll NobleLink
        if let path = ProcessInfo.processInfo.environment["NOBLELINK_PLAN_CHECK"] {
            exit(AppModel.planSelfCheck(backupPath: path) ? 0 : 1)
        }
        // NOBLELINK_INSTALL_CHECK="new-updater.exe:old-updater.exe" NobleLink
        if let spec = ProcessInfo.processInfo.environment["NOBLELINK_INSTALL_CHECK"] {
            let parts = spec.split(separator: ":").map(String.init)
            exit(parts.count == 2 && AppModel.installSelfCheck(newUpdater: parts[0], oldUpdater: parts[1]) ? 0 : 1)
        }
    }

    var body: some Scene {
        // A single window: opening a backup file must not spawn a second one.
        Window("NobleLink", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 600)
                // Opening a .fsdll with the app (Finder, or `open -a NobleLink file.fsdll`).
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    model.openBackup(url)
                    model.pane = .restore
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case transmitter = "Transmitter"
    case restore = "Restore"
    case firmware = "Firmware"
    case settings = "Settings"
    case log = "Log"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            StatusHeader()
            Divider()
            Picker("", selection: $model.pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Group {
                switch model.pane {
                case .transmitter: TransmitterPane()
                case .restore: RestorePane()
                case .firmware: FirmwarePane()
                case .settings: SettingsPane()
                case .log: LogPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if (model.busy && !model.installPhase.isActive) || model.errorMessage != nil || model.notice != nil {
                Divider()
                ActivityFooter()
            }
        }
    }
}

// MARK: - Header and footer

struct StatusHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(model.connection == nil ? Color.secondary.opacity(0.4) : Color.green)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.connection?.productName ?? "No transmitter connected")
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.connection == nil || model.busy)
        }
        .padding(16)
    }

    private var subtitle: String {
        guard model.connection != nil else {
            return "Connect by USB and switch the transmitter on. Keep the receiver (model) switched off."
        }
        var parts: [String] = []
        if let v = model.deviceInfo?.firmwareVersion { parts.append("Firmware \(v)") }
        if let s = model.storage { parts.append("\(s.modelCount) models") }
        return parts.isEmpty ? "Connected" : parts.joined(separator: " · ")
    }
}

struct ActivityFooter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.busy && !model.installPhase.isActive {
                HStack(spacing: 12) {
                    ProgressView(value: min(max(model.progress, 0), 1))
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 200, alignment: .leading)
                        .lineLimit(1)
                    Button("Cancel") { model.cancel() }
                }
            }
            if let error = model.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { model.errorMessage = nil }
                }
            }
            if let notice = model.notice {
                HStack(alignment: .top) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(notice).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { model.notice = nil }
                }
            }
        }
        .padding(16)
    }
}

// MARK: - Transmitter

struct TransmitterPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.models.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(model.connection == nil ? "Waiting for a transmitter" : "No model list yet")
                        .font(.title3)
                    Text(model.connection == nil
                         ? "The model list appears here once the transmitter is connected."
                         : "Press Refresh to read the model list.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.models, selection: $model.selectedSlots) { m in
                    HStack {
                        Text("\(m.slot + 1)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        Text(m.name.isEmpty ? "(unnamed)" : m.name)
                    }
                    .tag(m.slot)
                }
            }
            Divider()
            HStack {
                Text(model.selectedSlots.isEmpty ? "Select models to back up only some of them."
                     : "\(model.selectedSlots.count) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset Selected…") { model.confirmingResetSelected = true }
                    .disabled(model.selectedSlots.isEmpty || model.busy || model.connection == nil)
                Button("Reset All…") { model.confirmingResetAll = true }
                    .disabled(model.models.isEmpty || model.busy || model.connection == nil)
                Divider().frame(height: 18)
                Button("Back Up Selected…") { save(slots: model.selectedSlots.sorted()) }
                    .disabled(model.selectedSlots.isEmpty || model.busy || model.connection == nil)
                Button("Back Up Everything…") { save(slots: nil) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.connection == nil)
            }
            .padding(16)
        }
        .confirmationDialog("Reset all \(model.models.count) models to factory defaults?",
                            isPresented: $model.confirmingResetAll, titleVisibility: .visible) {
            Button("Reset All Models", role: .destructive) { model.resetModels(slots: nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(resetExplanation)
        }
        .confirmationDialog("Reset \(model.selectedSlots.count) selected model(s) to factory defaults?",
                            isPresented: $model.confirmingResetSelected, titleVisibility: .visible) {
            Button("Reset Selected Models", role: .destructive) { model.resetModels(slots: model.selectedSlots.sorted()) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(resetExplanation)
        }
    }

    private var resetExplanation: String {
        "The transmitter always has all of its model slots, so a model cannot be deleted – it is returned to "
            + "factory settings and named “Flysky NN” again. NobleLink first saves a full copy of the transmitter "
            + "as it is now, so this can be undone from the Restore tab. Keep the receiver switched off."
    }

    private func save(slots: [Int]?) {
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        let product = (model.connection?.productName ?? "Noble").replacingOccurrences(of: " ", with: "_")
        panel.nameFieldStringValue = "\(product)_\(slots == nil ? "all" : "selected")_\(stamp.string(from: Date())).fsdll"
        panel.allowedContentTypes = [UTType(filenameExtension: "fsdll") ?? .data]
        panel.message = slots == nil
            ? "A full backup includes every model and the transmitter's system settings."
            : "A partial backup contains only the selected models."
        if panel.runModal() == .OK, let url = panel.url {
            model.backUp(slots: slots, to: url)
        }
    }
}

// MARK: - Restore

struct RestorePane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let backup = model.backup {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(backup.url.lastPathComponent).font(.headline)
                        Spacer()
                        Button("Save Arranged Copy…") { saveCopy() }
                        Button("Open Another…") { open() }
                    }
                    Text(summary(backup.file)).foregroundStyle(.secondary)
                    Text("As opened, this restores the backup exactly as it was saved. If you want something "
                         + "different: drag a row to put that model in another slot, untick a model to leave its "
                         + "slot alone, or click a name to change it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(backup.issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue.message, systemImage: issue.severity == .error
                              ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                            .font(.callout)
                    }
                }
                .padding(16)
                Divider()
                List {
                    ForEach(Array(model.plan.enumerated()), id: \.element.id) { slot, row in
                        PlanRowView(slot: slot, row: row, file: backup.file)
                    }
                    .onMove { model.movePlanRows(from: $0, to: $1) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("Select All") { model.setAllIncluded(true) }
                        Button("Select None") { model.setAllIncluded(false) }
                        Button("Ticked to Top") { model.moveTickedToTop() }
                            .help("Move the ticked models to slots 1, 2, 3… keeping their order")
                        Spacer()
                        Button("Revert to Backup") { model.resetPlan() }
                            .help("Undo every change: all models ticked, in the slots and with the names they were saved with")
                            .disabled(model.planMatchesBackup)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(planSummary)
                                .foregroundStyle(model.planMatchesBackup ? Color.primary : Color.orange)
                            if model.restoreSystemSettings && backup.file.hasSystemBlock {
                                Text("System settings will be restored too (see Settings).")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let blocker = model.restoreBlocker {
                            Text(blocker)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                        Button("Restore to Transmitter…") { model.confirmingRestore = true }
                            .disabled(model.restoreBlocker != nil || model.busy)
                    }
                }
                .padding(16)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.badge.arrow.up")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Restore models from a backup").font(.title3)
                    Text("Open a .fsdll file made by NobleLink or by FlySky Assistant.")
                        .foregroundStyle(.secondary)
                    Button("Open Backup…") { open() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog(confirmTitle, isPresented: $model.confirmingRestore, titleVisibility: .visible) {
            Button("Restore \(model.restoreItems.count) Model(s)", role: .destructive) { model.restore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("NobleLink first saves a full copy of the transmitter as it is now, so this can be undone. "
                 + "Slots that already hold exactly the same model are left untouched; the others are "
                 + "overwritten. Keep the receiver switched off.")
        }
    }

    private var planSummary: String {
        let count = model.restoreItems.count
        if model.planMatchesBackup {
            var text = "Restores the backup exactly as saved: \(count) models, each to its own slot."
            if model.snapshot != nil {
                let same = model.plan.enumerated().filter { model.status(slot: $0.offset, row: $0.element) == .identical }.count
                if same == count {
                    text += " All of them are already identical on the transmitter."
                } else if same > 0 {
                    text += " \(same) are already identical on the transmitter and will be left untouched."
                }
            }
            return text
        }
        let written = count == 1 ? "1 model will be written" : "\(count) models will be written"
        return "Changed from the backup (\(model.planChanges)). \(written)."
    }

    private var confirmTitle: String {
        "Restore \(model.restoreItems.count) model(s)" + (model.restoreSystemSettings ? " and system settings?" : "?")
    }

    private func summary(_ file: BackupFile) -> String {
        "\(file.productName) · \(file.models.count) models · "
            + (file.hasSystemBlock ? "includes system settings" : "no system settings")
            + " · saved by firmware \(file.savedByFirmware)"
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fsdll") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.openBackup(url) }
    }

    private func saveCopy() {
        guard let backup = model.backup else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fsdll") ?? .data]
        panel.nameFieldStringValue = backup.url.deletingPathExtension().lastPathComponent + "_arranged.fsdll"
        panel.message = "Saves every model from this backup with the names and slots shown here."
        if panel.runModal() == .OK, let url = panel.url { model.saveArrangedCopy(to: url) }
    }
}

/// One slot of the restore plan.
struct PlanRowView: View {
    @EnvironmentObject var model: AppModel
    let slot: Int
    let row: AppModel.PlanRow
    let file: BackupFile

    /// Bindings are looked up by row identity, because rows move.
    private var include: Binding<Bool> {
        Binding(get: { row.include },
                set: { value in
                    if let i = model.plan.firstIndex(where: { $0.id == row.id }) { model.plan[i].include = value }
                })
    }

    private var name: Binding<String> {
        Binding(get: { row.name },
                set: { value in
                    if let i = model.plan.firstIndex(where: { $0.id == row.id }) {
                        model.plan[i].name = BackupFile.Model.sanitizedName(value)
                    }
                })
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(slot + 1)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            if row.fileIndex != nil {
                Toggle("", isOn: include).labelsHidden()
                if row.include {
                    TextField("Name", text: name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(detailColor)
                        .lineLimit(1)
                } else {
                    Text(row.name)
                        .foregroundStyle(.secondary)
                        .frame(width: 190, alignment: .leading)
                    Text("not restored – slot keeps \(current)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("slot keeps \(current)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to move this row to another slot")
        }
        .padding(.vertical, 1)
    }

    private var current: String { model.currentName(slot: slot).map { "“\($0)”" } ?? "its current model" }

    private var nameProblem: String? {
        model.isRenamed(row) ? BackupFile.Model.nameProblem(model.effectiveName(row)) : nil
    }

    private var status: AppModel.RowStatus { model.status(slot: slot, row: row) }

    private var detailColor: Color {
        if nameProblem != nil { return .red }
        switch status {
        case .replaces, .updates, .renames: return .primary
        case .identical, .alreadyThere, .unknown: return .secondary
        }
    }

    /// What restoring this row will do to the transmitter.
    private var detail: String {
        if let problem = nameProblem { return problem }
        var parts: [String] = []
        if let index = row.fileIndex, Int(file.models[index].slot) != slot {
            parts.append("from slot \(file.models[index].slot + 1)")
        }
        switch status {
        case .unknown:
            if model.isRenamed(row), let index = row.fileIndex { parts.append("was “\(file.models[index].name)”") }
        case .identical:
            parts.append("already on the transmitter – nothing to change")
        case .alreadyThere:
            parts.append("already in this slot")
        case let .updates(count):
            if model.isRenamed(row) { parts.append("renames \(current)") }
            let other = model.isRenamed(row) ? count - 1 : count
            if other > 0 { parts.append(other == 1 ? "1 setting differs" : "\(other) settings differ") }
        case let .renames(old):
            parts.append("renames “\(old)”")
        case let .replaces(old):
            parts.append("replaces “\(old)”")
        }
        // The length limit is only worth mentioning while a name is being edited.
        if model.isRenamed(row) {
            parts.append("\(model.effectiveName(row).utf8.count) of \(BackupFile.Model.maxNameLength) characters")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Firmware

struct FirmwarePane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Installed") {
                    VStack(alignment: .leading, spacing: 4) {
                        row("Transmitter", model.connection?.productName ?? "not connected")
                        row("Firmware", model.deviceInfo?.firmwareVersion ?? "–")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Firmware file") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.firmware?.url.lastPathComponent ?? "No file opened")
                            Spacer()
                            Button("Open Firmware File…") { open() }
                        }
                        if let error = model.firmwareError {
                            Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                        if let fw = model.firmware {
                            row("Version", fw.package.firmware.version ?? "unknown")
                            ForEach(Array(fw.package.firmware.checks().enumerated()), id: \.offset) { _, c in
                                Label(c.message, systemImage: c.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(c.ok ? .green : .red)
                                    .font(.callout)
                            }
                            row("Resource image", fw.package.resource.map { "\($0.count) bytes" } ?? "not included")
                            if let cmp = model.compareFirmwareToInstalled() {
                                Text(cmp > 0 ? "This file is newer than the installed firmware."
                                     : cmp == 0 ? "This is the version already installed."
                                     : "This file is older than the installed firmware.")
                                    .font(.callout.weight(.medium))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Available from FlySky") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.catalogueStatus
                                 ?? "Ask FlySky which firmware it publishes for \(model.productForCatalogue).")
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if model.checkingCatalogue { ProgressView().controlSize(.small) }
                            Button("Check for Updates") { model.checkCatalogue() }
                                .disabled(model.checkingCatalogue)
                        }
                        ForEach(model.catalogueNotes, id: \.self) { note in
                            Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                        }
                        if !model.releases.isEmpty {
                            Text("Each release comes in two builds, FCC and STD. Install the same build the transmitter "
                                 + "runs now: its About screen shows “FCC” or “std.” after the version number.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(groupedSources, id: \.self) { source in
                            Text(source.rawValue).font(.callout.weight(.semibold)).padding(.top, 4)
                            ForEach(model.releases.filter { $0.source == source }.prefix(source == .website ? 20 : 6),
                                    id: \.index) { release in
                                releaseRow(release)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Install on the transmitter") {
                    InstallBox()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
            }
            .padding(16)
        }
    }

    private var groupedSources: [Catalogue.Release.Source] {
        var out: [Catalogue.Release.Source] = []
        for r in model.releases where !out.contains(r.source) { out.append(r.source) }
        return out
    }

    @ViewBuilder
    private func releaseRow(_ release: Catalogue.Release) -> some View {
        HStack {
            Text(release.title).monospacedDigit().frame(width: 110, alignment: .leading)
            if let installed = model.deviceInfo?.firmwareVersion, let version = release.version,
               let c = Catalogue.compare(version, installed) {
                Text(c > 0 ? "newer" : c == 0 ? "installed version" : "older")
                    .foregroundStyle(c > 0 ? Color.green : Color.secondary)
                    .frame(width: 110, alignment: .leading)
            }
            if let notes = release.notesURL {
                Button("Release notes") { NSWorkspace.shared.open(notes) }
                    .buttonStyle(.link)
            }
            Spacer()
            if release.source == .website {
                if model.downloadingRelease == release.index {
                    ProgressView().controlSize(.small)
                }
                Button("Download") { model.downloadRelease(release) }
                    .disabled(model.downloadingRelease != nil)
            } else if let url = release.firmwareURL {
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                .buttonStyle(.link)
            }
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data, UTType(filenameExtension: "bin") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.openFirmware(url) }
    }
}

// MARK: - Firmware installation

struct InstallBox: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.installPhase {
            case .idle:
                idleView
            default:
                progressView
            }
        }
        .confirmationDialog("Install firmware \(model.firmware?.package.firmware.version ?? "")?",
                            isPresented: $model.confirmingInstall, titleVisibility: .visible) {
            Button("Start") { model.startInstall(rehearsal: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("NobleLink first saves all your models. You will then be asked to choose System → Firmware Update "
                 + "→ YES on the transmitter, and to confirm once more before anything is erased. Keep the USB "
                 + "cable connected until it finishes.")
        }
    }

    @ViewBuilder private var idleView: some View {
        if let fw = model.firmware {
            Text("\(fw.url.lastPathComponent) – firmware \(fw.package.firmware.version ?? "?")"
                 + (fw.package.builtFor.map { " for \($0)" } ?? ""))
        }
        if let blocker = model.installBlocker {
            Label(blocker, systemImage: "info.circle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.compareFirmwareToInstalled() == 0 {
            Text("This is the version already installed; installing it again is possible but not needed.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Text("How it works: your models are saved first; you choose System → Firmware Update → YES on the "
             + "transmitter; NobleLink compares, asks you to confirm, then writes and checks the new firmware "
             + "(about 7 minutes). “Rehearse” does everything except writing.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("Rehearse (No Changes)") { model.startInstall(rehearsal: true) }
                .disabled(model.installBlocker != nil || model.busy)
            Button("Install…") { model.confirmingInstall = true }
                .disabled(model.installBlocker != nil || model.busy)
        }
    }

    private enum Step: Int, CaseIterable {
        case backup, updateMode, compare, confirm, write
        var title: String {
            switch self {
            case .backup: return "Save all models"
            case .updateMode: return "Transmitter in update mode"
            case .compare: return "Compare"
            case .confirm: return "Confirm"
            case .write: return "Erase, write and check"
            }
        }
    }

    private var currentStep: Step? {
        switch model.installPhase {
        case .safetyBackup: return .backup
        case .waiting: return .updateMode
        case .comparing: return .compare
        case .ready: return .confirm
        case .installing: return .write
        default: return nil
        }
    }

    private var steps: [Step] {
        model.installRehearsal ? [.updateMode, .compare] : Step.allCases
    }

    @ViewBuilder private var progressView: some View {
        Text(model.installRehearsal ? "Rehearsal – nothing will be written" : "Installing firmware \(model.firmware?.package.firmware.version ?? "")")
            .font(.headline)
        HStack(spacing: 14) {
            ForEach(steps, id: \.rawValue) { step in
                HStack(spacing: 4) {
                    Image(systemName: icon(for: step))
                        .foregroundStyle(color(for: step))
                    Text(step.title).font(.callout)
                }
            }
        }
        switch model.installPhase {
        case let .waiting(seen):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On the transmitter: System → Firmware Update → YES").font(.body.weight(.semibold))
                    Text("Waiting: \(seen).").font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                ProgressView().controlSize(.small)
            }
            buttons(cancel: true)
        case .safetyBackup, .comparing, .installing:
            ProgressView(value: min(max(model.installProgress, 0), 1))
            Text(model.installStatus).font(.callout).foregroundStyle(.secondary)
            if model.installPhase == .installing {
                Label("Do not unplug or switch off the transmitter.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                buttons(cancel: true)
            }
        case let .ready(summary):
            Text(summary).fixedSize(horizontal: false, vertical: true)
            Text("Nothing has been changed yet. Installing erases the current firmware and takes about 7 minutes.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelInstall() }
                Button("Erase and Install") { model.confirmInstall() }
                    .keyboardShortcut(.defaultAction)
            }
        case let .finished(text):
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Done") { model.dismissInstall() } }
        case let .failed(text):
            Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack { Spacer(); Button("Close") { model.dismissInstall() } }
        case let .cancelled(text):
            Label(text, systemImage: "info.circle").foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Close") { model.dismissInstall() } }
        case .idle:
            EmptyView()
        }
    }

    private func buttons(cancel: Bool) -> some View {
        HStack { Spacer(); if cancel { Button("Cancel") { model.cancelInstall() } } }
    }

    private func state(of step: Step) -> Int {   // -1 done, 0 current, 1 to come
        guard let current = currentStep else {
            if case .finished = model.installPhase { return -1 }
            return 1
        }
        return step.rawValue < current.rawValue ? -1 : (step == current ? 0 : 1)
    }

    private func icon(for step: Step) -> String {
        switch state(of: step) {
        case -1: return "checkmark.circle.fill"
        case 0: return "circle.inset.filled"
        default: return "circle"
        }
    }

    private func color(for step: Step) -> Color {
        switch state(of: step) {
        case -1: return .green
        case 0: return .accentColor
        default: return .secondary
        }
    }
}

// MARK: - Settings

struct SettingsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Restoring") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Also restore the transmitter's system settings", isOn: $model.restoreSystemSettings)
                        Text("""
                        System settings are the transmitter-wide options that are not part of any model. They are \
                        only contained in a full backup (Back Up Everything). Leave this off unless you want them \
                        put back as well: NobleLink sends this block correctly aligned, which FlySky’s own software \
                        does not, so it is the one part of a restore that has no precedent on the transmitter.
                        """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Safety copies") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Before every restore or reset, NobleLink saves a full backup of the transmitter as it was.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Show Safety Copies in Finder") {
                            if let dir = try? AppModel.safetyBackupDirectory() { NSWorkspace.shared.open(dir) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Log

struct LogPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.log.count) { count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Toggle("Record every packet", isOn: $model.traceEnabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log.joined(separator: "\n"), forType: .string)
                }
                .disabled(model.log.isEmpty)
                Button("Clear") { model.log.removeAll() }
                    .disabled(model.log.isEmpty)
            }
            .padding(16)
        }
    }
}
