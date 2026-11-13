import Foundation
import NobleKit

// noble – command-line companion for FlySky Noble-series transmitters.

let usage = """
noble – back up, inspect and restore models on a FlySky Noble NB4+ (and relatives)

Transmitter commands (connect by USB, switch on, receiver/model switched off):
  noble devices                         list FlySky USB interfaces macOS can see
  noble info                            firmware version and storage layout
  noble list                            model names on the transmitter
  noble backup [-o FILE] [--slots 1,4]  save models to a .fsdll file (default: all, incl. system settings)
  noble restore FILE [options]          write models from a backup to the transmitter
      --models 4,1,9    models in the file to restore, by position (default: all)
      --to 1,2,3        slots to put them in, in the same order (default: the slots they came from)
      --name "NEW NAME" rename the model while restoring (only with a single model)
      --system          also restore the transmitter-wide system settings
      --allow-family    allow a backup from a sibling model (e.g. NB4 Pro → Noble plus)
      --allow-older-firmware  allow a backup made on older firmware. Not recommended: firmware updates
                        renumber some settings, and those values would land in the wrong place
      --no-verify       skip the read-back comparison
      --no-safety-backup  do not save the transmitter's current state first
      --yes             do not ask for confirmation

  noble reset --slots 18-25 | --all     return models to factory defaults ("Flysky NN"); the transmitter cannot
                                        delete a model. Saves a full safety backup first.

File commands (no transmitter needed):
  noble inspect FILE                    summary and integrity check of a .fsdll backup
  noble dump FILE --model N [--system]  list every setting record of one model
  noble diff FILE_A FILE_B              settings that differ between two backups
  noble extract FILE --models 1,4 -o OUT  write a new backup containing only some models
  noble rename FILE --model N --name "NEW NAME" -o OUT   write a copy with one model renamed (max 14 characters)

Firmware:
  noble firmware check [--product NAME]          list firmware in FlySky's online catalogue; with a transmitter
                                                 connected, also says whether an update is available
  noble firmware download N -o DIR               download release N from that list and verify it
  noble firmware inspect FILE [--resource BIN]   check an updater .exe or firmware .bin
  noble firmware extract FILE -o DIR             save the images contained in an updater .exe
  noble firmware plan FILE                       show the update procedure
  noble firmware probe FILE                      talk to the transmitter in update mode and compare, changing
                                                 nothing, then restart it (a safe rehearsal for an update)
  noble firmware flash FILE                      install the firmware (backs up all models first)
      --enter           ask the transmitter to open its Firmware Update screen instead of using its menu

Global options:
  --trace             print every packet
  --simulate FILE     use a simulated transmitter loaded from a backup instead of USB
"""

struct Args {
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    static let valueOptions: Set<String> = ["-o", "--slots", "--models", "--to", "--model", "--resource", "--simulate",
                                            "--product", "--name"]

    init(_ raw: [String]) throws {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if Args.valueOptions.contains(a) {
                guard i + 1 < raw.count else { throw CLIError("\(a) needs a value") }
                options[a] = raw[i + 1]
                i += 2
            } else if a.hasPrefix("-") && a.count > 1 {
                flags.insert(a)
                i += 1
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }

    /// "1,4,7-9" → zero-based indices.
    func indexList(_ key: String) throws -> [Int]? {
        guard let text = options[key] else { return nil }
        var out: [Int] = []
        for part in text.split(separator: ",") {
            let bounds = part.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !bounds.isEmpty, bounds.count <= 2, !bounds.contains(nil), bounds.allSatisfy({ $0! >= 1 }) else {
                throw CLIError("cannot understand \(key) \(text) (use e.g. 1,4,7-9)")
            }
            let lo = bounds[0]!, hi = bounds.count == 2 ? bounds[1]! : bounds[0]!
            guard lo <= hi else { throw CLIError("cannot understand \(key) \(text)") }
            out.append(contentsOf: (lo...hi).map { $0 - 1 })
        }
        return out
    }
}

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

func printErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func confirm(_ question: String) -> Bool {
    print(question + " [type yes] ", terminator: "")
    return readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes"
}

var lastProgressLength = 0
func showProgress(_ fraction: Double, _ message: String) {
    let line = String(format: "%3d%%  %@", Int(fraction * 100), message)
    let pad = String(repeating: " ", count: max(0, lastProgressLength - line.count))
    FileHandle.standardError.write(Data(("\r" + line + pad).utf8))
    lastProgressLength = line.count
    if fraction >= 1 { FileHandle.standardError.write(Data("\n".utf8)) }
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
}

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd_HHmmss"
    return f.string(from: Date())
}

