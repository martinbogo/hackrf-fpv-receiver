import Accelerate
import Foundation

/// Direct-form II transposed biquad, a1/a2 with the scipy sign convention.
struct Biquad { let b0, b1, b2, a1, a2: Float }

// scipy.signal.butter(4, fc, fs=20e6, output="sos"). Luma cut-offs sit at the same ratio (0.68)
// below each standard's colour subcarrier, so both reject chroma equally.
private let palLumaSOS = [
    Biquad(b0: 0.018563010626897174, b1: 0.03712602125379435, b2: 0.018563010626897174,
           a1: -0.6727409111915273, a2: 0.14453519983312102),
    Biquad(b0: 1, b1: 2, b2: 1, a1: -0.8976579400366445, a2: 0.5271869046315972),
]  // 3.0 MHz, below the 4.43 MHz PAL subcarrier
private let ntscLumaSOS = [
    Biquad(b0: 0.00891445723946302, b1: 0.01782891447892604, b2: 0.00891445723946302,
           a1: -0.8931036327062872, a2: 0.22516058868743402),
    Biquad(b0: 1, b1: 2, b2: 1, a1: -1.1552915050582222, a2: 0.5848302129885163),
]  // 2.4 MHz, below the 3.58 MHz NTSC subcarrier
private let chromaSOS = [
    Biquad(b0: 0.0005891316955801649, b1: 0.0011782633911603297, b2: 0.0005891316955801649,
           a1: -1.4332283736774938, a2: 0.5232837368655171),
    Biquad(b0: 1, b1: 2, b2: 1, a1: -1.6658220426810162, a2: 0.7704921788682659),
]  // 1.1 MHz: chroma baseband after mixing down from the subcarrier

private func runSOS(_ sos: [Biquad], _ x: UnsafeMutablePointer<Float>, _ n: Int, reverse: Bool) {
    for s in sos {
        var z1: Float = 0, z2: Float = 0
        var i = reverse ? n - 1 : 0
        let step = reverse ? -1 : 1
        for _ in 0..<n {
            let v = x[i]
            let y = s.b0 * v + z1
            z1 = s.b1 * v - s.a1 * y + z2
            z2 = s.b2 * v - s.a2 * y
            x[i] = y
            i += step
        }
    }
}

/// Zero-phase forward/backward filter of `src[0..<n]` into `dst`, with odd-extension padding.
private func filtfilt(_ sos: [Biquad], _ src: UnsafePointer<Float>, _ n: Int,
                      _ dst: UnsafeMutablePointer<Float>, _ work: UnsafeMutablePointer<Float>) {
    let pad = 100
    for k in 0..<pad {
        work[pad - 1 - k] = 2 * src[0] - src[min(k + 1, n - 1)]
        work[pad + n + k] = 2 * src[n - 1] - src[max(n - 2 - k, 0)]
    }
    (work + pad).update(from: src, count: n)
    let m = n + 2 * pad
    runSOS(sos, work, m, reverse: false)
    runSOS(sos, work, m, reverse: true)
    dst.update(from: work + pad, count: n)
}

