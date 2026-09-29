import AVFoundation
import CoreVideo

/// Writes decoded frames to an H.264 MP4. Timestamps come from the IQ stream clock, so the
/// file plays back at true speed even though frames arrive at a variable rate.
final class Recorder {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue = DispatchQueue(label: "fpv.recorder")
    private var t0: Double?
    private var finished = false
    private(set) var frames = 0

    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "Recorder", code: 1)
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// `seconds` is the stream time of the frame; `bgra` is width*height*4 bytes.
    func append(_ bgra: [UInt8], width: Int, height: Int, seconds: Double) {
        queue.async { [self] in
            guard !finished, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
            if t0 == nil { t0 = seconds }
            var pb: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return }
            CVPixelBufferLockBaseAddress(pb, [])
            let dst = CVPixelBufferGetBaseAddress(pb)!
            let stride = CVPixelBufferGetBytesPerRow(pb)
            bgra.withUnsafeBytes { src in
                for r in 0..<height {
                    (dst + r * stride).copyMemory(from: src.baseAddress! + r * width * 4, byteCount: width * 4)
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            let t = CMTime(seconds: seconds - t0!, preferredTimescale: 90_000)
            if adaptor.append(pb, withPresentationTime: t) { frames += 1 }
        }
    }

    func finish(_ done: @escaping (URL, Int) -> Void) {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            input.markAsFinished()
            writer.finishWriting { [self] in done(url, frames) }
        }
    }

    /// Blocking variant for app termination.
    func finishAndWait() {
        let sem = DispatchSemaphore(value: 0)
        finish { _, _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 5)
    }
}