func safetyBackupDirectory() throws -> URL {
    let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: true)
    let dir = base.appendingPathComponent("NobleLink/SafetyBackups", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Open the transmitter (or the simulator), run `body`, and always leave cleanly.
func withSession<T>(_ args: Args, _ body: (RadioSession) throws -> T) throws -> T {
    let transport: RadioTransport
    let productID: UInt16
    if let sim = args.options["--simulate"] {
        let mock = MockRadio(loading: try BackupFile(contentsOf: URL(fileURLWithPath: sim)))
        transport = mock
        productID = mock.productID
        printErr("(simulated transmitter loaded from \(sim); nothing is written anywhere)")
    } else {
        let hid = try HIDTransport.openFirst()
        transport = hid
        productID = hid.description.productID
        printErr("Connected: \(hid.description)")
        if !hid.description.isKnownTransmitter {
            printErr("warning: product ID is not in the list of known transmitters")
        }
    }
    let session = RadioSession(transport: transport, productID: productID,
                               timing: args.options["--simulate"] != nil ? .instant : LinkTiming())
    if args.has("--trace") { session.link.trace = { printErr("    " + $0) } }
    defer {
        session.leave()
        transport.close()
    }
    try session.hello()
    return try body(session)
}

func describe(_ file: BackupFile) {
    print("Product:        \(file.productName) (0x\(String(file.productID, radix: 16, uppercase: true)))")
    print("Saved by:       firmware \(file.savedByFirmware)")
    print("Models:         \(file.models.count), \(file.modelSize) bytes each")
    print("System block:   " + (file.hasSystemBlock ? "\(file.systemSize) bytes" : "not included"))
    print("")
    for (i, m) in file.models.enumerated() {
        let count = (try? m.records().records.count).map { "\($0) settings" } ?? "UNREADABLE"
        print(String(format: "  %2d  slot %2d  ", i + 1, m.slot + 1) + pad(m.name, 22) + count)
    }
    let issues = file.validate()
    print("")
    if issues.isEmpty {
        print("Integrity: OK – every record checksum is valid.")
    } else {
        for i in issues { print("Integrity \(i)") }
    }
}

func valueText(_ r: ParameterRecord) -> String {
    if let s = r.stringValue { return "\"\(s)\"" }
    if let u = r.unsignedValue {
        let signed: Int
        switch r.value.count {
        case 1: signed = Int(Int8(bitPattern: UInt8(u)))
        case 2: signed = Int(Int16(bitPattern: UInt16(u)))
        default: signed = Int(Int32(bitPattern: u))
        }
        return signed < 0 ? "\(u) (\(signed))" : "\(u)"
    }
    return r.value.hexString
}

func run() throws {
    var raw = Array(CommandLine.arguments.dropFirst())
    guard let command = raw.first, command != "-h", command != "--help", command != "help" else {
        print(usage)
        return
    }
    raw.removeFirst()
    let args = try Args(raw)

    switch command {
    case "devices":
        let all = HIDTransport.connectedDevices()
        if all.isEmpty {
            print("No FlySky USB HID device found (vendor ID 0x284E).")
            print("Check: USB data cable, transmitter switched on, and not in simulator/joystick-only mode.")
        }
        for d in all { print(d) }

    case "info":
        try withSession(args) { s in
            let d = try s.deviceInfo()
            print("Transmitter:      \(d.productName)")
            if !d.uniqueID.isEmpty { print("Unique ID:        \(d.uniqueID)") }
            print("Firmware version: \(d.firmwareVersion ?? "unknown")")
            print("Boot block:       \(d.bootVersion ?? "unknown")")
            print("Version block:    \(d.versionBlock.hexString)")
            let info = try s.storageInfo()
            print("Storage:          \(info.modelCount) models × \(info.modelSize) bytes, "
                + "system settings \(info.systemSize) bytes")
        }

    case "list":
        try withSession(args) { s in
            let (_, models) = try s.listModels()
            for m in models { print(String(format: "  %2d  %@", m.slot + 1, m.name)) }
        }

    case "backup":
        let slots = try args.indexList("--slots")
        let out = URL(fileURLWithPath: args.options["-o"] ?? "Noble_backup_\(timestamp()).fsdll")
        try withSession(args) { s in
            let file = try s.backup(slots: slots, progress: showProgress)
            try file.write(to: out)
            print("Saved \(file.models.count) model(s)" + (file.hasSystemBlock ? " and system settings" : "")
                + " to \(out.path)")
        }

    case "restore":
        guard let path = args.positional.first else { throw CLIError("restore needs a backup file") }
        var file = try BackupFile(contentsOf: URL(fileURLWithPath: path))
        let chosen = try args.indexList("--models") ?? Array(file.models.indices)
        guard chosen.allSatisfy({ file.models.indices.contains($0) }) else {
            throw CLIError("--models refers to a model that is not in the file (it has \(file.models.count))")
        }
        var items = chosen.map { RestoreItem(fileIndex: $0, targetSlot: Int(file.models[$0].slot)) }
        if let to = try args.indexList("--to") {
            guard to.count == items.count else {
                throw CLIError("--to lists \(to.count) slot(s) but \(items.count) model(s) are selected")
            }
            for (i, slot) in to.enumerated() { items[i].targetSlot = slot }
        }
        if let newName = args.options["--name"] {
            guard items.count == 1 else { throw CLIError("--name works with exactly one model") }
            file.models[items[0].fileIndex] = try file.models[items[0].fileIndex].renamed(newName)
        }
        let includeSystem = args.has("--system")
        try withSession(args) { s in
            try RadioSession.preflight(file: file, items: items, deviceProductID: s.productID,
                                       allowSameFamily: args.has("--allow-family"))
            let (storage, current) = try s.listModels()
            if let problem = RadioSession.sizeProblem(file: file, info: storage,
                                                      allowOlderFirmware: args.has("--allow-older-firmware")) {
                throw CLIError(problem)
            }
            print("About to overwrite on the transmitter:")
            for item in items {
                let existing = current.first { $0.slot == item.targetSlot }?.name ?? "?"
                print(String(format: "  slot %2d  \"%@\"  ←  \"%@\"", item.targetSlot + 1, existing,
                             file.models[item.fileIndex].name))
            }
            if includeSystem { print("  plus the transmitter-wide system settings") }
            if !args.has("--yes") && !confirm("Continue?") { throw RadioError.cancelled }

            var before: BackupFile?
            if !args.has("--no-safety-backup") {
                printErr("Saving the transmitter's current state first…")
                let snapshot = try s.backup(progress: showProgress)
                before = snapshot
                // A simulated transmitter's contents do not belong among the real safety copies.
                if args.options["--simulate"] == nil {
                    let url = try safetyBackupDirectory().appendingPathComponent("before_restore_\(timestamp()).fsdll")
                    try snapshot.write(to: url)
                    print("Safety backup: \(url.path)")
                }
            }
            let report = try s.restore(file: file, items: items, includeSystemSettings: includeSystem,
                                       allowSameFamily: args.has("--allow-family"),
                                       allowOlderFirmware: args.has("--allow-older-firmware"),
                                       verify: !args.has("--no-verify"), current: before, progress: showProgress)
            for e in report.entries {
                let status: String
                if e.skipped {
                    status = "already identical – left untouched"
                } else {
                    switch e.verified {
                    case .some(true): status = "written and verified"
                    case .some(false): status = "\(e.differences) setting(s) read back differently"
                    case .none: status = "written (not verified)"
                    }
                }
                print(String(format: "  slot %2d  ", e.targetSlot + 1) + pad(e.name, 22) + status)
            }
            if report.layoutConverted && !report.allVerified {
                print("Note: the backup was saved by firmware \(file.savedByFirmware), not the version running now, so the")
                print("transmitter may have converted it on the way in; differences in the read-back can be expected.")
            }
            if report.crossVersion {
                print("The backup came from older firmware (\(file.savedByFirmware)). Settings were matched one by one:")
                print("per model, \(report.settingsSkipped) setting(s) this firmware no longer has were skipped, and")
                print("\(report.settingsKeptFromSlot) setting(s) new in this firmware kept the values already in the slot.")
            }
            if report.writtenCount == 0 && !report.systemSettingsWritten {
                print("Nothing needed changing; the transmitter was not written to.")
            } else {
                print("Done. Switch the transmitter off and on, then check the restored models before driving.")
            }
        }

    case "reset":
        let chosen = try args.indexList("--slots")
        guard args.has("--all") != (chosen != nil) else { throw CLIError("use either --slots 18-25 or --all") }
        try withSession(args) { s in
            let (info, current) = try s.listModels()
            let slots = chosen ?? Array(0..<info.modelCount)
            guard slots.allSatisfy({ $0 < info.modelCount }), Set(slots).count == slots.count else {
                throw CLIError("--slots must name distinct slots between 1 and \(info.modelCount)")
            }
            print("About to return these models to factory defaults:")
            for slot in slots {
                print(String(format: "  slot %2d  \"%@\"  →  \"%@\"", slot + 1,
                             current.first { $0.slot == slot }?.name ?? "?", FactoryDefaults.defaultName(slot: slot)))
            }
            if !args.has("--yes") && !confirm("Continue?") { throw RadioError.cancelled }
            let simulated = args.options["--simulate"] != nil
            printErr("Saving the transmitter's current state first…")
            let before = try s.backup(progress: showProgress)
            if !simulated {
                let url = try safetyBackupDirectory().appendingPathComponent("before_reset_\(timestamp()).fsdll")
                try before.write(to: url)
                print("Safety backup: \(url.path)")
            }
            let report = try s.resetModels(slots: slots, current: before, useStore: !simulated, progress: showProgress)
            print("Reset \(report.entries.count) model(s)" + (report.allVerified ? ", verified." : "; some settings read back differently."))
        }

    case "inspect":
        guard let path = args.positional.first else { throw CLIError("inspect needs a file") }
        describe(try BackupFile(contentsOf: URL(fileURLWithPath: path)))

    case "dump":
        guard let path = args.positional.first else { throw CLIError("dump needs a file") }
        let file = try BackupFile(contentsOf: URL(fileURLWithPath: path))
        let stream: RecordStream
        if args.has("--system") {
            guard file.hasSystemBlock else { throw CLIError("this backup has no system block") }
            stream = try RecordStream.parse(file.systemBlock)
        } else {
            guard let n = try args.indexList("--model")?.first, file.models.indices.contains(n) else {
                throw CLIError("use --model N (1…\(file.models.count)) or --system")
            }
            stream = try file.models[n].records()
        }
        for r in stream.records {
            print(String(format: "0x%04X[%d]  %@", r.id, r.element, valueText(r)))
        }

    case "diff":
        guard args.positional.count == 2 else { throw CLIError("diff needs two files") }
        let a = try BackupFile(contentsOf: URL(fileURLWithPath: args.positional[0]))
        let b = try BackupFile(contentsOf: URL(fileURLWithPath: args.positional[1]))
        struct Key: Hashable { let id: UInt16; let element: UInt8 }
        func table(_ data: Data) throws -> [Key: ParameterRecord] {
            var t: [Key: ParameterRecord] = [:]
            let stream = try RecordStream.parse(data)
            for r in stream.records { t[Key(id: r.id, element: r.element)] = r }
            return t
        }
        func compare(_ title: String, _ x: Data, _ y: Data) throws -> Int {
            let tx = try table(x), ty = try table(y)
            let keys = Set(tx.keys).union(ty.keys).sorted { ($0.id, $0.element) < ($1.id, $1.element) }
            var n = 0
            for k in keys where tx[k]?.value != ty[k]?.value {
                if n == 0 { print(title) }
                n += 1
                print(String(format: "    0x%04X[%d]  %@  →  %@", k.id, k.element,
                             tx[k].map(valueText) ?? "(absent)", ty[k].map(valueText) ?? "(absent)"))
            }
            return n
        }
        var total = 0
        let bySlotB = Dictionary(b.models.map { ($0.slot, $0) }, uniquingKeysWith: { first, _ in first })
        for m in a.models {
            guard let other = bySlotB[m.slot] else {
                print("slot \(m.slot + 1) \"\(m.name)\": only in the first file")
                continue
            }
            total += try compare("slot \(m.slot + 1) \"\(m.name)\"" + (other.name != m.name ? " / \"\(other.name)\"" : ""),
                                 m.data, other.data)
        }
        if a.hasSystemBlock && b.hasSystemBlock {
            total += try compare("system settings", a.systemSettings, b.systemSettings)
        }
        print(total == 0 ? "No differences." : "\(total) setting(s) differ.")

    case "rename":
        let which = try args.indexList("--model")
        guard let path = args.positional.first, let out = args.options["-o"], let newName = args.options["--name"],
              let n = which?.first else {
            throw CLIError("usage: noble rename FILE --model N --name \"NEW NAME\" -o OUT")
        }
        var file = try BackupFile(contentsOf: URL(fileURLWithPath: path))
        guard file.models.indices.contains(n) else { throw CLIError("no such model in file") }
        let oldName = file.models[n].name
        file.models[n] = try file.models[n].renamed(newName)
        try file.write(to: URL(fileURLWithPath: out))
        print("Renamed \"\(oldName)\" to \"\(newName)\" in \(out)")

    case "extract":
        let chosenModels = try args.indexList("--models")
        guard let path = args.positional.first, let out = args.options["-o"], let chosen = chosenModels else {
            throw CLIError("usage: noble extract FILE --models 1,4 -o OUT")
        }
        var file = try BackupFile(contentsOf: URL(fileURLWithPath: path))
        guard chosen.allSatisfy({ file.models.indices.contains($0) }) else { throw CLIError("no such model in file") }
        file.models = chosen.map { file.models[$0] }
        file.systemSize = 0
        file.systemBlock = Data()
        try file.write(to: URL(fileURLWithPath: out))
        print("Wrote \(file.models.count) model(s) to \(out)")

    case "firmware":
        try firmware(args)

    default:
        throw CLIError("unknown command \"\(command)\" – run `noble help`")
    }
}

/// `noble firmware check` / `noble firmware download N`: FlySky's online catalogue.
func firmwareCatalogue(_ args: Args) throws {
    let sub = args.positional[0]
    var product = args.options["--product"]
    var installed: String?
    if product == nil {
        // Ask the transmitter what it is and what it runs.
        (product, installed) = try withSession(args) { s in
            let d = try s.deviceInfo()
            return (d.productName, d.firmwareVersion)
        }
    }
    guard let product else { throw CLIError("could not determine the product; pass --product \"Noble plus EN\"") }
    printErr("Asking FlySky (website and FlySky Assistant catalogue) about \"\(product)\"…")
    let listing = Catalogue.fetchAll(productName: product)
    for (source, reason) in listing.failures { printErr("note: \(source.rawValue): \(reason)") }
    let releases = listing.releases
    guard !releases.isEmpty else {
        throw CLIError("no firmware could be found for \(product)")
    }
    if sub == "check" {
        var lastSource: Catalogue.Release.Source?
        for r in releases {
            if r.source != lastSource { print("\n\(r.source.rawValue):"); lastSource = r.source }
            print(String(format: "  %2d  ", r.index) + pad(r.title, 14) + (r.firmwareURL?.absoluteString ?? ""))
        }
        if let newest = listing.newestVersion {
            print("\nNewest listed: \(newest)")
            if let installed, let c = Catalogue.compare(newest, installed) {
                print(c > 0 ? "Installed: \(installed) – an update is available."
                      : c == 0 ? "Installed: \(installed) – up to date."
                      : "Installed: \(installed) – newer than anything listed.")
            }
            print("FCC and STD are two builds of each release; install the same one the transmitter runs now")
            print("(its About screen shows \"FCC\" or \"std.\" after the version number).")
        }
        return
    }
    // download
    guard args.positional.count >= 2, let n = Int(args.positional[1]),
          let release = releases.first(where: { $0.index == n }) else {
        throw CLIError("usage: noble firmware download N -o DIR   (N from `noble firmware check`)")
    }
    guard let out = args.options["-o"] else { throw CLIError("download needs -o DIR") }
    let dir = URL(fileURLWithPath: out, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    printErr("Downloading \(release.title) from the \(release.source.rawValue)…")
    if release.source == .website {
        let (data, pkg) = try Catalogue.downloadUpdater(release)
        guard pkg.firmware.isValid, pkg.firmware.version == release.version else {
            for c in pkg.firmware.checks() { print("    \(c)") }
            throw CLIError("the downloaded updater did not contain a valid firmware \(release.version ?? "") and was not saved")
        }
        let file = dir.appendingPathComponent(Catalogue.suggestedFileName(release, product: product))
        try data.write(to: file)
        print("Saved \(file.path) (firmware \(pkg.firmware.version ?? "?"), integrity OK)")
        return
    }
    let pkg = try Catalogue.download(release)
    guard pkg.firmware.isValid else {
        for c in pkg.firmware.checks() { print("    \(c)") }
        throw CLIError("the downloaded firmware failed its integrity checks and was not saved")
    }
    let tag = release.title.replacingOccurrences(of: " ", with: "_")
    try pkg.firmware.data.write(to: dir.appendingPathComponent("firmware_\(tag).bin"))
    if let r = pkg.resource { try r.write(to: dir.appendingPathComponent("resource_\(tag).bin")) }
    print("Saved firmware \(pkg.firmware.version ?? "?") (integrity OK) to \(dir.path)")
}

func firmware(_ args: Args) throws {
    if let first = args.positional.first, first == "check" || first == "download" {
        try firmwareCatalogue(args)
        return
    }
    guard args.positional.count >= 2 else {
        throw CLIError("usage: noble firmware check|download|inspect|extract|plan|flash …")
    }
    let sub = args.positional[0]
    let url = URL(fileURLWithPath: args.positional[1])
    let pkg = try FirmwarePackage.load(url: url, resourceURL: args.options["--resource"].map { URL(fileURLWithPath: $0) })

    func summary() {
        print("Source:    \(pkg.source)")
        print("Firmware:  version \(pkg.firmware.version ?? "?"), \(pkg.firmware.data.count) bytes")
        for c in pkg.firmware.checks() { print("    \(c)") }
        if let target = pkg.builtFor { print("    built for: \(target)") }
        if let r = pkg.resource {
            print(String(format: "Resources: %d bytes for external flash at 0x80000, checksum 0x%08X", r.count,
                         pkg.resourceCRC32 ?? 0))
        } else {
            print("Resources: none supplied (a full update also needs the matching \"Resource\" image)")
        }
    }

    switch sub {
    case "inspect":
        summary()
    case "rename":
        let which = try args.indexList("--model")
        guard let path = args.positional.first, let out = args.options["-o"], let newName = args.options["--name"],
              let n = which?.first else {
            throw CLIError("usage: noble rename FILE --model N --name \"NEW NAME\" -o OUT")
        }
        var file = try BackupFile(contentsOf: URL(fileURLWithPath: path))
        guard file.models.indices.contains(n) else { throw CLIError("no such model in file") }
        let oldName = file.models[n].name
        file.models[n] = try file.models[n].renamed(newName)
        try file.write(to: URL(fileURLWithPath: out))
        print("Renamed \"\(oldName)\" to \"\(newName)\" in \(out)")

    case "extract":
        guard let out = args.options["-o"] else { throw CLIError("extract needs -o DIR") }
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let v = pkg.firmware.version ?? "unknown"
        try pkg.firmware.data.write(to: dir.appendingPathComponent("firmware_\(v).bin"))
        if let r = pkg.resource { try r.write(to: dir.appendingPathComponent("resource_\(v).bin")) }
        summary()
        print("Images written to \(dir.path)")
    case "plan":
        summary()
        let blocks = ((pkg.resource?.count ?? 0) + 0xFFFF) / 0x10000
        print("""

        Update procedure (identical to FlySky's Windows updater):
          1. 0x06  ask the transmitter for the CRC of each of the \(blocks) 64 KiB resource blocks (read-only)
          2. 0x03  erase the installed firmware (a = \(pkg.firmware.data.count))
          3. 0x04  erase only the resource blocks whose CRC differs
          4. 0x05  write \(pkg.firmware.data.count) bytes of firmware in 256-byte pieces (c = 1)
          5. 0x05  write the differing resource blocks (c = 2)
          6. 0x08  firmware check, expecting CRC16 \(String(format: "0x%04X", pkg.firmware.computedCRC))
          7. 0x06  resource check, expecting \(String(format: "0x%08X", pkg.resourceCRC32 ?? 0))
          8. 0x07  restart
        """)

    case "probe", "flash":
        summary()
        guard pkg.firmware.isValid else { throw CLIError("firmware image failed its integrity checks") }
        guard pkg.resource != nil else { throw CLIError("this needs the resource image too (use the updater .exe)") }
        let flashing = sub == "flash"

        // Is the transmitter running normally? Then note what it runs and (for a
        // real update) keep a copy of its models before going any further.
        if let hid = try? HIDTransport.openFirst() {
            let s = RadioSession(transport: hid, productID: hid.description.productID)
            if args.has("--trace") { s.link.trace = { printErr("    " + $0) } }
            var normalMode = false
            if let info = try? s.deviceInfo(), (try? s.storageInfo()) != nil {
                normalMode = true
                print("\nTransmitter is running normally: \(info.productName), firmware \(info.firmwareVersion ?? "?").")
                switch pkg.isBuilt(for: info.productName) {
                case .some(true): break
                case .some(false):
                    hid.close()
                    throw CLIError("this firmware is built for \(pkg.builtFor ?? "another transmitter"), "
                        + "not the connected \(info.productName)")
                case .none:
                    printErr("warning: could not confirm that this firmware is built for this transmitter model")
                }
                if flashing && !args.has("--no-safety-backup") {
                    let url = try safetyBackupDirectory().appendingPathComponent("before_firmware_\(timestamp()).fsdll")
                    printErr("Saving all models first (updating can reset them)…")
                    try s.backup(progress: showProgress).write(to: url)
                    print("Safety backup: \(url.path)")
                }
                if args.has("--enter") {
                    print("Asking the transmitter to open its firmware-update screen…")
                    try? s.setMode(.firmwareUpdate, waitForEcho: false)
                } else {
                    s.leave()
                }
            }
            hid.close()
            if normalMode {
                print("""

                Now put the transmitter into update mode: on the transmitter open the system settings,
                choose Firmware Update and confirm. Leave the USB cable connected.
                Waiting for it (up to 3 minutes)…
                """)
            }
        } else {
            print("\nNo transmitter visible yet. Connect it, switch it on and choose Firmware Update on it.")
            print("Waiting (up to 3 minutes)…")
        }

        // Wait for the bootloader, then run the read-only comparison.
        var found: (RadioTransport, FirmwareUpdater, FirmwareUpdater.Probe)?
        let trace: ((String) -> Void)? = args.has("--trace") ? { printErr("    " + $0) } : nil
        if let hid = UpdateMode.waitForBootloader(timeout: 180, trace: trace, status: { seen, waited in
            printErr("[\(Int(waited)) s] Waiting: \(UpdateMode.describe(seen)).")
            printErr("        \(UpdateMode.instruction)")
        }) {
            printErr("Update mode detected: \((hid as? HIDTransport)?.description.description ?? "transmitter")")
            let session = BootloaderSession(transport: hid)
            session.trace = trace
            let u = FirmwareUpdater(session: session)
            let probe = try u.probe(package: pkg, progress: showProgress)
            found = (hid, u, probe)
        }
        guard let (hid, updater, probe) = found else {
            throw CLIError("the transmitter did not enter update mode within 3 minutes; nothing was changed. "
                + "Start again and choose System → Firmware Update → YES on the transmitter while this waits.")
        }
        defer { hid.close() }

        print("Bootloader \(probe.identity.bootloaderVersion); installed firmware: \(probe.identity.firmwareVersion ?? "none")")
        print("Resource blocks that differ from this image: \(probe.differingBlocks.count) of \(probe.imageBlockCRCs.count)")
        if probe.identity.bootloaderWord > BootloaderSession.newestKnownBootloader {
            updater.restart()
            throw CLIError("this bootloader is newer than the update procedure knows; not continuing")
        }

        if !flashing {
            print("Probe finished – nothing was changed. Restarting the transmitter into its normal firmware.")
            updater.restart()
            return
        }

        print("\nReady to install firmware \(pkg.firmware.version ?? "?"). Do not unplug or switch off until it finishes.")
        if !args.has("--yes") && !confirm("Erase the current firmware and install this one?") {
            print("Cancelled – nothing was changed. Restarting the transmitter.")
            updater.restart()
            return
        }
        do {
            try updater.run(package: pkg, progress: showProgress)
        } catch {
            printErr("")
            printErr("The update did not complete: \(error)")
            printErr("The transmitter's bootloader is separate from the firmware and is not touched by an update,")
            printErr("so it stays in update mode. Leave it connected and run the same command again.")
            throw CLIError("update incomplete")
        }
        print("Update finished. The transmitter restarts with firmware \(pkg.firmware.version ?? "?").")
        print("Check your models; if they were reset, restore them from the safety backup.")

    default:
        throw CLIError("unknown firmware command \"\(sub)\"")
    }
}

// Line-buffer stdout so instructions appear immediately even when the output
// goes to a pipe (otherwise they would only show up when the program ends).
setvbuf(stdout, nil, _IOLBF, 0)

do {
    try run()
} catch {
    printErr("error: \(error)")
    exit(1)
}
