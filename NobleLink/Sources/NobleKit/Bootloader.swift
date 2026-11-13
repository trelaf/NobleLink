import Foundation

/// Conversation with the transmitter's bootloader ("update mode").
///
/// This mirrors FlySky's Windows updater (`Flysky_Noble Plus EN_UpdateFirmware_1.0.31-4FCC.exe`,
/// whose code is byte-identical to the 1.0.22 updater apart from the version it
/// displays and the highest bootloader version it accepts):
///
/// * the sequence number starts at 0 and is incremented *before* each request;
/// * every request is sent exactly once;
/// * the reply is the first report whose sequence number equals the request's;
/// * no reply within 2 seconds is a failure.
public final class BootloaderSession {
    public let transport: RadioTransport
    public var trace: ((String) -> Void)?
    public var isCancelled: () -> Bool = { false }
    /// FlySky's updater waits 2 s for every command. We allow more, because
    /// waiting longer for the one reply we need cannot do harm.
    public var replyTimeout: TimeInterval = 10
    private var seq: UInt32 = 0

    public init(transport: RadioTransport) { self.transport = transport }

    public func transact(_ packet: Packet, what: String, timeout: TimeInterval? = nil) throws -> Packet {
        if isCancelled() { throw RadioError.cancelled }
        seq &+= 1
        var p = packet
        p.seq = seq
        trace?("→ " + p.summary)
        try transport.write(report: p.encoded())
        let deadline = Date().addingTimeInterval(timeout ?? replyTimeout)
        while Date() < deadline {
            guard let raw = try transport.read(timeout: min(0.25, max(0.01, deadline.timeIntervalSinceNow))) else { continue }
            let reply = Packet(report: raw)
            trace?("← " + reply.summary)
            if reply.seq == seq { return reply }
        }
        throw RadioError.timeout(what)
    }

    /// Send without waiting (used for the final reset).
    public func sendOnly(_ packet: Packet) throws {
        seq &+= 1
        var p = packet
        p.seq = seq
        trace?("→ " + p.summary)
        try transport.write(report: p.encoded())
    }

    public struct Identity: Sendable {
        /// First payload word of the version reply: high half . low half.
        public var bootloaderWord: UInt32
        public var bootloaderVersion: String { "\(bootloaderWord >> 16).\(bootloaderWord & 0xFFFF)" }
        /// Version of the installed application, nil when none is installed.
        public var firmwareVersion: String?
        public var raw: Data
    }

    /// Highest bootloader version the 1.0.31 updater accepts (0x10002 = "1.2").
    public static let newestKnownBootloader: UInt32 = 0x0001_0002

    /// Command 1, twice, as the vendor updater does when it finds a device.
    public func identify() throws -> Identity {
        _ = try transact(Packet(command: .getVersion), what: "version", timeout: 2)
        let reply = try transact(Packet(command: .getVersion), what: "version", timeout: 2)
        let p = reply.payload
        let hi = p.le32(0x2C), lo = p.le32(0x28)
        var version: String?
        if !(hi == 0xFFFF_FFFF && lo == 0xFFFF_FFFF) {
            // Application version words: major at +0x2E, minor at +0x2B, patch at +0x28.
            version = "\(p[p.startIndex + 0x2E]).\(p[p.startIndex + 0x2B]).\(p[p.startIndex + 0x28])"
        }
        return Identity(bootloaderWord: p.le32(0), firmwareVersion: version, raw: p.prefix(0x30).asData)
    }

    /// Command 6: CRC of a stretch of external flash. Read-only.
    /// `seed` is 0xFFFFFFFF for a fresh CRC, or the previous result to continue one.
    public func flashCRC(address: UInt32, length: UInt32, seed: UInt32 = 0xFFFF_FFFF,
                         timeout: TimeInterval? = nil) throws -> UInt32 {
        let reply = try transact(Packet(command: .verifyFlashCRC32, a: address, b: length, c: seed),
                                 what: String(format: "flash CRC at 0x%X", address), timeout: timeout)
        return reply.c
    }
}

