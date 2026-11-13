import Foundation

/// Raw 280-byte report pipe. `HIDTransport` talks to a real transmitter,
/// `MockRadio` simulates one for tests.
public protocol RadioTransport: AnyObject {
    /// Send one output report (exactly `Packet.reportSize` bytes, no report-ID prefix).
    func write(report: Data) throws
    /// Wait for the next input report. Returns nil on timeout.
    func read(timeout: TimeInterval) throws -> Data?
    func close()
}

public enum RadioError: Error, CustomStringConvertible, Equatable {
    case noDevice
    case openFailed(String)
    case ioFailed(String)
    case timeout(String)
    case receiverActive
    case refused(String)
    case unexpected(String)
    case corruptData(String)
    case incompatible(String)
    case cancelled

    public var description: String {
        switch self {
        case .noDevice:
            return "No FlySky transmitter found. Connect it by USB and switch it on."
        case let .openFailed(m): return "Could not open the transmitter: \(m)"
        case let .ioFailed(m): return "USB communication failed: \(m)"
        case let .timeout(m):
            return "The transmitter did not answer (\(m)). Switch it off and on again before retrying – "
                + "after a missed reply its data stream is out of step."
        case .receiverActive:
            return "A receiver is linked to the transmitter. Switch the receiver (model) off and try again."
        case let .refused(m): return "The transmitter refused the request: \(m)"
        case let .unexpected(m): return "Unexpected reply from the transmitter: \(m)"
        case let .corruptData(m): return "Data received from the transmitter is damaged: \(m)"
        case let .incompatible(m): return m
        case .cancelled: return "Cancelled."
        }
    }
}

public struct LinkTiming: Sendable {
    /// Pause after every report we send (the vendor tool sleeps 10 ms).
    public var postSendDelay: TimeInterval = 0.010
    /// How often an idempotent request is repeated while waiting for its reply.
    public var resendInterval: TimeInterval = 0.30
    /// Total patience for an idempotent request.
    public var requestTimeout: TimeInterval = 2.0
    /// Patience for one data chunk. Chunks are never re-sent: the transmitter
    /// streams sequentially and a repeat would shift the data.
    public var chunkTimeout: TimeInterval = 5.0
    /// Patience for the final "commit to storage" step.
    public var commitTimeout: TimeInterval = 15.0

    public init() {}

    public static var instant: LinkTiming {
        var t = LinkTiming()
        t.postSendDelay = 0
        t.resendInterval = 0.05
        t.requestTimeout = 0.2
        t.chunkTimeout = 0.2
        t.commitTimeout = 0.5
        return t
    }
}

/// Packet-level conversation: sequence numbers, logging, request/reply matching.
public final class RadioLink {
    public let transport: RadioTransport
    public var timing: LinkTiming
    /// Receives one line per packet sent or received.
    public var trace: ((String) -> Void)?
    /// Checked between packets; return true to abort the current operation.
    public var isCancelled: () -> Bool = { false }

    private var seq: UInt32 = 2

    public init(transport: RadioTransport, timing: LinkTiming = LinkTiming()) {
        self.transport = transport
        self.timing = timing
    }

    private func nextSeq() -> UInt32 {
        let s = seq
        seq = seq + 1 > 100_000 ? 2 : seq + 1
        return s
    }

    public func send(_ packet: Packet) throws {
        var p = packet
        p.seq = nextSeq()
        trace?("→ " + p.summary)
        try transport.write(report: p.encoded())
        if timing.postSendDelay > 0 { Thread.sleep(forTimeInterval: timing.postSendDelay) }
    }

    /// Read reports until one satisfies `match` or the deadline passes.
    public func receive(until deadline: Date, match: (Packet) -> Bool) throws -> Packet? {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            guard let raw = try transport.read(timeout: min(remaining, 0.1)) else {
                if isCancelled() { throw RadioError.cancelled }
                continue
            }
            let p = Packet(report: raw)
            trace?("← " + p.summary)
            if match(p) { return p }
        }
    }

    /// For requests that are safe to repeat: send, wait, re-send until answered.
    public func request(_ packet: Packet, what: String, timeout: TimeInterval? = nil,
                        match: ((Packet) -> Bool)? = nil) throws -> Packet {
        let accept = match ?? { $0.command == packet.command }
        let deadline = Date().addingTimeInterval(timeout ?? timing.requestTimeout)
        while Date() < deadline {
            if isCancelled() { throw RadioError.cancelled }
            try send(packet)
            let slice = min(deadline, Date().addingTimeInterval(timing.resendInterval))
            if let reply = try receive(until: slice, match: accept) { return reply }
        }
        throw RadioError.timeout(what)
    }

    /// For requests that must reach the transmitter exactly once.
    public func exchangeOnce(_ packet: Packet, what: String, timeout: TimeInterval,
                             match: (Packet) -> Bool) throws -> Packet {
        if isCancelled() { throw RadioError.cancelled }
        try send(packet)
        guard let reply = try receive(until: Date().addingTimeInterval(timeout), match: match) else {
            throw RadioError.timeout(what)
        }
        return reply
    }

    /// Discard anything already queued (stale replies to repeated requests).
    public func drain() {
        while let raw = try? transport.read(timeout: 0.02) {
            trace?("← (drained) " + Packet(report: raw).summary)
        }
    }
}
