import Foundation
import IOKit
import IOKit.hid

/// One HID interface of a connected FlySky device.
public struct HIDDeviceDescription: Sendable, CustomStringConvertible {
    public var vendorID: UInt16
    public var productID: UInt16
    public var product: String
    public var manufacturer: String
    public var serial: String
    public var usagePage: Int
    public var usage: Int
    public var maxInputReport: Int
    public var maxOutputReport: Int
    public var locationID: Int

    public var productName: String { Products.name(forProductID: productID) }
    public var isKnownTransmitter: Bool { Products.product(forProductID: productID) != nil }

    public var description: String {
        String(format: "%@ [%04X:%04X] \"%@\" usage %04X:%04X in=%d out=%d loc=%08X",
               productName, vendorID, productID, product, usagePage, usage, maxInputReport, maxOutputReport,
               locationID)
    }
}

/// USB HID transport built directly on IOKit (no third-party libraries).
///
/// The transmitter uses un-numbered 280-byte reports in both directions, so
/// output goes out with report ID 0 and input arrives without a prefix.
public final class HIDTransport: RadioTransport {
    public let description: HIDDeviceDescription
    private let device: IOHIDDevice
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputBufferSize: Int
    private let condition = NSCondition()
    private var queue: [Data] = []
    private var removed = false
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var isOpen = false

    // MARK: Discovery

    private static func manager() -> IOHIDManager {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // FlySky's own vendor ID, plus the alternative one its firmware updater
        // also accepts (evidently the bootloader's identity on some units).
        let matches: [[String: Any]] = [
            [kIOHIDVendorIDKey: Int(Products.vendorID)],
            [kIOHIDVendorIDKey: Int(Products.bootloaderVendorID)],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
        return m
    }

    private static func describe(_ d: IOHIDDevice) -> HIDDeviceDescription {
        func int(_ key: String) -> Int { (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? 0 }
        // Keep printable ASCII only: the bootloader's USB name string is malformed
        // ("Flysk" followed by stray bytes).
        func str(_ key: String) -> String {
            let raw = IOHIDDeviceGetProperty(d, key as CFString) as? String ?? ""
            return String(String.UnicodeScalarView(raw.unicodeScalars.prefix { $0.value >= 0x20 && $0.value < 0x7F }))
                .trimmingCharacters(in: .whitespaces)
        }
        return HIDDeviceDescription(
            vendorID: UInt16(truncatingIfNeeded: int(kIOHIDVendorIDKey)),
            productID: UInt16(truncatingIfNeeded: int(kIOHIDProductIDKey)),
            product: str(kIOHIDProductKey), manufacturer: str(kIOHIDManufacturerKey),
            serial: str(kIOHIDSerialNumberKey), usagePage: int(kIOHIDPrimaryUsagePageKey),
            usage: int(kIOHIDPrimaryUsageKey), maxInputReport: int(kIOHIDMaxInputReportSizeKey),
            maxOutputReport: int(kIOHIDMaxOutputReportSizeKey), locationID: int(kIOHIDLocationIDKey))
    }

    private static func candidates() -> [(IOHIDDevice, HIDDeviceDescription)] {
        let m = manager()
        guard let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else { return [] }
        return set.map { ($0, describe($0)) }
            // The second vendor ID is not FlySky's alone: only accept known transmitters under it.
            .filter { $0.1.vendorID == Products.vendorID || $0.1.isKnownTransmitter }
            .sorted { score($0.1) > score($1.1) }
    }

    /// Prefer the interface that can actually carry our 280-byte reports.
    private static func score(_ d: HIDDeviceDescription) -> Int {
        var s = 0
        if d.isKnownTransmitter { s += 8 }
        if d.maxOutputReport >= Packet.reportSize { s += 4 }
        if d.maxInputReport >= Packet.reportSize { s += 2 }
        if d.usagePage >= 0xFF00 { s += 1 }
        return s
    }

    /// Every HID interface exposed by FlySky devices currently connected.
    public static func connectedDevices() -> [HIDDeviceDescription] {
        candidates().map(\.1)
    }

    /// Open the best-matching interface.
    public static func openFirst() throws -> HIDTransport {
        guard let (device, desc) = candidates().first else { throw RadioError.noDevice }
        let t = HIDTransport(device: device, description: desc)
        try t.open()
        return t
    }

    private init(device: IOHIDDevice, description: HIDDeviceDescription) {
        self.device = device
        self.description = description
        inputBufferSize = max(description.maxInputReport, Packet.reportSize) + 8
        inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
        inputBuffer.initialize(repeating: 0, count: inputBufferSize)
    }

    deinit {
        close()
        inputBuffer.deallocate()
    }

    // MARK: Open / close

    private func open() throws {
        let rc = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard rc == kIOReturnSuccess else {
            throw RadioError.openFailed(String(format: "IOHIDDeviceOpen returned 0x%08X", rc))
        }
        isOpen = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, inputBufferSize, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            let me = Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue()
            me.enqueue(Data(bytes: report, count: length))
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { ctx, _, _ in
            guard let ctx else { return }
            Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue().markRemoved()
        }, context)

        // Input reports are delivered on a run loop; give them a private thread.
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self else { return }
            guard let rl = CFRunLoopGetCurrent() else { ready.signal(); return }
            self.runLoop = rl
            IOHIDDeviceScheduleWithRunLoop(self.device, rl, CFRunLoopMode.defaultMode.rawValue)
            ready.signal()
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
            IOHIDDeviceUnscheduleFromRunLoop(self.device, rl, CFRunLoopMode.defaultMode.rawValue)
        }
        t.name = "NobleKit.HID"
        t.start()
        thread = t
        ready.wait()
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        thread?.cancel()
        if let rl = runLoop { CFRunLoopStop(rl) }
        // Let the reader thread unschedule before the device is closed.
        Thread.sleep(forTimeInterval: 0.3)
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, inputBufferSize, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func enqueue(_ data: Data) {
        condition.lock()
        queue.append(data)
        condition.signal()
        condition.unlock()
    }

    private func markRemoved() {
        condition.lock()
        removed = true
        condition.broadcast()
        condition.unlock()
    }

    // MARK: RadioTransport

    public func write(report: Data) throws {
        guard isOpen, !removed else { throw RadioError.ioFailed("the transmitter was disconnected") }
        precondition(report.count == Packet.reportSize)
        let rc = report.withUnsafeBytes { raw -> IOReturn in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0,
                                 raw.bindMemory(to: UInt8.self).baseAddress!, report.count)
        }
        guard rc == kIOReturnSuccess else {
            throw RadioError.ioFailed(String(format: "sending a report failed (0x%08X)", rc))
        }
    }

    public func read(timeout: TimeInterval) throws -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty {
            if removed { throw RadioError.ioFailed("the transmitter was disconnected") }
            if !condition.wait(until: deadline) { return nil }
        }
        return queue.removeFirst()
    }
}
