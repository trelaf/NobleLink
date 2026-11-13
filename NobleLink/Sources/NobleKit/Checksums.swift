import Foundation

public enum Checksums {
    /// CRC-16/CCITT-FALSE: polynomial 0x1021, initial value 0xFFFF, MSB first, no final XOR.
    /// This is `SendorUpdateThread::ComputeCRC16`; the last two bytes of a firmware
    /// image hold this CRC (little-endian) of everything before them.
    public static func crc16CCITT(_ data: Data, initial: UInt16 = 0xFFFF) -> UInt16 {
        var crc = initial
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    private static let crc32Table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// `SendorUpdateThread::ComputeCRC32(seed, data)`: reflected CRC-32 (polynomial
    /// 0xEDB88320) whose register starts at `seed ^ 0xFFFFFFFF` and is inverted at
    /// the end. Seed 0 gives the standard zlib / IEEE 802.3 CRC-32.
    public static func crc32(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        var c = seed ^ 0xFFFF_FFFF
        for byte in data {
            c = crc32Table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    /// XOR of all bytes – the trailing check byte of a parameter record.
    public static func xor8<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(0, ^)
    }
}
