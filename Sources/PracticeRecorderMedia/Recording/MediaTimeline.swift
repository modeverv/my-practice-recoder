import AVFoundation
import PracticeRecorderCore

/// All calculations use the capture session's source clock. Offset is applied only to audio.
public struct MediaTimeline {
    public let start: CMTime
    public let end: CMTime
    public let audioOffset: CMTime
    public init(start: CMTime, limit: Double = 300, audioOffsetMs: Int) {
        self.start = start
        self.end = start + CMTime(seconds: limit, preferredTimescale: 600_000)
        self.audioOffset = CMTime(value: Int64(audioOffsetMs), timescale: 1000)
    }
    /// Half-open frame range: samples must be presented at start <= PTS < end.
    public func audioRange(pts: CMTime, frames: Int, sampleRate: Double) -> Range<Int> {
        guard frames > 0, pts.isNumeric, start.isNumeric, end.isNumeric,
              sampleRate.isFinite, sampleRate > 0, sampleRate <= Double(Int32.max),
              sampleRate.rounded() == sampleRate else { return 0..<0 }
        let shifted = pts + audioOffset
        let scale = Int32(sampleRate)
        // Rational conversions avoid floating-point ceil/floor losing a PCM frame.
        // The first complete frame must be inside both raw and shifted intervals.
        let originalFirst = CMTimeConvertScale(start - pts, timescale:scale, method:.roundTowardPositiveInfinity).value
        let shiftedFirst = CMTimeConvertScale(start - shifted, timescale:scale, method:.roundTowardPositiveInfinity).value
        let first = max(0, min(frames, Int(max(originalFirst, shiftedFirst))))
        let originalLast = CMTimeConvertScale(end - pts, timescale:scale, method:.roundTowardNegativeInfinity).value
        let shiftedLast = CMTimeConvertScale(end - shifted, timescale:scale, method:.roundTowardNegativeInfinity).value
        let last = max(first, min(frames, Int(min(originalLast, shiftedLast))))
        return first..<last
    }
    public func videoDuration(pts: CMTime, duration: CMTime) -> CMTime? {
        guard pts.isNumeric, pts >= start, (pts < end), duration.isNumeric, (duration > .zero) else { return nil }
        return CMTimeMinimum(duration, end - pts)
    }
    public func adjustedAudio(_ sample: CMSampleBuffer) throws -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame == 2,
              asbd.mSampleRate == 44_100 || asbd.mSampleRate == 48_000 else {
            throw RecorderError("writerには44.1/48kHzのステレオPCMが必要です")
        }
        let count = CMSampleBufferGetNumSamples(sample)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric, count > 0 else { throw RecorderError("音声PTSまたはサンプル数が無効です") }
        let range = audioRange(pts: pts, frames: count, sampleRate: asbd.mSampleRate)
        guard !range.isEmpty else { return nil }
        var sliced: CMSampleBuffer?
        let status = CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleRange: CFRange(location: range.lowerBound, length: range.count), sampleBufferOut: &sliced)
        guard status == noErr, let sliced else { throw RecorderError("PCM境界の切り詰めに失敗しました: \(status)") }
        let time = CMSampleBufferGetPresentationTimeStamp(sliced) + audioOffset
        return try Self.retime(sliced, pts: time, duration: CMTime(value: 1, timescale: Int32(asbd.mSampleRate)))
    }
    public static func retime(_ sample: CMSampleBuffer, pts: CMTime, duration: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
        guard status == noErr, let copy else { throw RecorderError("PTSの設定に失敗しました: \(status)") }
        return copy
    }
}