/// Firmware update, step for step as FlySky's Windows updater performs it.
///
///     1. 0x06  CRC of every 64 KiB block of external flash          (read-only)
///     2. 0x03  a = firmware size                                    erase the application
///     3. 0x04  erase only those flash blocks whose CRC differs      (b = 2: 64 KiB, b = 0: 4 KiB)
///     4. 0x05  c = 1  write the firmware in 256-byte pieces
///     5. 0x05  c = 2  write the differing flash blocks
///     6. 0x08  b = size − 2; reply c = CRC16 of the firmware
///     7. 0x06  CRC of the whole resource image, chained across 64 KiB requests
///     8. 0x07  restart
public final class FirmwareUpdater {
    public static let blockSize = 0x10000
    public static let flashBase: UInt32 = FirmwarePackage.resourceBaseAddress

    public let session: BootloaderSession

    public init(session: BootloaderSession) { self.session = session }

    public struct Probe: Sendable {
        public var identity: BootloaderSession.Identity
        /// CRC the transmitter reports for each 64 KiB block of the resource area.
        public var deviceBlockCRCs: [UInt32]
        /// CRC of the same blocks in the image about to be installed.
        public var imageBlockCRCs: [UInt32]
        public var differingBlocks: [Int] {
            zip(deviceBlockCRCs, imageBlockCRCs).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        }
    }

    static func blocks(of data: Data) -> [Data] {
        let d = Data(data)
        return stride(from: 0, to: d.count, by: blockSize).map { d.subdata(in: $0..<min($0 + blockSize, d.count)) }
    }

    /// The CRC the bootloader reports for `data` when asked with seed 0xFFFFFFFF.
    public static func blockCRC(_ data: Data) -> UInt32 { FirmwarePackage.resourceChecksum(data) }

    /// Steps that change nothing: identify the bootloader and compare the external
    /// flash with the image, block by block.
    public func probe(package: FirmwarePackage, progress: ProgressHandler? = nil) throws -> Probe {
        let identity = try session.identify()
        let image = FirmwareUpdater.blocks(of: package.resource ?? Data())
        var device: [UInt32] = []
        for (i, block) in image.enumerated() {
            progress?(Double(i) / Double(max(image.count, 1)), "Comparing resource block \(i + 1) of \(image.count)")
            let address = FirmwareUpdater.flashBase + UInt32(i * FirmwareUpdater.blockSize)
            // The first request also tells us whether this really is the bootloader:
            // the normal firmware does not answer command 6 at all.
            device.append(try session.flashCRC(address: address, length: UInt32(block.count),
                                               timeout: i == 0 ? 3 : nil))
        }
        progress?(1, "Compared")
        return Probe(identity: identity, deviceBlockCRCs: device, imageBlockCRCs: image.map(FirmwareUpdater.blockCRC))
    }

    /// The erase requests for a run of differing blocks, exactly as the updater issues them.
    public static func eraseRequests(startOffset: Int, byteCount: Int) -> [(address: UInt32, kind: UInt32)] {
        var out: [(UInt32, UInt32)] = []
        var address = flashBase + UInt32(startOffset)
        let end = (flashBase + UInt32(startOffset + byteCount) + 0xFFF) & ~UInt32(0xFFF)
        while address < end && address & 0xFFFF != 0 {
            out.append((address, 0)); address += 0x1000
        }
        while address & ~UInt32(0xFFFF) < end & ~UInt32(0xFFFF) {
            out.append((address, 2)); address += 0x10000
        }
        while address < end {
            out.append((address, 0)); address += 0x1000
        }
        return out
    }

    private func write(_ data: Data, at base: UInt32, kind: UInt32, progress: (Int) -> Void) throws {
        let bytes = Data(data)
        var offset = 0
        while offset < bytes.count {
            let address = base + UInt32(offset)
            // Pieces end on 256-byte address boundaries.
            let n = min(bytes.count - offset, 0x100 - Int(address & 0xFF))
            _ = try session.transact(Packet(command: .writeBlock, a: address, b: UInt32(n), c: kind,
                                            payload: bytes.subdata(in: offset..<(offset + n))),
                                     what: String(format: "write at 0x%X", address))
            offset += n
            progress(n)
        }
    }

