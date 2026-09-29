import AppKit
import Foundation

struct Band: Hashable {
    let letter: String    // as shown on the VTX's LED display
    let title: String
    let mhz: [Int]
}

struct Channel: Identifiable, Hashable {
    let number: Int       // 1...48, internal ordering
    let band: Band
    let index: Int        // 1...8 within the band
    let mhz: Int
    var id: Int { number }
    var name: String { "\(band.letter):\(index)" }            // matches the VTX display, e.g. H:1
    var fileTag: String { "\(band.letter)\(index)" }
    var label: String { "\(name)  \(mhz) MHz" }
}

enum Channels {
    // Letters follow the JJPRO P175 VTX display: C is Boscam E, D is FatShark, H is RaceBand.
    static let bands: [Band] = [
        Band(letter: "A", title: "Boscam A", mhz: [5865, 5845, 5825, 5805, 5785, 5765, 5745, 5725]),
        Band(letter: "B", title: "Boscam B", mhz: [5733, 5752, 5771, 5790, 5809, 5828, 5847, 5866]),
        Band(letter: "C", title: "Boscam E", mhz: [5705, 5685, 5665, 5645, 5885, 5905, 5925, 5945]),
        Band(letter: "D", title: "FatShark", mhz: [5740, 5760, 5780, 5800, 5820, 5840, 5860, 5880]),
        Band(letter: "H", title: "RaceBand", mhz: [5658, 5695, 5732, 5769, 5806, 5843, 5880, 5917]),
        Band(letter: "L", title: "Low Band", mhz: [5362, 5399, 5436, 5473, 5510, 5547, 5584, 5621]),
    ]
    static let all: [Channel] = bands.enumerated().flatMap { b, band in
        band.mhz.enumerated().map { i, mhz in Channel(number: b * 8 + i + 1, band: band, index: i + 1, mhz: mhz) }
    }
    static var count: Int { all.count }
    static func channel(_ n: Int) -> Channel { all[min(max(n, 1), count) - 1] }
}

enum SourceState: Equatable {
    case starting
    case live
    case noDevice(String)
    case file(String)
}

enum ScanState: Equatable {
    case idle
    case scanning(Double)
    case found(channel: Int, carrierMHz: Double)
    case notFound
}

struct LiveStats {
    var decode = DecodeStats()
    var usbMBps = 0.0
    var fps = 0.0
    var decodeMs = 0.0
    var heldFields = 0
}

// MARK: - Engine: owns the ring, the source and the decode thread

final class Engine {
    static let tuneOffsetHz = 3_500_000   // keep the HackRF DC spur off the carrier
    let ring = Ring()
    var device: HackRFDevice?
    var file: FileSource?

    private let decoder = PALDecoder()
    private let lock = NSLock()
    private var options = DecodeOptions()
    private var settleUntil = 0
    private var paused = false
    private var needsReset = false
    private var recorder: Recorder?

    /// Called on the decode thread.
    var onFrame: (([UInt8], DecodeStats, Double) -> Void)?
    var onHeld: (() -> Void)?
    var onNoFrame: ((DecodeStats) -> Void)?

    func start() {
        let t = Thread { [self] in loop() }
        t.qualityOfService = .userInteractive
        t.name = "fpv.decode"
        t.start()
    }

    func setOptions(_ o: DecodeOptions) { lock.lock(); options = o; lock.unlock() }
    func setRecorder(_ r: Recorder?) { lock.lock(); recorder = r; lock.unlock() }

    /// Skip samples captured before `now + 20 ms` and forget per-channel decoder state.
    func markRetune() {
        let mark = ring.bytesWritten + Int(2 * 0.02 * PALDecoder.sampleRate)
        lock.lock(); settleUntil = mark; needsReset = true; lock.unlock()
    }

