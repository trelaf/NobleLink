import Foundation
import NobleKit

// Self-test runner. Usage: NobleSelfTest [samples-directory]
// The samples directory is expected to contain models/*.fsdll and
// firmware/*.exe; tests that need files are skipped when they are absent.

var failures = 0
var checksRun = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
    checksRun += 1
    if !condition() {
        failures += 1
        print("  FAIL  \(message)   (\(file):\(line))")
    }
}

func section(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch {
        failures += 1
        print("  FAIL  threw: \(error)")
    }
}

func expectError(_ what: String, _ body: () throws -> Void, where predicate: (Error) -> Bool = { _ in true }) {
    checksRun += 1
    do {
        try body()
        failures += 1
        print("  FAIL  expected an error: \(what)")
    } catch {
        if !predicate(error) {
            failures += 1
            print("  FAIL  wrong error for \(what): \(error)")
        }
    }
}

let samplesDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../samples")
let fm = FileManager.default
let modelFiles = ((try? fm.contentsOfDirectory(at: samplesDir.appendingPathComponent("models"),
                                               includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "fsdll" }.sorted { $0.path < $1.path }
let firmwareFiles = ((try? fm.contentsOfDirectory(at: samplesDir.appendingPathComponent("firmware"),
                                                  includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "exe" }.sorted { $0.path < $1.path }

func session(_ mock: MockRadio) -> RadioSession {
    RadioSession(transport: mock, productID: mock.productID, timing: .instant)
}

// MARK: - Pure format tests

section("packet layout") {
    let p = Packet(seq: 7, command: 0x69, a: 1, b: 4, c: 0x100, d: 0x80, payload: Data([1, 2, 3]))
    let raw = p.encoded()
    check(raw.count == 280, "report is 280 bytes")
    check(raw.prefix(24).hexString == "07000000" + "69000000" + "01000000" + "04000000" + "00010000" + "80000000",
          "header is six little-endian words")
    check(raw[24] == 1 && raw[26] == 3 && raw[27] == 0, "payload follows header, zero padded")
    check(Packet(report: raw) == p, "decode(encode(p)) == p")
    check(Packet(report: Data([0]) + raw) == p, "a leading report-ID byte is tolerated")
}

section("checksums") {
    let s = Data("123456789".utf8)
    check(Checksums.crc16CCITT(s) == 0x29B1, "CRC-16/CCITT-FALSE check value")
    check(Checksums.crc32(s) == 0xCBF4_3926, "standard CRC-32 check value")
    check(Checksums.crc32(s, seed: 0xFFFF_FFFF) != Checksums.crc32(s), "seeded variant differs from standard")
    check(Checksums.xor8([0x0D, 0x0A, 0x00, 0x07, 0x15, 0x00, 0x00, 0x07, 0xD0, 0xA5]) == 0x67,
          "record check byte matches the first record of a real backup")
}

section("parameter records") {
    let r = ParameterRecord(owner: 0, element: 0, id: 0x07D0, value: Data([0xA5]))
    check(r.encoded().hexString == "0d0a0007150000" + "07d0a567", "encoding matches a real record")
    let name = ParameterRecord(owner: 3, element: 0, id: 0x07D1, value: Data("TT-02".utf8) + Data(count: 10))
    let stream = try RecordStream.parse(r.encoded() + name.encoded() + Data(repeating: 0xFF, count: 5))
    check(stream.records == [r, name], "round trip of two records")
    check(stream.trailing.count == 5 && stream.trailingIsPadding, "padding is recognised")
    check(stream.records[1].stringValue == "TT-02", "string value")
    var damaged = r.encoded()
    damaged[9] ^= 1
    expectError("bad checksum") { _ = try RecordStream.parse(damaged) }
}

// MARK: - Real backup files

if modelFiles.isEmpty {
    print("• (no sample .fsdll files found in \(samplesDir.path)/models – file tests skipped)")
}

for url in modelFiles {
    section("backup file \(url.lastPathComponent)") {
        let original = try Data(contentsOf: url)
        let file = try BackupFile(data: original)
        check(file.serialized() == original, "re-serialising reproduces the file byte for byte")
        check(file.validate().isEmpty, "no validation issues: \(file.validate())")
        check(file.models.count == 25, "25 models")
        check(file.modelSize == 0x42DC, "model block size 0x42DC")
        check(file.productID == 0x8D09 && file.productName == "Noble plus EN", "product")
        check(file.systemSize == 493 && file.systemBlock.count == 512, "system block 493 (stored 512)")
        check(file.models[0].name == "RX28 2500", "first model name")
        let records = try file.models[0].records()
        check(records.records.count == 1430 && records.trailing.isEmpty, "1430 records fill the block exactly")

        // The simulated transmitter, loaded with this file, must hand back the same bytes.
        let mock = MockRadio(loading: file)
        let exported = try session(mock).backup()
        check(exported.serialized() == original, "backup from the simulator is byte-identical to the vendor's export")
        let chunkRequests = mock.log.filter { $0.command == Command.dataBlock.rawValue }
        check(Set(chunkRequests.map(\.seq)).count == chunkRequests.count, "no data chunk was ever requested twice")

        // Restore everything into a blank transmitter.
        let blank = MockRadio()
        let items = file.models.indices.map { RestoreItem(fileIndex: $0, targetSlot: $0) }
        let report = try session(blank).restore(file: file, items: items, includeSystemSettings: true)
        check(blank.models == file.models.map(\.data), "all model blocks arrived intact")
        check(blank.systemBlock == file.systemSettings, "system settings arrived intact (493 bytes, unshifted)")
        check(blank.names[9] == Data("TT-02".utf8), "names were written")
        check(blank.commits >= 1, "commit was sent")
        check(report.allVerified && report.entries.count == 25, "read-back verification passed")
        check(report.layoutConverted, "older layout version is flagged (file 0x10005 vs simulator 0x1000B)")
        if let a = blank.announcedImport {
            check(a.a == 1 && a.b == file.storageField1 && a.c == 0x8D09 && a.d == file.storageField2,
                  "import announcement carries the file's header fields")
            check(a.payload.le32(16) == 0x42DC && a.payload.prefix(16).allSatisfy { $0 == 0 },
                  "announcement payload carries the model size at +16")
        } else {
            check(false, "import was announced")
        }

        // Single model into a different slot.
        let other = MockRadio()
        _ = try session(other).restore(file: file, items: [RestoreItem(fileIndex: 9, targetSlot: 2)])
        let landed = try RecordStream.parse(other.models[2])
        check(landed.records.allSatisfy { $0.owner == 2 }, "cross-slot restore re-tags every record with the new slot")
        check(RadioSession.settingDifferences(written: file.models[9].data, readBack: other.models[2]) == 0,
              "…without changing any setting")
        check(other.names[2] == Data("TT-02".utf8), "…and names the slot")

        // Renaming.
        let renamed = try file.models[9].renamed("TT-02 Rally")
        check(renamed.name == "TT-02 Rally" && renamed.data.count == file.models[9].data.count, "rename keeps the block size")
        let renamedRecords = try renamed.records()
        check(renamedRecords.records.first { $0.id == 0x07D1 }?.stringValue == "TT-02 Rally", "name record inside the model is updated")
        check(RadioSession.settingDifferences(written: file.models[9].data, readBack: renamed.data) == 1,
              "…and nothing else changes")
        check((try? file.models[9].renamed(file.models[9].name))?.data == file.models[9].data,
              "renaming to the same name reproduces the block byte for byte")
        expectError("15 characters is too long") { _ = try file.models[9].renamed("123456789012345") }
        expectError("non-ASCII refused") { _ = try file.models[9].renamed("Tamiya é") }
        check(BackupFile.Model.sanitizedName("Rally 🚗 Car with a long name") == "Rally  Car wit", "live sanitising")
        var edited = file
        edited.models[9] = renamed
        check(edited.validate().isEmpty, "an edited backup still validates")
        let renamedTarget = MockRadio()
        _ = try session(renamedTarget).restore(file: edited, items: [RestoreItem(fileIndex: 9, targetSlot: 0)])
        check(renamedTarget.names[0] == Data("TT-02 Rally".utf8), "restore applies the edited name")
        let back = try session(renamedTarget).backup(slots: [0])
        check(back.models[0].name == "TT-02 Rally" && back.validate().isEmpty, "…and it reads back consistently")
        check(other.models[9] == MockRadio(productID: 0x8D09).models[9], "…and leaves the original slot alone")
        check(other.systemBlock == MockRadio().systemBlock, "…and does not touch system settings by default")

        // Partial backup.
        let partial = try session(MockRadio(loading: file)).backup(slots: [0, 9])
        check(partial.models.map(\.name) == ["RX28 2500", "TT-02"], "partial backup has the chosen models")
        check(partial.systemSize == 0 && partial.systemBlock.isEmpty, "partial backup carries no system block")
        let reparsed = try BackupFile(data: partial.serialized())
        check(reparsed == partial, "partial backup round-trips")

        // A damaged file must never reach a transmitter.
        var broken = original
        broken[1000] ^= 0x40
        let brokenFile = try BackupFile(data: broken)
        check(!brokenFile.isSafeToWrite, "a flipped bit is detected")
        let untouched = MockRadio()
        expectError("damaged file refused") {
            _ = try session(untouched).restore(file: brokenFile, items: items)
        }
        check(untouched.requestCount == 0, "…before a single packet is sent")
    }
}

// MARK: - Skipping what is already there

section("restore leaves identical models untouched") {
    let mock = MockRadio()
    let saved = try session(mock).backup()
    // Change one model on the "transmitter" after the backup.
    var stream = try RecordStream.parse(mock.models[3])
    stream.records[7].value = Data([0x2A])
    mock.models[3] = stream.encoded()

    let current = try session(mock).backup()
    let all = saved.models.indices.map { RestoreItem(fileIndex: $0, targetSlot: $0) }
    let before = mock.log.count
    let report = try session(mock).restore(file: saved, items: all, current: current)
    let writes = mock.log[before...].filter { $0.command == Command.dataBlock.rawValue && $0.a == 1 }
    check(report.writtenCount == 1 && report.skippedCount == 24, "only the changed model is written")
    check(Set(writes.map(\.b)) == [DataArea.model(slot: 3)], "…and only its slot is touched")
    check(mock.models[3] == saved.models[3].data, "the changed model is back to the saved settings")
    check(report.allVerified, "report is clean")

    let again = try session(mock).backup()
    let logBefore = mock.log.count
    let nothing = try session(mock).restore(file: saved, items: all, current: again)
    check(nothing.writtenCount == 0 && nothing.skippedCount == 25, "a second restore finds nothing to do")
    check(mock.log[logBefore...].allSatisfy { $0.a == 0 || $0.command == Command.setMode.rawValue },
          "…and sends no write, announcement or commit")

    // Same settings under another name are not "identical".
    var renamed = saved
    renamed.models[5] = try saved.models[5].renamed("New Name")
    let r = try session(mock).restore(file: renamed, items: [RestoreItem(fileIndex: 5, targetSlot: 5)], current: again)
    check(r.writtenCount == 1 && mock.names[5] == Data("New Name".utf8), "a rename alone is written")
    let moved = try saved.models[5].retargeted(toSlot: 9)
    check(!RadioSession.sameSettings(saved.models[5].data, renamed.models[5].data)
          && RadioSession.sameSettings(saved.models[5].data, moved.data),
          "sameness ignores the slot tag but not the name")
}

// MARK: - Factory defaults

section("factory-default model and reset") {
    // A simulated transmitter: 25 untouched slots, three of them then "used".
    let mock = MockRadio()
    let s0 = session(mock)
    var current = try s0.backup()
    check(FactoryDefaults.detect(in: current) != nil, "defaults are recognised when all slots are untouched")
    for slot in [0, 1, 2] {
        var stream = try RecordStream.parse(mock.models[slot])
        stream.records[5].value = Data([UInt8(slot + 7)])
        mock.models[slot] = try BackupFile.Model(nameBytes: Data(), slot: UInt32(slot), nameField: 14, data: stream.encoded())
            .renamed("Car \(slot + 1)").data
        mock.names[slot] = Data("Car \(slot + 1)".utf8)
    }
    current = try s0.backup()
    guard let defaults = FactoryDefaults.detect(in: current) else { check(false, "defaults found"); return }
    check(!defaults.matches(current.models[0]) && defaults.matches(current.models[10]), "used and untouched models are told apart")

    let report = try session(mock).resetModels(slots: [0, 2], current: current)
    check(report.allVerified && report.entries.count == 2, "reset writes and verifies")
    let after = try session(mock).backup()
    check(after.models[0].name == "Flysky 01" && after.models[2].name == "Flysky 03", "reset slots get their default names")
    check(defaults.matches(after.models[0]) && defaults.matches(after.models[2]), "…and default settings")
    check(after.models[1].name == "Car 2" && !defaults.matches(after.models[1]), "other slots are untouched")
    let tagged = try RecordStream.parse(after.models[2].data)
    check(tagged.records.allSatisfy { $0.owner == 2 }, "records are tagged with the right slot")

    // With every slot in use there is nothing to learn from.
    var allUsed = current
    for i in allUsed.models.indices { allUsed.models[i] = try allUsed.models[i].renamed("Used \(i + 1)") }
    check(FactoryDefaults.detect(in: allUsed) == nil, "no defaults are assumed when every slot has been renamed")
    var oneLeft = allUsed
    oneLeft.models[24] = current.models[24]
    check(FactoryDefaults.detect(in: oneLeft) == nil, "a single default-named model is not trusted on its own")
}

for url in modelFiles {
    section("factory defaults in \(url.lastPathComponent)") {
        let file = try BackupFile(contentsOf: url)
        guard let defaults = FactoryDefaults.detect(in: file) else { check(false, "defaults detected in a real backup"); return }
        let untouched = file.models.filter { defaults.matches($0) }.map(\.name)
        check(untouched.count >= 2 && untouched.allSatisfy { $0.hasPrefix("Flysky ") }, "only untouched slots match the default (\(untouched.count))")
        let (resetFile, items) = try defaults.resetFile(slots: [0, 5])
        check(resetFile.validate().isEmpty && items.map(\.targetSlot) == [0, 5], "reset file is a valid backup")
        check(resetFile.models.map(\.name) == ["Flysky 01", "Flysky 06"], "default names follow the slot")
    }
}

let newerBackupURL = samplesDir.appendingPathComponent("models_1.0.22/all_2026-11-11.fsdll")
if let older = modelFiles.first, let newerFile = try? BackupFile(contentsOf: newerBackupURL),
   let olderFile = try? BackupFile(contentsOf: older) {
    section("restoring a 1.0.5 model onto 1.0.22 (setting by setting)") {
        check(newerFile.modelSize == 20672 && newerFile.savedByFirmware == "1.0.22", "1.0.22 backup as expected")
        let mock = MockRadio(loading: newerFile)
        let s = session(mock)
        let info = try s.storageInfo()
        check(RadioSession.formatRelation(file: olderFile, info: info) == .olderFirmware(file: "1.0.5", device: "1.0.22"),
              "the older backup is recognised as such")
        check(RadioSession.sizeProblem(file: olderFile, info: info) != nil, "…and refused by default")
        expectError("default restore of an older backup") {
            _ = try s.restore(file: olderFile, items: [RestoreItem(fileIndex: 9, targetSlot: 20)])
        }
        check(mock.announcedImport == nil, "…before anything is sent")
        check(RadioSession.sizeProblem(file: olderFile, info: info, allowOlderFirmware: true) == nil, "allowed when asked for")

        let slotBefore = mock.models[20]
        let report = try s.restore(file: olderFile, items: [RestoreItem(fileIndex: 9, targetSlot: 20)],
                                   allowOlderFirmware: true)
        check(report.crossVersion && report.allVerified, "restore verifies on the settings both versions have")
        check(report.settingsSkipped == 16 && report.settingsKeptFromSlot == 312,
              "16 settings dropped since 1.0.5 are skipped, 312 new ones keep their value (\(report.settingsSkipped)/\(report.settingsKeptFromSlot))")
        check(mock.models[20].count == 20672, "the slot keeps the 1.0.22 size")
        let now = try RecordStream.parse(mock.models[20]).records
        let was = try RecordStream.parse(slotBefore).records
        let old = Dictionary(try olderFile.models[9].records().records.map { ("\($0.id)/\($0.element)", $0.value) },
                             uniquingKeysWith: { a, _ in a })
        let carried = now.filter { old["\($0.id)/\($0.element)"] != nil && $0.id != 0x0FDB }
        check(carried.allSatisfy { $0.value == old["\($0.id)/\($0.element)"] }, "every shared setting has the 1.0.5 value")
        let kept = zip(now, was).filter { old["\($0.0.id)/\($0.0.element)"] == nil }
        check(!kept.isEmpty && kept.allSatisfy { $0.0.value == $0.1.value }, "new settings keep what was in the slot")
        check(mock.names[20] == Data("TT-02".utf8) && now.allSatisfy { $0.owner == 20 }, "named and tagged for slot 21")
    }

    section("restoring a 1.0.22 backup onto 1.0.5 is refused") {
        let mock = MockRadio(loading: olderFile)
        let s = session(mock)
        let info = try s.storageInfo()
        check(RadioSession.sizeProblem(file: newerFile, info: info) != nil, "reported as newer firmware")
        expectError("refused") { _ = try s.restore(file: newerFile, items: [RestoreItem(fileIndex: 0, targetSlot: 0)]) }
        check(mock.announcedImport == nil, "…before anything is sent")
    }
} else {
    print("• (no 1.0.22 backup in \(newerBackupURL.path) – cross-version tests skipped)")
}

section("backup from other firmware is refused early") {
    let mock = MockRadio(modelSize: 0x50C0)
    let small = try session(MockRadio()).backup()
    let info = try session(mock).storageInfo()
    check(RadioSession.sizeProblem(file: small, info: info) != nil, "size mismatch is reported")
    expectError("restore refuses a different model size") {
        _ = try session(mock).restore(file: small, items: [RestoreItem(fileIndex: 0, targetSlot: 0)])
    }
    check(mock.announcedImport == nil, "…before announcing an import")
}

// MARK: - Protocol behaviour against the simulator

section("listing and device info") {
    let mock = MockRadio()
    let s = session(mock)
    let (info, models) = try s.listModels()
    check(info.modelCount == 25 && info.modelSize == 0x42DC && info.systemSize == 493, "storage layout")
    check(info.totalSize == UInt32(25 * 0x42DC + 493), "total size")
    check(models.count == 25 && models[11].name == "Flysky 12", "names")
    let d = try s.deviceInfo()
    check(d.firmwareVersion == "1.0.22", "firmware version decoding")
    check(d.uniqueID == "0039002E3133510A37383339" && d.productName == "Noble plus EN", "product name and unique ID")
}

section("receiver linked") {
    let mock = MockRadio()
    mock.receiverLinked = true
    expectError("backup refused") { _ = try session(mock).backup() } where: { ($0 as? RadioError) == .receiverActive }
    let dataRequests = mock.log.filter { $0.command == Command.dataBlock.rawValue }
    check(dataRequests.isEmpty, "no data was requested")
}

section("damaged read is retried") {
    let mock = MockRadio()
    mock.corruptNextModelRead = true
    let b = try session(mock).backup(slots: [4])
    check(b.models[0].data == mock.models[4], "second attempt returned clean data")
}

section("lost reply during a data read") {
    let mock = MockRadio()
    let s = session(mock)
    try s.requireReceiverOff()
    let info = try s.storageInfo()
    // Lose the reply to the third request from now (a data chunk).
    mock.dropReplyToRequestNumber = mock.requestCount + 4
    let data = try s.readModelBlock(slot: 1, size: Int(info.modelSize))
    check(data == mock.models[1], "block is intact after restarting the stream")
}

section("pre-flight checks") {
    let mock = MockRadio()
    let file = try session(mock).backup()
    let all = file.models.indices.map { RestoreItem(fileIndex: $0, targetSlot: $0) }
    expectError("different family") {
        try RadioSession.preflight(file: file, items: all, deviceProductID: 0x8E00, allowSameFamily: true)
    }
    expectError("same family needs confirmation") {
        try RadioSession.preflight(file: file, items: all, deviceProductID: 0x8D0C, allowSameFamily: false)
    }
    try RadioSession.preflight(file: file, items: all, deviceProductID: 0x8D0C, allowSameFamily: true)
    expectError("duplicate target") {
        try RadioSession.preflight(file: file, items: [.init(fileIndex: 0, targetSlot: 1), .init(fileIndex: 1, targetSlot: 1)],
                                   deviceProductID: 0x8D09, allowSameFamily: false)
    }
    expectError("empty selection") {
        try RadioSession.preflight(file: file, items: [], deviceProductID: 0x8D09, allowSameFamily: false)
    }
    check(Products.compatibility(fileProductID: 0x8D09, deviceProductID: 0x8D09) == .same, "same product")
}

// MARK: - Firmware files

func updater(_ boot: MockBootloader) -> FirmwareUpdater {
    let s = BootloaderSession(transport: boot)
    s.replyTimeout = 0.2
    return FirmwareUpdater(session: s)
}

if firmwareFiles.isEmpty {
    print("• (no sample firmware .exe found in \(samplesDir.path)/firmware – firmware tests skipped)")
}

var packages: [String: FirmwarePackage] = [:]
for url in firmwareFiles {
    section("firmware package \(url.lastPathComponent)") {
        let pkg = try FirmwarePackage.load(url: url)
        check(pkg.firmware.isValid, "integrity checks pass: \(pkg.firmware.checks())")
        check(pkg.firmware.version != nil, "version read from the image")
        check(pkg.firmware.contains(text: "Noble+ EN"), "image is for the Noble+ EN")
        check((pkg.resource?.count ?? 0) > 5_000_000, "resource image extracted")
        var tampered = pkg.firmware.data
        tampered[0x2000] ^= 0x01
        check(!FirmwareImage(data: tampered).isValid, "a flipped bit invalidates the image")
        packages[pkg.firmware.version ?? url.lastPathComponent] = pkg
    }
}

section("erase planning matches the vendor updater") {
    let whole = FirmwareUpdater.eraseRequests(startOffset: 0x20000, byteCount: 0x30000)
    check(whole.map(\.address) == [0xA0000, 0xB0000, 0xC0000] && whole.allSatisfy { $0.kind == 2 },
          "whole blocks are erased 64 KiB at a time")
    let tail = FirmwareUpdater.eraseRequests(startOffset: 0x560000, byteCount: 0xE7B0)
    check(tail.count == 15 && tail.allSatisfy { $0.kind == 0 } && tail.first?.address == 0x5E0000
          && tail.last?.address == 0x5EE000, "a short final block is erased in 4 KiB sectors, rounded up")
}

if let new = packages["1.0.31"] ?? packages.values.first, let resource = new.resource {
    let old = packages["1.0.22"] ?? new

    section("update from \(old.firmware.version ?? "?") to \(new.firmware.version ?? "?") against the simulated bootloader") {
        let boot = MockBootloader(flashContents: old.resource ?? resource)
        let u = updater(boot)
        let before = try u.probe(package: new)
        check(before.identity.bootloaderVersion == "1.1" && before.identity.firmwareVersion == "1.0.22",
              "bootloader and installed version are reported")
        check(boot.eraseLog.isEmpty && boot.appErasedFor == nil && boot.flashWrites == 0, "probing changes nothing")
        let changed = before.differingBlocks.count
        print("    (\(changed) of \(before.imageBlockCRCs.count) resource blocks differ)")

        try u.run(package: new)
        check(boot.app == new.firmware.data, "firmware delivered intact")
        check(boot.appErasedFor == new.firmware.data.count, "application erased with the image size")
        check(boot.flash.prefix(resource.count) == resource, "external flash now equals the new resource image")
        check(boot.resetSeen, "restart sent last")
        check(boot.requests.last?.command == Command.reset.rawValue, "nothing is sent after the restart")
        check(Set(boot.requests.map(\.seq)).count == boot.requests.count && boot.requests.first?.seq == 1,
              "every request has a fresh sequence number, starting at 1")
        let erased = Set(boot.eraseLog.filter { $0.kind == 2 }.map { Int($0.address - 0x80000) / 0x10000 })
        check(erased.isSubset(of: Set(before.differingBlocks)), "only blocks that differ are erased")
        let order = boot.requests.map(\.command)
        let firstErase = order.firstIndex(of: Command.eraseFirmware.rawValue) ?? -1
        let firstFlashErase = order.firstIndex(of: Command.eraseFlashBlock.rawValue) ?? Int.max
        let firstWrite = order.firstIndex(of: Command.writeBlock.rawValue) ?? -1
        let crcCheck = order.firstIndex(of: Command.verifyFirmwareCRC16.rawValue) ?? -1
        check(firstErase > 0 && firstErase < firstFlashErase && firstFlashErase < firstWrite && firstWrite < crcCheck,
              "order: compare, erase firmware, erase flash, write, verify")
        let check8 = boot.requests.first { $0.command == Command.verifyFirmwareCRC16.rawValue }
        check(check8?.b == UInt32(new.firmware.data.count - 2), "CRC request carries length − 2")

        // Running it again on an up-to-date flash rewrites the firmware but no resources.
        let again = MockBootloader(flashContents: resource)
        try updater(again).run(package: new)
        check(again.eraseLog.isEmpty && again.flashWrites == 0, "identical resources are left untouched")
    }

    section("update failure handling") {
        let wrongMode = MockBootloader(flashContents: resource)
        wrongMode.answerFlashCommands = false
        let s = BootloaderSession(transport: wrongMode)
        s.replyTimeout = 0.1
        expectError("normal firmware does not answer flash commands") {
            _ = try FirmwareUpdater(session: s).probe(package: new)
        }
        check(wrongMode.appErasedFor == nil, "nothing erased when the transmitter is not in update mode")

        let tooNew = MockBootloader(flashContents: resource)
        tooNew.bootloaderWord = 0x0001_0003
        expectError("unknown bootloader version refused") { try updater(tooNew).run(package: new) }
        check(tooNew.appErasedFor == nil, "…before erasing anything")

        let bad = MockBootloader(flashContents: resource)
        bad.corruptAppByte = 100
        expectError("firmware CRC mismatch stops the update") { try updater(bad).run(package: new) }
        check(!bad.resetSeen, "…and the transmitter is not restarted into a bad image")

        var broken = new
        var bytes = new.firmware.data
        bytes[0x3000] ^= 0x10
        broken.firmware = FirmwareImage(data: bytes)
        let untouched = MockBootloader(flashContents: resource)
        expectError("damaged image refused") { try updater(untouched).run(package: broken) }
        check(untouched.requests.isEmpty, "…before a single packet is sent")
    }
}

// MARK: - Catalogue

let downloadsPage = fixture("noble-nb4plus-downloads.html")
if let html = try? String(contentsOf: downloadsPage, encoding: .utf8) {
    section("FlySky downloads page") {
        let base = URL(string: "https://www.flysky-cn.com/noble-nb4plus-downloads")!
        let en = Catalogue.releases(inDownloadsPage: html, base: base, region: "EN")
        check(en.map(\.title) == ["1.0.31 FCC", "1.0.31 STD"], "both EN builds of 1.0.31 found (\(en.map(\.title)))")
        check(en.first?.firmwareURL?.absoluteString == "https://www.flysky-cn.com/s/Flysky_NoblePlusEN_UpdateFirmware_1031-4FCC.exe",
              "FCC link resolved")
        check(en.allSatisfy { $0.notesURL?.lastPathComponent.hasPrefix("Release_Notes") == true && $0.source == .website },
              "release notes attached")
        let eu = Catalogue.releases(inDownloadsPage: html, base: base, region: "EU")
        check(eu.count == 2 && eu.allSatisfy { $0.firmwareURL?.absoluteString.contains("EU") == true }, "EU builds kept apart")
    }
}

/// FlySky's real files when present in samples/, else the stand-ins shipped in Fixtures/.
func fixture(_ name: String) -> URL {
    let real = samplesDir.appendingPathComponent("catalogue/\(name)")
    return fm.fileExists(atPath: real.path) ? real : URL(fileURLWithPath: "Fixtures/catalogue/\(name)")
}

let catalogueFile = fixture("OnlineDevice.ini")
if let ini = try? Data(contentsOf: catalogueFile) {
    section("firmware catalogue") {
        let releases = try Catalogue.releases(inCatalogue: ini, productName: "Noble plus EN")
        check(releases.count >= 2, "releases listed")
        check(releases.first?.version == "1.0.22" && releases.first?.variant == "FCC", "first entry is 1.0.22 FCC")
        check(releases.dropFirst().first?.variant == "STD", "second entry is the STD build")
        check(releases.first?.firmwareURL?.absoluteString.contains("%20") == true, "spaces in URLs are escaped")
        check(releases.first?.resourceURL != nil && releases.first?.notesURL != nil, "resource and notes URLs parsed")
        expectError("unknown product") { _ = try Catalogue.releases(inCatalogue: ini, productName: "Nonexistent") }
        check(Catalogue.compare("1.0.22", "1.0.9") == 1 && Catalogue.compare("1.0.9", "1.0.22") == -1
              && Catalogue.compare("1.0.22", "1.0.22") == 0, "version comparison is numeric, not textual")
    }
}

print("")
print(failures == 0 ? "All \(checksRun) checks passed." : "\(failures) of \(checksRun) checks FAILED.")
exit(failures == 0 ? 0 : 1)