    /// Perform the update. The transmitter must already be in update mode.
    public func run(package: FirmwarePackage, progress: ProgressHandler? = nil) throws {
        guard package.firmware.isValid else {
            throw RadioError.incompatible("The firmware image failed its integrity checks; refusing to flash it.")
        }
        guard let resource = package.resource, !resource.isEmpty else {
            throw RadioError.incompatible("The update needs the resource image as well as the firmware.")
        }
        let firmware = package.firmware.data

        // 1. What is on the external flash now?
        let state = try probe(package: package) { f, m in progress?(f * 0.05, m) }
        guard state.identity.bootloaderWord <= BootloaderSession.newestKnownBootloader else {
            throw RadioError.incompatible("This transmitter's bootloader (\(state.identity.bootloaderVersion)) is newer "
                + "than the ones this update procedure was written for.")
        }
        let imageBlocks = FirmwareUpdater.blocks(of: resource)
        let differs = zip(state.deviceBlockCRCs, state.imageBlockCRCs).map { $0 != $1 }
        let resourceBytesToWrite = zip(imageBlocks, differs).filter(\.1).reduce(0) { $0 + $1.0.count }
        let totalBytes = Double(firmware.count + resourceBytesToWrite)
        var written = 0.0
        func step(_ n: Int, _ message: String) {
            written += Double(n)
            progress?(0.05 + 0.9 * written / max(totalBytes, 1), message)
        }

        // 2. Erase the application.
        progress?(0.05, "Erasing the old firmware")
        _ = try session.transact(Packet(command: .eraseFirmware, a: UInt32(firmware.count)),
                                 what: "erase firmware", timeout: 60)

        // 3. Erase the flash blocks that will change.
        var i = 0
        while i < imageBlocks.count {
            guard differs[i] else { i += 1; continue }
            var j = i
            var bytes = 0
            while j < imageBlocks.count, differs[j] { bytes += imageBlocks[j].count; j += 1 }
            for request in FirmwareUpdater.eraseRequests(startOffset: i * FirmwareUpdater.blockSize, byteCount: bytes) {
                progress?(0.05, "Erasing resource blocks")
                _ = try session.transact(Packet(command: .eraseFlashBlock, a: request.address, b: request.kind),
                                         what: String(format: "erase flash at 0x%X", request.address), timeout: 30)
            }
            i = j
        }

        // 4. Firmware.
        try write(firmware, at: 0, kind: 1) { step($0, "Writing firmware") }

        // 5. Changed resource blocks.
        for (index, block) in imageBlocks.enumerated() where differs[index] {
            try write(block, at: FirmwareUpdater.flashBase + UInt32(index * FirmwareUpdater.blockSize), kind: 2) {
                step($0, "Writing resources")
            }
        }

        // 6. Firmware check.
        progress?(0.95, "Checking the firmware")
        let expected16 = UInt32(package.firmware.computedCRC)
        let fwCheck = try session.transact(Packet(command: .verifyFirmwareCRC16, b: UInt32(firmware.count - 2)),
                                           what: "firmware CRC", timeout: 30)
        guard fwCheck.c & 0xFFFF == expected16 else {
            throw RadioError.corruptData(String(format: "firmware check failed: transmitter reports 0x%04X, "
                + "image is 0x%04X. The transmitter stays in update mode; run the update again.", fwCheck.c & 0xFFFF, expected16))
        }

        // 7. Resource check, chained across 64 KiB requests.
        var crc: UInt32 = 0xFFFF_FFFF
        for (index, block) in imageBlocks.enumerated() {
            progress?(0.95 + 0.05 * Double(index) / Double(imageBlocks.count), "Checking the resources")
            crc = try session.flashCRC(address: FirmwareUpdater.flashBase + UInt32(index * FirmwareUpdater.blockSize),
                                       length: UInt32(block.count), seed: crc)
        }
        let expected32 = FirmwarePackage.resourceChecksum(resource)
        guard crc == expected32 else {
            throw RadioError.corruptData(String(format: "resource check failed: transmitter reports 0x%08X, "
                + "image is 0x%08X. The transmitter stays in update mode; run the update again.", crc, expected32))
        }

        // 8. Restart into the new firmware.
        progress?(1, "Restarting the transmitter")
        try? session.sendOnly(Packet(command: .reset))
    }

    /// Leave update mode without changing anything (the same restart request).
    public func restart() {
        try? session.sendOnly(Packet(command: .reset))
    }
}