    private func loop() {
        let nBytes = 2 * PALDecoder.blockSamples
        let raw = UnsafeMutablePointer<Int8>.allocate(capacity: nBytes)
        var lastEnd = -1
        while true {
            lock.lock()
            let (opts, settle, isPaused, reset, rec) = (options, settleUntil, paused, needsReset, recorder)
            needsReset = false
            lock.unlock()
            if isPaused { Thread.sleep(forTimeInterval: 0.02); continue }
            guard let end = ring.latest(nBytes, into: raw), end != lastEnd, end - nBytes >= settle else {
                Thread.sleep(forTimeInterval: 0.004); continue
            }
            lastEnd = end
            if reset { decoder.reset() }
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                if let img = try decoder.decode(raw, samples: PALDecoder.blockSamples, options: opts) {
                    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    rec?.append(img, width: PALDecoder.width, height: PALDecoder.height,
                                seconds: Double(end) / (2 * PALDecoder.sampleRate))
                    onFrame?(img, decoder.stats, ms)
                } else {
                    onNoFrame?(decoder.stats)
                }
            } catch {
                onHeld?()
            }
        }
    }

    /// Steps through `mhz` looking for PAL sync; returns (channel MHz, measured carrier MHz) for locks.
    func scan(_ mhz: [Int], progress: @escaping (Double) -> Void) -> [(Int, Double)] {
        guard let device else { return [] }
        lock.lock(); paused = true; lock.unlock()
        defer { lock.lock(); paused = false; lock.unlock() }
        let nBytes = 2 * PALDecoder.blockSamples
        let raw = UnsafeMutablePointer<Int8>.allocate(capacity: nBytes)
        defer { raw.deallocate() }
        var found = [(Int, Double)]()
        for (i, f) in mhz.enumerated() {
            progress(Double(i) / Double(mhz.count))
            let tuned = f * 1_000_000 + Self.tuneOffsetHz
            device.setFrequency(UInt64(tuned))
            let ready = ring.bytesWritten + Int(2 * 0.02 * PALDecoder.sampleRate) + nBytes
            let deadline = Date().addingTimeInterval(1)
            while ring.bytesWritten < ready && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            guard ring.latest(nBytes, into: raw) != nil else { continue }
            let probe = PALDecoder()
            _ = try? probe.decode(raw, samples: PALDecoder.blockSamples,
                                  options: DecodeOptions(color: false, saturation: 1, weave: false, repairBands: false))
            if probe.stats.lock > 0.9 {
                found.append((f, (Double(tuned) + probe.stats.carrierOffsetHz) / 1e6))
            }
        }
        progress(1)
        return found
    }
}

// MARK: - Receiver: the UI model

final class Receiver: ObservableObject {
    static let shared = Receiver()
    let engine = Engine()
    private let defaults = UserDefaults.standard

    @Published var channel: Int { didSet { defaults.set(channel, forKey: "channel"); retune() } }
    @Published var ampOn: Bool { didSet { defaults.set(ampOn, forKey: "amp"); engine.device?.setAmp(ampOn) } }
    @Published var lna: Int { didSet { defaults.set(lna, forKey: "lna"); engine.device?.setLNA(lna) } }
    @Published var vga: Int { didSet { defaults.set(vga, forKey: "vga"); engine.device?.setVGA(vga) } }
    @Published var autoGain: Bool { didSet { defaults.set(autoGain, forKey: "autoGain") } }
    @Published var color: Bool { didSet { defaults.set(color, forKey: "color"); pushOptions() } }
    @Published var saturation: Double { didSet { defaults.set(saturation, forKey: "saturation"); pushOptions() } }
    @Published var weave: Bool { didSet { defaults.set(weave, forKey: "weave"); pushOptions() } }
    @Published var repairBands: Bool { didSet { defaults.set(repairBands, forKey: "repair"); pushOptions() } }
    /// "auto", "PAL" or "NTSC"
    @Published var standardSetting: String { didSet { defaults.set(standardSetting, forKey: "standard"); pushOptions() } }

    @Published var image: CGImage?
    @Published var stats = LiveStats()
    @Published var hasSignal = false
    @Published var source: SourceState = .starting
    @Published var recording: Recorder?
    @Published var recordingStarted: Date?
    @Published var scan: ScanState = .idle
    @Published var notice: String?
    @Published var showInspector = true

