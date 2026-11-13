import Foundation

/// Stand-in for the bootloader, strict enough to catch a wrong update procedure:
/// flash behaves like NOR flash (writing can only clear bits, so a missing erase
/// shows up as corrupt data) and replies carry the request's sequence number.
public final class MockBootloader: RadioTransport {
    public var flash: Data                       // external flash from 0x80000
    public var app = Data()                      // internal application area
    public var appErasedFor: Int?
    public var eraseLog: [(address: UInt32, kind: UInt32)] = []
    public var flashWrites = 0
    public var resetSeen = false
    public var bootloaderWord: UInt32 = 0x0001_0001
    public var installedVersion: (UInt8, UInt8, UInt8)? = (1, 0, 22)
    public var answerFlashCommands = true        // false = behave like the normal firmware
    public var corruptAppByte: Int?
    public var requests: [Packet] = []
    private var pending: [Data] = []

    public init(flashContents: Data) {
        flash = flashContents
        if flash.count % 0x10000 != 0 { flash.append(Data(repeating: 0xFF, count: 0x10000 - flash.count % 0x10000)) }
    }

    public func write(report: Data) throws {
        let p = Packet(report: report)
        requests.append(p)
        var r = Packet(seq: p.seq, command: p.command, a: p.a, b: p.b, c: p.c, d: p.d)
        switch Command(rawValue: p.command) {
        case .getVersion:
            var block = Data(count: 0x30)
            block.replaceSubrange(0..<4, with: withUnsafeBytes(of: bootloaderWord.littleEndian) { Data($0) })
            if let v = installedVersion {
                block[0x28] = v.2; block[0x2B] = v.1; block[0x2E] = v.0
            } else {
                block.replaceSubrange(0x28..<0x30, with: Data(repeating: 0xFF, count: 8))
            }
            r = Packet(seq: p.seq, command: p.command, payload: block)
        case .verifyFlashCRC32:
            guard answerFlashCommands else { return }
            let start = Int(p.a) - 0x80000
            r.c = Checksums.crc32(flash.subdata(in: start..<(start + Int(p.b))), seed: p.c)
        case .eraseFirmware:
            guard answerFlashCommands else { return }
            app = Data(repeating: 0xFF, count: Int(p.a))
            appErasedFor = Int(p.a)
        case .eraseFlashBlock:
            guard answerFlashCommands else { return }
            eraseLog.append((p.a, p.b))
            let size = p.b == 2 ? 0x10000 : 0x1000
            let start = Int(p.a) - 0x80000
            precondition(start % size == 0, "erase address not aligned to its block size")
            flash.replaceSubrange(start..<(start + size), with: Data(repeating: 0xFF, count: size))
        case .writeBlock:
            guard answerFlashCommands else { return }
            let n = Int(p.b)
            precondition(Int(p.a & 0xFF) + n <= 0x100, "write crosses a 256-byte boundary")
            let chunk = [UInt8](p.payload.prefix(n))
            if p.c == 1 {
                for k in 0..<n { app[Int(p.a) + k] &= chunk[k] }
            } else {
                flashWrites += 1
                let start = Int(p.a) - 0x80000
                for k in 0..<n { flash[start + k] &= chunk[k] }
            }
        case .verifyFirmwareCRC16:
            guard answerFlashCommands else { return }
            var f = app.prefix(Int(p.b))
            if let i = corruptAppByte { f[f.startIndex + i] ^= 1 }
            r.c = UInt32(Checksums.crc16CCITT(Data(f)))
        case .reset:
            resetSeen = true
            return
        default:
            return
        }
        pending.append(r.encoded())
    }
    public func read(timeout: TimeInterval) throws -> Data? { pending.isEmpty ? nil : pending.removeFirst() }
    public func close() {}
}

