import Foundation

/// Byte ring holding the most recent interleaved 8-bit IQ from whichever source is active.
final class Ring {
    let size = 16 * 1024 * 1024          // ~420 ms at 20 Msps
    private let buf: UnsafeMutablePointer<Int8>
    private var total = 0                // bytes ever written; also the stream clock
    private let lock = NSLock()

    init() {
        buf = .allocate(capacity: size)
        buf.initialize(repeating: 0, count: size)
    }

    deinit { buf.deallocate() }

    var bytesWritten: Int {
        lock.lock(); defer { lock.unlock() }
        return total
    }

    func write(_ p: UnsafeRawPointer, _ n: Int) {
        lock.lock(); defer { lock.unlock() }
        var src = p.assumingMemoryBound(to: Int8.self)
        var left = n
        while left > 0 {
            let i = total % size
            let k = min(left, size - i)
            (buf + i).update(from: src, count: k)
            src += k; left -= k; total += k
        }
    }

    /// Copies the newest `n` bytes (IQ-pair aligned) into `out`. Returns the stream offset of their end.
    func latest(_ n: Int, into out: UnsafeMutablePointer<Int8>) -> Int? {
        lock.lock(); defer { lock.unlock() }
        let end = total & ~1
        guard end >= n else { return nil }
        let s = (end - n) % size
        let k = min(n, size - s)
        out.update(from: buf + s, count: k)
        if k < n { (out + k).update(from: buf, count: n - k) }
        return end
    }
}

enum RadioError: LocalizedError {
    case call(String, Int32)
    case badFile(String)

    var errorDescription: String? {
        switch self {
        case let .call(what, code):
            let name = hackrf_error_name(hackrf_error(rawValue: code)).map { String(cString: $0) } ?? "\(code)"
            if what == "hackrf_open" && code == HACKRF_ERROR_NOT_FOUND.rawValue { return "No HackRF found" }
            if what == "hackrf_open" && code == HACKRF_ERROR_LIBUSB.rawValue {
                return "HackRF is busy (another program may be using it)"
            }
            return "\(what) failed: \(name)"
        case let .badFile(msg): return msg
        }
    }
}

/// Direct libhackrf control: frequency and gains change live, with no stream restart.
final class HackRFDevice {
    private var dev: OpaquePointer?
    private let ring: Ring
    private static var libraryReady = false

    init(ring: Ring) { self.ring = ring }

    private func check(_ r: Int32, _ what: String) throws {
        if r != HACKRF_SUCCESS.rawValue { throw RadioError.call(what, r) }
    }

    func open() throws {
        if !Self.libraryReady {
            try check(hackrf_init(), "hackrf_init")
            Self.libraryReady = true
        }
        var d: OpaquePointer?
        try check(hackrf_open(&d), "hackrf_open")
        dev = d
    }

    func start(freq: UInt64, amp: Bool, lna: Int, vga: Int) throws {
        guard let dev else { throw RadioError.call("hackrf_open", HACKRF_ERROR_NOT_FOUND.rawValue) }
        try check(hackrf_set_sample_rate(dev, 20_000_000), "hackrf_set_sample_rate")
        try check(hackrf_set_baseband_filter_bandwidth(dev, hackrf_compute_baseband_filter_bw(15_000_000)),
                  "hackrf_set_baseband_filter_bandwidth")
        try check(hackrf_set_freq(dev, freq), "hackrf_set_freq")
        try check(hackrf_set_amp_enable(dev, amp ? 1 : 0), "hackrf_set_amp_enable")
        try check(hackrf_set_lna_gain(dev, UInt32(lna)), "hackrf_set_lna_gain")
        try check(hackrf_set_vga_gain(dev, UInt32(vga)), "hackrf_set_vga_gain")
        let ctx = Unmanaged.passUnretained(ring).toOpaque()
        try check(hackrf_start_rx(dev, { t in
            guard let t, let ctx = t.pointee.rx_ctx else { return 0 }
            Unmanaged<Ring>.fromOpaque(ctx).takeUnretainedValue()
                .write(t.pointee.buffer, Int(t.pointee.valid_length))
            return 0
        }, ctx), "hackrf_start_rx")
    }

    func setFrequency(_ hz: UInt64) { if let dev { _ = hackrf_set_freq(dev, hz) } }
    func setAmp(_ on: Bool) { if let dev { _ = hackrf_set_amp_enable(dev, on ? 1 : 0) } }
    func setLNA(_ db: Int) { if let dev { _ = hackrf_set_lna_gain(dev, UInt32(db)) } }
    func setVGA(_ db: Int) { if let dev { _ = hackrf_set_vga_gain(dev, UInt32(db)) } }

    var isStreaming: Bool {
        guard let dev else { return false }
        return hackrf_is_streaming(dev) == HACKRF_TRUE.rawValue
    }

    func close() {
        if let dev {
            _ = hackrf_stop_rx(dev)
            _ = hackrf_close(dev)
        }
        dev = nil
    }
}

/// Replays a 20 Msps int8 IQ capture into the ring at the real 40 MB/s rate, looping.
final class FileSource {
    let url: URL
    private let ring: Ring
    private let data: Data
    private let lock = NSLock()
    private var stopped = false

    init(url: URL, ring: Ring) throws {
        self.url = url
        self.ring = ring
        data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 8_000_000 else {
            throw RadioError.badFile("\(url.lastPathComponent) is too short to be a 20 Msps IQ capture")
        }
    }

    func start() {
        let t = Thread { [self] in run() }
        t.qualityOfService = .userInitiated
        t.start()
    }

    func stop() { lock.lock(); stopped = true; lock.unlock() }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func run() {
        let chunk = 1 << 20
        let t0 = CFAbsoluteTimeGetCurrent()
        var pos = 0, sent = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while !isStopped {
                if pos + chunk > raw.count { pos = 0 }
                ring.write(base + pos, chunk)
                pos += chunk; sent += chunk
                let ahead = Double(sent) / 40_000_000 - (CFAbsoluteTimeGetCurrent() - t0)
                if ahead > 0 { Thread.sleep(forTimeInterval: ahead) }
            }
        }
    }
}