    private var lastFrame = Date.distantPast
    private var lastBytes = 0
    private var framePending = false          // guarded by pendingLock (touched by the decode thread)
    private let pendingLock = NSLock()
    private var retryTicks = 0
    private var noticeTask: DispatchWorkItem?

    var current: Channel { Channels.channel(channel) }
    var tunedHz: Int { current.mhz * 1_000_000 + Engine.tuneOffsetHz }

    private init() {
        defaults.register(defaults: ["channel": 5, "amp": true, "lna": 32, "vga": 30, "autoGain": false,
                                     "color": true, "saturation": 1.0, "weave": false, "repair": true,
                                     "standard": "auto"])
        channel = defaults.integer(forKey: "channel")
        ampOn = defaults.bool(forKey: "amp")
        lna = defaults.integer(forKey: "lna")
        vga = defaults.integer(forKey: "vga")
        autoGain = defaults.bool(forKey: "autoGain")
        color = defaults.bool(forKey: "color")
        saturation = defaults.double(forKey: "saturation")
        weave = defaults.bool(forKey: "weave")
        repairBands = defaults.bool(forKey: "repair")
        standardSetting = defaults.string(forKey: "standard") ?? "auto"

        engine.onFrame = { [weak self] bgra, st, ms in self?.deliver(bgra, st, ms) }
        engine.onHeld = { [weak self] in DispatchQueue.main.async { self?.stats.heldFields += 1 } }
        engine.onNoFrame = { [weak self] st in DispatchQueue.main.async { self?.stats.decode = st } }
        pushOptions()
        engine.start()
        connect()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: sources

    func connect() {
        engine.file?.stop(); engine.file = nil
        engine.device?.close(); engine.device = nil
        let dev = HackRFDevice(ring: engine.ring)
        do {
            try dev.open()
            try dev.start(freq: UInt64(tunedHz), amp: ampOn, lna: lna, vga: vga)
            engine.device = dev
            engine.markRetune()
            source = .live
        } catch {
            dev.close()
            source = .noDevice(error.localizedDescription)
        }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.title = "Open IQ Recording"
        panel.message = "Choose a 20 Msps, 8-bit signed IQ capture (hackrf_transfer -r)."
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let f = try FileSource(url: url, ring: engine.ring)
            engine.device?.close(); engine.device = nil
            engine.file?.stop()
            engine.file = f
            engine.markRetune()
            f.start()
            source = .file(url.lastPathComponent)
        } catch {
            show(error.localizedDescription)
        }
    }

    private func retune() {
        engine.device?.setFrequency(UInt64(tunedHz))
        engine.markRetune()
        hasSignal = false
        if case .found = scan {} else { scan = .idle }
    }

    func step(_ delta: Int) { channel = (channel - 1 + delta + Channels.count) % Channels.count + 1 }

    private func pushOptions() {
        engine.setOptions(DecodeOptions(color: color, saturation: Float(saturation), weave: weave,
                                        repairBands: repairBands,
                                        standard: VideoStandard(rawValue: standardSetting)))
    }

    // MARK: frames

    private func deliver(_ bgra: [UInt8], _ st: DecodeStats, _ ms: Double) {
        // drop frames if the main thread has not drawn the previous one yet
        pendingLock.lock()
        let skip = framePending
        framePending = true
        pendingLock.unlock()
        if skip { return }
        let img = Self.makeImage(bgra)
        DispatchQueue.main.async { [self] in
            pendingLock.lock(); framePending = false; pendingLock.unlock()
            image = img
            let now = Date()
            let dt = now.timeIntervalSince(lastFrame)
            lastFrame = now
            hasSignal = true
            stats.decode = st
            stats.decodeMs = stats.decodeMs * 0.9 + ms * 0.1
            if dt < 2 { stats.fps = stats.fps * 0.9 + 0.1 / max(dt, 0.001) }
        }
    }

