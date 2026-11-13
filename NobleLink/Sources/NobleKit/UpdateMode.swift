import Foundation

/// Helpers shared by the command-line tool and the app for getting from a
/// running transmitter to its bootloader ("update mode").
public enum UpdateMode {
    /// What the wait loop currently sees.
    public enum Seen: Equatable, Sendable {
        case noDevice
        case normalFirmware
    }

    public static func describe(_ seen: Seen) -> String {
        switch seen {
        case .noDevice: return "no transmitter visible on USB"
        case .normalFirmware: return "the transmitter is still running its normal firmware (not in update mode)"
        }
    }

    public static let instruction = "On the transmitter: System → Firmware Update → YES."

    /// Poll until something answers the bootloader's read-only checksum command
    /// (the normal firmware ignores it). Returns the open transport, or nil when
    /// cancelled or timed out. `status` is called whenever the state changes and
    /// otherwise every `reminderInterval` seconds.
    public static func waitForBootloader(timeout: TimeInterval,
                                         reminderInterval: TimeInterval = 20,
                                         pollInterval: TimeInterval = 1.5,
                                         open: () -> RadioTransport? = { try? HIDTransport.openFirst() },
                                         trace: ((String) -> Void)? = nil,
                                         isCancelled: () -> Bool = { false },
                                         status: (Seen, TimeInterval) -> Void) -> RadioTransport? {
        let started = Date()
        var last: Seen?
        var lastReport = Date.distantPast
        while Date().timeIntervalSince(started) < timeout {
            if isCancelled() { return nil }
            var seen = Seen.noDevice
            if let hid = open() {
                let session = BootloaderSession(transport: hid)
                session.trace = trace
                if (try? session.flashCRC(address: FirmwareUpdater.flashBase, length: 16, timeout: 2)) != nil {
                    return hid
                }
                seen = .normalFirmware
                hid.close()
            }
            if seen != last || Date().timeIntervalSince(lastReport) >= reminderInterval {
                status(seen, Date().timeIntervalSince(started))
                last = seen
                lastReport = Date()
            }
            // Sleep in small steps so cancelling is quick.
            let until = Date().addingTimeInterval(pollInterval)
            while Date() < until {
                if isCancelled() { return nil }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        return nil
    }
}

extension FirmwarePackage {
    /// How the firmware names the transmitter it is built for, for each product
    /// name used by `Products`. Each image contains only its own name.
    static let imageNames: [String: String] = [
        "Noble plus EN": "Noble+ EN",
        "Noble plus EU": "Noble+ EU",
        "Noble plus CN": "Noble+ CN",
    ]

    /// true / false when known, nil when this product's image name is not known.
    public func isBuilt(for productName: String) -> Bool? {
        guard let text = FirmwarePackage.imageNames[productName] else { return nil }
        return firmware.contains(text: text)
    }

    /// Name of the transmitter the image is built for, if recognised.
    public var builtFor: String? {
        FirmwarePackage.imageNames.first { firmware.contains(text: $0.value) }?.key
    }
}
