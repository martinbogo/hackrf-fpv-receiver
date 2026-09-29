// Offline decoder test: runs PALDecoder over an IQ capture and reports per-block statistics.
//   dectest <capture.iq> [blocks] [out.bgra]
// The last decoded frame is written as raw 768x576 BGRA when an output path is given.
import Foundation

let args = CommandLine.arguments
let data = try! Data(contentsOf: URL(fileURLWithPath: args[1]), options: .alwaysMapped)
let nB = 2 * PALDecoder.blockSamples
let blocks = min(args.count > 2 ? Int(args[2])! : 12, data.count / nB)
let step = max((data.count - nB) / max(blocks - 1, 1) & ~1, 0)
let dec = PALDecoder()
var times = [Double](), last: [UInt8]?
for k in 0..<blocks {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let p = raw.baseAddress!.advanced(by: k * step).assumingMemoryBound(to: Int8.self)
        let t = CFAbsoluteTimeGetCurrent()
        do {
            let img = try dec.decode(p, samples: PALDecoder.blockSamples, options: DecodeOptions())
            times.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            let s = dec.stats
            print(k, img == nil ? "nil  " : "frame", s.standard,
                  String(format: "lock %.2f line %.4f us field %@ carrier %+.3f MHz dBFS %.1f click %.1f%% patched %d",
                         s.lock, s.lineMicroseconds, s.fieldLines.map(String.init) ?? "-",
                         s.carrierOffsetHz / 1e6, s.dbfs, s.clickPercent, s.patchedLines))
            if img != nil { last = img }
        } catch { print(k, "rejected", error) }
    }
}
if !times.isEmpty { print(String(format: "median %.1f ms/frame", times.sorted()[times.count / 2])) }
if args.count > 3, let last { try! Data(last).write(to: URL(fileURLWithPath: args[3])) }