private func median(_ a: inout [Float]) -> Float {
    guard !a.isEmpty else { return 0 }
    let k = a.count / 2
    a.withUnsafeMutableBufferPointer { b in
        // quickselect
        var lo = 0, hi = b.count - 1
        while lo < hi {
            let pivot = b[(lo + hi) / 2]
            var i = lo, j = hi
            while i <= j {
                while b[i] < pivot { i += 1 }
                while b[j] > pivot { j -= 1 }
                if i <= j { b.swapAt(i, j); i += 1; j -= 1 }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { break }
        }
    }
    return a[k]
}

private func resampleTable(_ from: Int, _ to: Int) -> ([Int], [Float]) {
    var idx = [Int](), f = [Float]()
    for j in 0..<to {
        let x = Double(j) * Double(from - 1) / Double(to - 1)
        let k = min(Int(x), from - 2)
        idx.append(k); f.append(Float(x - Double(k)))
    }
    return (idx, f)
}

enum VideoStandard: String, CaseIterable, Identifiable {
    case pal = "PAL", ntsc = "NTSC"
    var id: String { rawValue }
}

/// Everything that differs between 625-line PAL-B/G and 525-line NTSC-M at 20 Msps.
/// Sample offsets are relative to the tracked sync position, which sits ~10 samples after the
/// sync leading edge; segment offsets add the 20-sample lead of each extracted line.
struct StandardParams {
    let standard: VideoStandard
    let nominalLine: Double          // samples per line
    let cyclesPerLine: Double        // colour subcarrier cycles per line (line-locked)
    let burst: Range<Int>            // colour burst, segment coords
    let blank: Range<Int>            // back porch after the burst, segment coords
    let act0: Int, actN: Int         // active video start (from sync position) and length
    let rows: Int                    // active lines decoded per field
    let skipTop: Int, skipBottom: Int  // lines from the broad-pulse start to the first active line
    let shortField: Int              // the shorter of the two field lengths, in lines
    let topFieldIsShort: Bool        // is the top field the one followed by the short field gap?
    let blackInSync: Float           // black level above blanking, in units of sync depth
    let spanInSync: Float            // white minus black, in units of sync depth
    let burstRel: Float              // burst amplitude relative to white minus black
    let lumaSOS: [Biquad]
    let palSwitch: Bool              // V axis alternates line by line
    let i0: [Int], fr: [Float], ci0: [Int], cfr: [Float]

    static let chromaWidth = PALDecoder.width / 4

    init(_ s: VideoStandard) {
        standard = s
        switch s {
        case .pal:
            // 64 us lines, 4.43361875 MHz = 283.7516 cycles/line, burst 5.6 us after sync,
            // active from 10.5 us for 52 us, 0.3 V sync / 0.7 V white, 0.15 V burst amplitude
            nominalLine = 1280; cyclesPerLine = 283.7516
            burst = 128..<165; blank = 170..<210
            act0 = 210; actN = 1040; rows = 288
            skipTop = 22; skipBottom = 23; shortField = 312; topFieldIsShort = true
            blackInSync = 0; spanInSync = 0.7 / 0.3; burstRel = 0.15 / 0.7
            lumaSOS = palLumaSOS; palSwitch = true
        case .ntsc:
            // 63.556 us lines, 3.579545 MHz = 227.5 cycles/line, burst 5.3 us after sync,
            // active from 9.4 us for 52.6 us, 40 IRE sync, 7.5 IRE setup, 100 IRE white, 20 IRE burst
            nominalLine = 1271.111; cyclesPerLine = 227.5
            burst = 120..<160; blank = 170..<192
            act0 = 180; actN = 1050; rows = 240
            skipTop = 17; skipBottom = 17; shortField = 262; topFieldIsShort = false
            blackInSync = 7.5 / 40; spanInSync = 92.5 / 40; burstRel = 20 / 92.5
            lumaSOS = ntscLumaSOS; palSwitch = false
        }
        (i0, fr) = resampleTable(actN, PALDecoder.width)
        (ci0, cfr) = resampleTable(actN, Self.chromaWidth)
    }
}

struct DecodeOptions {
    var color = true
    var saturation: Float = 1
    var weave = false
    var repairBands = true
    var standard: VideoStandard? = nil     // nil: detect automatically
}

struct DecodeStats {
    var standard = "–"
    var lock: Double = 0
    var lineMicroseconds: Double = 0
    var fieldLines: Int?
    var carrierOffsetHz: Double = 0
    var clickPercent: Double = 0
    var patchedLines = 0
    var dbfs: Double = -100
}

/// A block whose sync or levels look wrong; the caller keeps showing the last good frame.
struct Rejected: Error { let reason: String }

/// Composite video (PAL or NTSC) from FM-modulated 8-bit IQ at 20 Msps.
final class PALDecoder {
    static let sampleRate = 20_000_000.0
    static let blockSamples = 1_300_000          // > one PAL frame plus one field
    static let width = 768, height = 576         // output canvas; NTSC is scaled to fit

    private let box = 80                          // sync boxcar
    private let segOffset = 20, segLen = 1320     // samples kept per line, from sync - 20
    private let W = PALDecoder.width
    private let margin = 6
    private let white: Float = 1.05                // peak white on the black..white scale
    private let clickThreshold: Float = 2.2        // |inst. freq| beyond any real video level
    private let bandMin: Int32 = 150

    private let pal = StandardParams(.pal), ntsc = StandardParams(.ntsc)
    private var std: StandardParams
    private var needsDetect = true
    private var failures = 0

    private var w: Double?                         // carrier offset, rad/sample (AFC)
    private var linePeriod = 1280.0
    private var syncDepthRef: Float?
    private var burstRef: Float?
    private var prev: [Int: [[Float]]] = [:]
    private var patched = 0
    private(set) var stats = DecodeStats()

    /// Test hook: force the weave order (top field short-gap?, extra skip for the bottom field).
    var weaveOverride: (topIsShort: Bool, bottomSkip: Int)?

    // chroma quarter width -> W
    private let ui0: [Int], ufr: [Float]

    // scratch, sized for one block
    private var dBuf = [Float](repeating: 0, count: PALDecoder.blockSamples)
    private var reBuf = [Float](repeating: 0, count: PALDecoder.blockSamples)
    private var imBuf = [Float](repeating: 0, count: PALDecoder.blockSamples)
    private var mask = [UInt8](repeating: 0, count: PALDecoder.blockSamples)
    private var ccum = [Int32](repeating: 0, count: PALDecoder.blockSamples + 1)
    private var boxBuf = [Float](repeating: 0, count: PALDecoder.blockSamples)
    private var envBuf = [Float](repeating: 0, count: PALDecoder.blockSamples)   // |x|, for band detection

    init() {
        std = pal
        (ui0, ufr) = resampleTable(StandardParams.chromaWidth, PALDecoder.width)
    }

    /// Forget per-channel state (AFC, standard, levels, repair history) after a retune.
    func reset() {
        w = nil
        needsDetect = true
        resetLevels()
    }

    private func resetLevels() {
        syncDepthRef = nil
        burstRef = nil
        prev = [:]
    }

    private func use(_ s: StandardParams) {
        guard s.standard != std.standard else { return }
        std = s
        linePeriod = s.nominalLine
        resetLevels()
    }

    /// Picks the standard from the line period: the sync boxcar repeats every 1280 samples for
    /// PAL and every 1271.1 for NTSC, 9 samples apart, so its autocorrelation peak separates them.
    private func detectStandard(_ nb: Int) -> StandardParams? {
        let n = min(nb - 1300, 400_000)
        guard n > 100_000 else { return nil }
        var mean: Float = 0
        for i in stride(from: 0, to: n, by: 2) { mean += boxBuf[i] }
        mean /= Float(n / 2)
        var best = 0, bestV = -Float.infinity
        boxBuf.withUnsafeBufferPointer { b in
            for L in 1262...1290 {
                var acc: Float = 0
                for i in stride(from: 0, to: n, by: 2) { acc += (b[i] - mean) * (b[i + L] - mean) }
                if acc > bestV { bestV = acc; best = L }
            }
        }
        return abs(Double(best) - ntsc.nominalLine) < abs(Double(best) - pal.nominalLine) ? ntsc : pal
    }

    private func fail(_ st: DecodeStats) {
        stats = st
        failures += 1
        if failures >= 3 { needsDetect = true; failures = 0 }
    }

    /// Decodes one block of interleaved IQ into a BGRA frame, or nil when no field was found.
    func decode(_ raw: UnsafePointer<Int8>, samples n: Int, options: DecodeOptions) throws -> [UInt8]? {
        var st = DecodeStats()
        let nd = n - 1

        // --- FM demodulation: phase difference of consecutive samples --------------------
        var sI = 0, sQ = 0, pw = 0
        for i in 0..<n {
            let a = Int(raw[2 * i]), b = Int(raw[2 * i + 1])
            sI += a; sQ += b; pw += a * a + b * b
        }
        st.dbfs = 10 * log10(max(Double(pw) / Double(n), 1e-9)) - 20 * log10(128)
        let mi = Float(sI) / Float(n), mq = Float(sQ) / Float(n)

        let chunks = 8
        var sums = [(Double, Double)](repeating: (0, 0), count: chunks)
        envBuf.withUnsafeMutableBufferPointer { env in
            reBuf.withUnsafeMutableBufferPointer { re in
                imBuf.withUnsafeMutableBufferPointer { im in
                    sums.withUnsafeMutableBufferPointer { sb in
                        DispatchQueue.concurrentPerform(iterations: chunks) { c in
                            let lo = c * nd / chunks, hi = (c + 1) * nd / chunks
                            var sr = 0.0, si = 0.0
                            for i in lo..<hi {
                                let a = Float(raw[2 * i + 2]) - mi, b = Float(raw[2 * i + 3]) - mq
                                let p = Float(raw[2 * i]) - mi, q = Float(raw[2 * i + 1]) - mq
                                let r = a * p + b * q, m = b * p - a * q
                                re[i] = r; im[i] = m
                                env[i] = (a * a + b * b).squareRoot()
                                sr += Double(r); si += Double(m)
                            }
                            sb[c] = (sr, si)
                        }
                    }
                }
            }
        }
        let tot = sums.reduce((0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1) }
        let wn = atan2(tot.1, tot.0)
        if let w0 = w {
            w = atan2(0.8 * sin(w0) + 0.2 * sin(wn), 0.8 * cos(w0) + 0.2 * cos(wn))
        } else {
            w = wn
        }
        let wv = w!
        st.carrierOffsetHz = wv * Self.sampleRate / (2 * .pi)
        let c = Float(cos(-wv)), s = Float(sin(-wv))
        reBuf.withUnsafeMutableBufferPointer { re in
            imBuf.withUnsafeMutableBufferPointer { im in
                dBuf.withUnsafeMutableBufferPointer { d in
                    DispatchQueue.concurrentPerform(iterations: chunks) { k in
                        let lo = k * nd / chunks, hi = (k + 1) * nd / chunks
                        for i in lo..<hi {
                            let r = re[i] * c - im[i] * s
                            im[i] = re[i] * s + im[i] * c
                            re[i] = r
                        }
                        var cnt = Int32(hi - lo)
                        vvatan2f(d.baseAddress! + lo, im.baseAddress! + lo, re.baseAddress! + lo, &cnt)
                    }
                }
            }
        }

        // --- FM click suppression: bridge 2*pi phase slips by interpolation ---------------
        var clicked = 0
        dBuf.withUnsafeMutableBufferPointer { d in
            mask.withUnsafeMutableBufferPointer { m in
                ccum.withUnsafeMutableBufferPointer { cc in
                    for i in 0..<nd { m[i] = 0 }
                    for i in 0..<nd where abs(d[i]) > clickThreshold {
                        for j in max(i - 2, 0)...min(i + 2, nd - 1) { m[j] = 1 }
                    }
                    cc[0] = 0
                    for i in 0..<nd { cc[i + 1] = cc[i] + Int32(m[i]) }
                    clicked = Int(cc[nd])
                    var i = 0
                    while i < nd {
                        if m[i] == 0 { i += 1; continue }
                        var j = i
                        while j < nd && m[j] != 0 { j += 1 }
                        let left = i > 0 ? d[i - 1] : (j < nd ? d[j] : 0)
                        let right = j < nd ? d[j] : left
                        let span = Float(j - i + 1)
                        for k in i..<j { d[k] = left + (right - left) * Float(k - i + 1) / span }
                        i = j
                    }
                }
            }
        }
        st.clickPercent = Double(clicked) / Double(nd) * 100

        // --- sync boxcar and slicing threshold -------------------------------------------
        let nb = nd - box + 1
        dBuf.withUnsafeBufferPointer { d in
            boxBuf.withUnsafeMutableBufferPointer { bx in
                var acc = 0.0
                for i in 0..<box { acc += Double(d[i]) }
                for i in 0..<nb {
                    bx[i] = Float(acc / Double(box))
                    if i + box < nd { acc += Double(d[i + box]) - Double(d[i]) }
                }
            }
        }
        var sub = [Float]()
        sub.reserveCapacity(nb / 13 + 1)
        for i in stride(from: 0, to: nb, by: 13) { sub.append(boxBuf[i]) }
        sub.sort()
        let tip = sub[sub.count / 100], med = sub[sub.count / 2]
        let thr = tip + 0.5 * (med - tip)

        // --- video standard: forced by the user, or detected from the line period ----------
        if let forced = options.standard {
            use(forced == .pal ? pal : ntsc)
            needsDetect = false
        } else if needsDetect, let s = detectStandard(nb) {
            use(s)
            needsDetect = false
        }
        let p = std
        st.standard = p.standard.rawValue

        // --- horizontal sync: PLL over predicted line starts ------------------------------
        var k0 = 0
        for i in 0..<1400 where boxBuf[i] < boxBuf[k0] { k0 = i }
        guard boxBuf[k0] < thr else { fail(st); return nil }
        var pos = [Double](), ok = [Bool]()
        var pred = Double(k0)
        let P = linePeriod
        while pred + P + 1400 < Double(nb) {
            let a = max(Int(pred) - 40, 0)
            var k = a
            for i in a..<min(a + 81, nb) where boxBuf[i] < boxBuf[k] { k = i }
            let good = boxBuf[k] < thr
            if good { pred += 0.35 * (Double(k) - pred) }
            pos.append(pred); ok.append(good)
            pred += P
        }
        let nLines = pos.count
        st.lock = Double(ok.filter { $0 }.count) / Double(max(nLines, 1))
        if st.lock < 0.9 { fail(st); throw Rejected(reason: "sync lock \(st.lock)") }
        // refine the line period with a least-squares fit over locked lines
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, cnt = 0.0
        for l in 0..<nLines where ok[l] {
            let x = Double(l)
            sx += x; sy += pos[l]; sxx += x * x; sxy += x * pos[l]; cnt += 1
        }
        if cnt > 100 {
            let pm = (cnt * sxy - sx * sy) / (cnt * sxx - sx * sx)
            if abs(pm - p.nominalLine) < 5 { linePeriod = 0.9 * linePeriod + 0.1 * pm }
        }
        st.lineMicroseconds = linePeriod / Self.sampleRate * 1e6

        // --- vertical sync: lines mostly at sync level are the broad pulses ---------------
        var vs = [Bool](repeating: false, count: nLines)
        for l in 0..<nLines {
            let base = Int(pos[l])
            var lowCount = 0
            for k in stride(from: 100, to: 1180, by: 6) where boxBuf[min(base + k, nb - 1)] < thr { lowCount += 1 }
            vs[l] = Double(lowCount) / 180 > 0.35
        }
        var starts = [Int]()
        for l in 1..<nLines where vs[l] && !vs[l - 1] {
            if starts.isEmpty || l - starts.last! > 50 { starts.append(l) }
        }
        if starts.count >= 2 { st.fieldLines = starts[1] - starts[0] }

        // which fields are top and bottom: the field gaps alternate short/long (312/313, 262/263)
        let order = weaveOverride ?? (p.topFieldIsShort, p.skipBottom - p.skipTop)
        func isTop(_ i: Int) -> Bool? {
            if i + 1 < starts.count {
                return (starts[i + 1] - starts[i] <= p.shortField) == order.topIsShort
            }
            if i > 0 { return !((starts[i] - starts[i - 1] <= p.shortField) == order.topIsShort) }
            return nil
        }
        func skip(_ top: Bool?) -> Int { top == false ? p.skipTop + order.bottomSkip : p.skipTop }
        let usable = starts.indices.filter { i in
            starts[i] - margin >= 0 && starts[i] + skip(isTop(i)) + p.rows + 1 < nLines
        }
        guard !usable.isEmpty else { fail(st); return nil }
        failures = 0

        // --- fields -> frame ---------------------------------------------------------------
        let fsc = p.cyclesPerLine / linePeriod       // subcarrier, cycles/sample, line-locked
        patched = 0
        var planes: [[Float]]
        if options.weave, usable.count >= 2 {
            let i0 = usable[0], i1 = usable[1]
            let t0 = isTop(i0) ?? true
            let fa = try field(pos: pos, f: starts[i0], skip: skip(t0), p: p, fsc: fsc, options: options, slot: 0)
            let fb = try field(pos: pos, f: starts[i1], skip: skip(!t0), p: p, fsc: fsc, options: options, slot: 1)
            planes = []
            for (pa, pb) in zip(fa, fb) {
                let (top, bottom) = t0 ? (pa, pb) : (pb, pa)
                var out = [Float](repeating: 0, count: 2 * p.rows * W)
                for r in 0..<p.rows {
                    out.replaceSubrange((2 * r) * W..<(2 * r + 1) * W, with: top[r * W..<(r + 1) * W])
                    out.replaceSubrange((2 * r + 1) * W..<(2 * r + 2) * W, with: bottom[r * W..<(r + 1) * W])
                }
                planes.append(fitHeight(out, rows: 2 * p.rows))
            }
        } else {
            // bob: prefer a top field so the picture does not bounce by half a line
            let i = usable.first { isTop($0) == true } ?? usable[0]
            let fa = try field(pos: pos, f: starts[i], skip: skip(isTop(i)), p: p, fsc: fsc, options: options, slot: 0)
            planes = fa.map { fitHeight($0, rows: p.rows) }
        }
        st.patchedLines = patched
        stats = st
        return toBGRA(planes, color: options.color && planes.count == 3, saturation: options.saturation)
    }

    /// Scales `rows` lines vertically onto the 576-line output canvas.
    private func fitHeight(_ a: [Float], rows: Int) -> [Float] {
        let H = Self.height
        if rows == H { return a }
        var out = [Float](repeating: 0, count: H * W)
        for r in 0..<H {
            let y = (Double(r) + 0.5) * Double(rows) / Double(H) - 0.5
            let y0 = min(max(Int(floor(y)), 0), rows - 1), y1 = min(y0 + 1, rows - 1)
            let t = Float(min(max(y - Double(y0), 0), 1))
            for x in 0..<W { out[r * W + x] = a[y0 * W + x] * (1 - t) + a[y1 * W + x] * t }
        }
        return out
    }

    private func toBGRA(_ planes: [[Float]], color: Bool, saturation: Float) -> [UInt8] {
        let H = Self.height
        var out = [UInt8](repeating: 255, count: W * H * 4)
        let g = 1 / white
        let Y = planes[0]
        out.withUnsafeMutableBufferPointer { o in
            DispatchQueue.concurrentPerform(iterations: H) { r in
                for x in 0..<W {
                    let i = r * W + x
                    let y = Y[i] * g
                    var R = y, G = y, B = y
                    if color {
                        let u = planes[1][i] * g * saturation, v = planes[2][i] * g * saturation
                        R = y + v / 0.877
                        B = y + u / 0.492
                        G = (y - 0.299 * R - 0.114 * B) / 0.587
                    }
                    o[4 * i] = UInt8(max(0, min(255, B * 255)))
                    o[4 * i + 1] = UInt8(max(0, min(255, G * 255)))
                    o[4 * i + 2] = UInt8(max(0, min(255, R * 255)))
                }
            }
        }
        return out
    }

    private func field(pos: [Double], f: Int, skip: Int, p: StandardParams, fsc: Double,
                       options: DecodeOptions, slot: Int) throws -> [[Float]] {
        var planes = try fieldPlanes(pos: pos, first: f + skip, p: p, fsc: fsc, color: options.color)
        let flags = options.repairBands ? bandFlags(pos: pos, first: f + skip, p: p)
                                        : [Bool](repeating: false, count: p.rows)
        patch(&planes, flags, rows: p.rows, slot: slot)
        return planes
    }

    /// Lines hit by an interference burst. Another transmitter on the channel shows up as extra
    /// fluctuation of the received amplitude (the FM carrier alone is constant-envelope), and a
    /// strong burst also as a cluster of FM clicks.
    private func bandFlags(pos: [Double], first: Int, p: StandardParams) -> [Bool] {
        let H2 = p.rows, actN = p.actN
        var n = [Int32](repeating: 0, count: H2)
        var envStd = [Float](repeating: 0, count: H2)
        for r in 0..<H2 {
            let q = Int(pos[first + r]) + p.act0
            n[r] = ccum[q + actN] - ccum[q]
            var s: Float = 0, s2: Float = 0
            for i in q..<(q + actN) { let e = envBuf[i]; s += e; s2 += e * e }
            let m = s / Float(actN)
            envStd[r] = max(s2 / Float(actN) - m * m, 0).squareRoot()
        }
        var sorted = envStd
        let fieldEnv = median(&sorted)
        var flag = [Bool](repeating: false, count: H2)
        for r in 0..<H2 {
            var win = [Float]()
            for k in (r - 7)...(r + 7) { win.append(Float(n[min(max(k, 0), H2 - 1)])) }
            let local = Int32(median(&win))
            flag[r] = envStd[r] > 1.3 * fieldEnv || n[r] > max(bandMin, 3 * local)
        }
        var out = flag
        for r in 0..<H2 where flag[r] {
            if r > 0 { out[r - 1] = true }
            if r + 1 < H2 { out[r + 1] = true }
        }
        return out
    }

    /// Short runs are interpolated from the lines either side; longer ones come from the last field.
    private func patch(_ planes: inout [[Float]], _ flag: [Bool], rows H2: Int, slot: Int) {
        let prevPlanes = prev[slot].flatMap { $0.count == planes.count && $0[0].count == planes[0].count ? $0 : nil }
        var r = 0
        while r < H2 {
            guard flag[r] else { r += 1; continue }
            var e = r
            while e < H2 && flag[e] { e += 1 }
            patched += e - r
            let a = r - 1, b = e
            for pi in 0..<planes.count {
                if (e - r <= 3 && a >= 0 && b < H2) || prevPlanes == nil {
                    for row in r..<e {
                        for x in 0..<W {
                            let v: Float
                            if a >= 0 && b < H2 {
                                let t = Float(row - a) / Float(b - a)
                                v = planes[pi][a * W + x] * (1 - t) + planes[pi][b * W + x] * t
                            } else {
                                v = planes[pi][(a >= 0 ? a : b) * W + x]
                            }
                            planes[pi][row * W + x] = v
                        }
                    }
                } else {
                    planes[pi].replaceSubrange(r * W..<e * W, with: prevPlanes![pi][r * W..<e * W])
                }
            }
            r = e
        }
        prev[slot] = planes
    }

    private func fieldPlanes(pos: [Double], first: Int, p: StandardParams, fsc: Double, color: Bool) throws -> [[Float]] {
        let H2 = p.rows, actN = p.actN
        let nL = H2 + margin
        let L0 = first - margin
        var luma = [Float](repeating: 0, count: nL * segLen)
        var cre = [Float](repeating: 0, count: color ? nL * segLen : 0)
        var cim = [Float](repeating: 0, count: color ? nL * segLen : 0)
        let segLen = self.segLen, segOffset = self.segOffset
        let lumaSOS = p.lumaSOS

        dBuf.withUnsafeBufferPointer { d in
            luma.withUnsafeMutableBufferPointer { lu in
                cre.withUnsafeMutableBufferPointer { cr in
                    cim.withUnsafeMutableBufferPointer { ci in
                        DispatchQueue.concurrentPerform(iterations: nL) { li in
                            let start = Int(pos[L0 + li]) - segOffset
                            let work = UnsafeMutablePointer<Float>.allocate(capacity: segLen + 200)
                            defer { work.deallocate() }
                            let src = d.baseAddress! + start
                            filtfilt(lumaSOS, src, segLen, lu.baseAddress! + li * segLen, work)
                            guard color else { return }
                            let re = UnsafeMutablePointer<Float>.allocate(capacity: segLen)
                            let im = UnsafeMutablePointer<Float>.allocate(capacity: segLen)
                            defer { re.deallocate(); im.deallocate() }
                            var ph = (Double(start) * fsc).truncatingRemainder(dividingBy: 1)
                            for j in 0..<segLen {
                                let ang = Float(2 * Double.pi * ph)
                                re[j] = src[j] * cos(ang)
                                im[j] = -src[j] * sin(ang)
                                ph += fsc
                                if ph >= 1 { ph -= 1 }
                            }
                            filtfilt(chromaSOS, re, segLen, cr.baseAddress! + li * segLen, work)
                            filtfilt(chromaSOS, im, segLen, ci.baseAddress! + li * segLen, work)
                        }
                    }
                }
            }
        }

        // levels relative to sync: sync tip and blanking (back porch after the burst)
        var tips = [Float](), blanks = [Float]()
        tips.reserveCapacity(nL * 50); blanks.reserveCapacity(nL * p.blank.count)
        for li in 0..<nL {
            tips.append(contentsOf: luma[li * segLen + 30..<li * segLen + 80])
            blanks.append(contentsOf: luma[(li * segLen + p.blank.lowerBound)..<(li * segLen + p.blank.upperBound)])
        }
        let tip = median(&tips), blank = median(&blanks)
        var S = blank - tip
        if let ref = syncDepthRef {
            if !(S / ref > 0.8 && S / ref < 1.25) { throw Rejected(reason: "sync depth") }
            syncDepthRef = ref + 0.05 * (S - ref)
        } else {
            if S <= 0.05 { throw Rejected(reason: "no sync depth") }
            syncDepthRef = S
        }
        S = syncDepthRef!

        let a0 = segOffset + p.act0
        var Y = [Float](repeating: 0, count: H2 * W)
        for r in 0..<H2 {
            let base = (r + margin) * segLen + a0
            for x in 0..<W {
                let v = luma[base + p.i0[x]] * (1 - p.fr[x]) + luma[base + p.i0[x] + 1] * p.fr[x]
                Y[r * W + x] = ((v - blank) / S - p.blackInSync) / p.spanInSync
            }
        }
        guard color else { return [Y] }

        // colour burst per line -> U axis reference (and, for PAL, the V-switch phase)
        var br = [Float](repeating: 0, count: nL), bi = [Float](repeating: 0, count: nL)
        let bn = Float(p.burst.count)
        for li in 0..<nL {
            var sr: Float = 0, si: Float = 0
            for j in p.burst { sr += cre[li * segLen + j]; si += cim[li * segLen + j] }
            br[li] = sr / bn; bi[li] = si / bn
        }
        // reference: average of 8 bursts (cancels PAL's +/-45 degree swing)
        var rr = [Float](repeating: 0, count: nL), ri = [Float](repeating: 0, count: nL)
        var sumv: Float = 0, sumR: Float = 0, sumI: Float = 0, sumA: Float = 0
        var amps = [Float]()
        for li in 0..<nL {
            var sr: Float = 0, si: Float = 0
            for k in (li - 4)...(li + 3) where k >= 0 && k < nL { sr += br[k]; si += bi[k] }
            let m = max(hypot(sr, si), 1e-12)
            rr[li] = sr / m; ri[li] = si / m
            let rel = atan2(bi[li] * rr[li] - br[li] * ri[li], br[li] * rr[li] + bi[li] * ri[li])
            let alt: Float = li % 2 == 0 ? 1 : -1
            sumv += (rel > 0 ? 1 : (rel < 0 ? -1 : 0)) * alt
            let a = hypot(br[li], bi[li])
            amps.append(a)
            if a > 0 { sumR += br[li] / a; sumI += bi[li] / a; sumA += 1 }
        }
        let amp = median(&amps)
        if burstRef == nil { burstRef = amp }
        // burst quality: PAL must show the line-by-line swing; NTSC bursts must agree in phase
        let quality = p.palSwitch ? abs(sumv) / Float(nL) : hypot(sumR, sumI) / max(sumA, 1)
        let goodBurst = quality > 0.5 && amp / burstRef! > 0.6 && amp / burstRef! < 1.6
        guard goodBurst else {
            // colour killer: the burst is unreliable in this field, show it monochrome
            return [Y, [Float](repeating: 0, count: H2 * W), [Float](repeating: 0, count: H2 * W)]
        }
        burstRef! += 0.05 * (amp - burstRef!)
        let k = p.burstRel / burstRef!
        let s0: Float = sumv > 0 ? -1 : 1

        // demodulated U/V over the active line, rows margin-1 ..< nL (one extra for the line average).
        // Rotating by -ref and negating puts the burst (the -U axis) at 180 degrees: U is the real
        // part and V the imaginary part, with PAL's V inverted on alternate lines.
        var U = [Float](repeating: 0, count: (H2 + 1) * actN), V = U
        for r in 0...H2 {
            let li = r + margin - 1
            let vsw: Float = p.palSwitch ? s0 * (li % 2 == 0 ? 1 : -1) : 1
            let base = li * segLen + a0
            for x in 0..<actN {
                let cr = cre[base + x], ci = cim[base + x]
                U[r * actN + x] = -(cr * rr[li] + ci * ri[li]) * k
                V[r * actN + x] = -(ci * rr[li] - cr * ri[li]) * k * vsw
            }
        }
        // average each line with the previous one: the PAL delay line, and chroma noise
        // reduction for NTSC
        var Ua = [Float](repeating: 0, count: H2 * actN), Va = Ua
        for r in 0..<H2 {
            for x in 0..<actN {
                Ua[r * actN + x] = 0.5 * (U[(r + 1) * actN + x] + U[r * actN + x])
                Va[r * actN + x] = 0.5 * (V[(r + 1) * actN + x] + V[r * actN + x])
            }
        }
        return [Y, chromaPlane(Ua, p), chromaPlane(Va, p)]
    }

    /// Chroma carries ~1 MHz of detail: median-filter it at quarter width, then interpolate up.
    private func chromaPlane(_ a: [Float], _ p: StandardParams) -> [Float] {
        let H2 = p.rows, actN = p.actN, cw = StandardParams.chromaWidth
        var small = [Float](repeating: 0, count: H2 * cw)
        for r in 0..<H2 {
            for x in 0..<cw {
                small[r * cw + x] = a[r * actN + p.ci0[x]] * (1 - p.cfr[x]) + a[r * actN + p.ci0[x] + 1] * p.cfr[x]
            }
        }
        var filt = small
        var win = [Float](repeating: 0, count: 9)
        for r in 0..<H2 {
            for x in 0..<cw {
                var n = 0
                for dr in -1...1 {
                    let rr = min(max(r + dr, 0), H2 - 1)
                    for dx in -1...1 {
                        win[n] = small[rr * cw + min(max(x + dx, 0), cw - 1)]; n += 1
                    }
                }
                filt[r * cw + x] = median(&win)
            }
        }
        var out = [Float](repeating: 0, count: H2 * W)
        for r in 0..<H2 {
            for x in 0..<W {
                out[r * W + x] = filt[r * cw + ui0[x]] * (1 - ufr[x]) + filt[r * cw + ui0[x] + 1] * ufr[x]
            }
        }
        return out
    }
}