    static func makeImage(_ bgra: [UInt8]) -> CGImage? {
        let w = PALDecoder.width, h = PALDecoder.height
        guard let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: periodic housekeeping

    private func tick() {
        let bytes = engine.ring.bytesWritten
        stats.usbMBps = Double(bytes - lastBytes) / 0.5 / 1e6
        lastBytes = bytes
        if Date().timeIntervalSince(lastFrame) > 1 { hasSignal = false }

        switch source {
        case .live:
            if let dev = engine.device, !dev.isStreaming {
                dev.close(); engine.device = nil
                source = .noDevice("HackRF disconnected")
            }
        case .noDevice, .starting:
            retryTicks += 1
            if retryTicks % 4 == 0 { connect() }      // quietly retry every 2 s
            return
        case .file:
            return
        }

        let level = stats.decode.dbfs
        guard hasSignal || level > -60 else { return }
        // front-end protection: never keep the RF amp on with a hot signal
        if ampOn && level > -6 {
            ampOn = false
            show("Signal very strong (\(String(format: "%.0f", level)) dBFS): RF amplifier switched off")
        }
        // automatic gain: hold the ADC level in a comfortable window using VGA first, then LNA
        if autoGain {
            if level > -12 {
                if vga >= 2 { vga -= 2 } else if lna >= 8 { lna -= 8 }
            } else if level < -24 {
                if vga <= 60 { vga += 2 } else if lna <= 32 { lna += 8 }
            }
        }
    }

    // MARK: recording and snapshots

    static var recordingsFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FPV Receiver", isDirectory: true)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    func toggleRecording() {
        if let r = recording {
            engine.setRecorder(nil)
            recording = nil
            recordingStarted = nil
            r.finish { [weak self] url, frames in
                DispatchQueue.main.async {
                    self?.show(frames > 0 ? "Saved \(url.lastPathComponent)" : "Recording was empty")
                    if frames == 0 { try? FileManager.default.removeItem(at: url) }
                }
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
            let url = Self.recordingsFolder.appendingPathComponent("FPV \(Self.stamp()) \(current.fileTag).mp4")
            let r = try Recorder(url: url, width: PALDecoder.width, height: PALDecoder.height)
            engine.setRecorder(r)
            recording = r
            recordingStarted = Date()
        } catch {
            show("Could not start recording: \(error.localizedDescription)")
        }
    }

    func snapshot() {
        guard let img = image else { return }
        let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FPV Receiver", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("FPV \(Self.stamp()) \(current.fileTag).png")
            guard let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
            try png.write(to: url)
            show("Snapshot saved to Pictures/FPV Receiver")
        } catch {
            show("Could not save snapshot: \(error.localizedDescription)")
        }
    }

    func revealRecordings() {
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.recordingsFolder)
    }

    // MARK: scanning

    func findVTX() {
        guard engine.device != nil else { show("Find VTX needs the live HackRF"); return }
        if case .scanning = scan { return }
        scan = .scanning(0)
        let freqs = Array(Set(Channels.all.map(\.mhz))).sorted()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let hits = engine.scan(freqs) { p in DispatchQueue.main.async { self.scan = .scanning(p) } }
            DispatchQueue.main.async { [self] in
                engine.device?.setFrequency(UInt64(tunedHz))
                engine.markRetune()
                if hits.isEmpty {
                    scan = .notFound
                } else {
                    // every channel within a few MHz of the VTX locks; they all measure the same carrier
                    let carriers = hits.map(\.1).sorted()
                    let carrier = carriers[carriers.count / 2]
                    let best = Channels.all.min { abs(Double($0.mhz) - carrier) < abs(Double($1.mhz) - carrier) }!
                    scan = .found(channel: best.number, carrierMHz: carrier)
                }
            }
        }
    }

    // MARK: misc

    func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeTask = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: t)
    }

    func shutdown() {
        engine.setRecorder(nil)
        recording?.finishAndWait()
        engine.device?.close()
        engine.file?.stop()
    }
}
