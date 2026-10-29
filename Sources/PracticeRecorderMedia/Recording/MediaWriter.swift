import Foundation
import AVFoundation
import VideoToolbox
import PracticeRecorderCore

/// Mutable writer state is confined to `queue`. The lock protects ONLY the bounded ingress
/// counters and active token. Retained CMSampleBuffers own their underlying memory.
public final class MediaWriter: WriterProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "PracticeRecorder.writer", qos: .userInitiated)
    private let ingressLock = NSLock()
    private var ingressID: UUID?
    private var pendingIngressAudio = 0
    private var pendingIngressVideo = 0
    private var overflowReported = false
    private var ingressVideoDrops = 0
    private var audioRate: Double?
    private var request: RecordingRequest?
    private var context: RecordingContext?
    private var timeline: MediaTimeline?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var partialURL: URL?
    private var onStarted: ((RecordingContext) -> Void)?
    private var onFinished: ((Result<RecordingResult, Error>) -> Void)?
    private var firstVideo: CMSampleBuffer?
    private var armingAudio: [CMSampleBuffer] = []
    private var pendingAudio: [CMSampleBuffer] = []
    private var pendingVideo: [CMSampleBuffer] = []
    private var finishing = false
    private var retryScheduled = false
    private var backpressureSince: Double?
    private var interruption: String?
    private var lastAudioPTS: CMTime?
    private var lastAudioEndPTS: CMTime?
    private var lastVideoPTS: CMTime?
    private var latestAcceptedEnd = CMTime.invalid
    private var appendedAudio = 0
    private var appendedVideo = 0
    private var videoDrops = 0
    public init() {}

    public func arm(_ request: RecordingRequest, onStarted: @escaping (RecordingContext) -> Void,
                    onFinished: @escaping (Result<RecordingResult, Error>) -> Void) {
        queue.async { [self] in
            guard self.request == nil else {
                onFinished(.failure(RecorderError("保存が終わるまで次の録画は開始できません"))); return
            }
            guard abs(request.settings.audioOffsetMs) <= 500, request.settings.audioOffsetMs % 10 == 0 else {
                onFinished(.failure(RecorderError("音声補正は−500〜+500ms、10ms刻みです"))); return
            }
            self.request = request; self.onStarted = onStarted; self.onFinished = onFinished
            ingressLock.lock(); ingressID = request.id; overflowReported = false; ingressVideoDrops = 0; ingressLock.unlock()
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.request?.id == request.id, self.context == nil, !self.finishing else { return }
                self.fail("3秒以内に有効な映像と音声の両方を取得できませんでした")
            }
        }
    }
    public func appendVideo(_ sample: CMSampleBuffer) { enqueue(sample, audio: false) }
    public func appendAudio(_ sample: CMSampleBuffer) { enqueue(sample, audio: true) }
    private func enqueue(_ sample: CMSampleBuffer, audio: Bool) {
        ingressLock.lock()
        guard let id = ingressID else { ingressLock.unlock(); return }
        let full = audio ? pendingIngressAudio >= 64 : pendingIngressVideo >= 6
        if full {
            if !audio { ingressVideoDrops += 1 }
            let report = !overflowReported && (audio || ingressVideoDrops > 30)
            if report { overflowReported = true }
            ingressLock.unlock()
            if report { queue.async { [weak self] in
                guard self?.request?.id == id else { return }
                self?.fail(audio ? "音声処理のキューが上限に達しました。欠落を隠さず停止します" : "映像処理の遅延が継続しました")
            } }
            return
        }
        if audio { pendingIngressAudio += 1 } else { pendingIngressVideo += 1 }
        ingressLock.unlock()
        queue.async { [self] in
            defer {
                ingressLock.lock()
                if audio { pendingIngressAudio -= 1 } else { pendingIngressVideo -= 1 }
                ingressLock.unlock()
            }
            guard self.request?.id == id, !finishing else { return }
            do { try receive(sample, audio: audio) } catch { fail(error.localizedDescription) }
        }
    }
    public func stop(id: UUID, reason: String?) {
        queue.async { [weak self] in
            guard let self, self.request?.id == id, !self.finishing else { return }
            self.interruption = self.interruption ?? reason
            if self.context == nil { self.fail(reason ?? "録画開始前に停止しました"); return }
            self.beginFinish()
        }
    }
    private func receive(_ sample: CMSampleBuffer, audio: Bool) throws {
        guard CMSampleBufferDataIsReady(sample), let request else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric else { throw RecorderError("入力PTSが無効です") }
        if context == nil {
            if audio {
                armingAudio.append(sample)
                if armingAudio.count > 64 { armingAudio.removeFirst() }
            } else { firstVideo = sample }
            if let video = firstVideo, let audio = armingAudio.last {
                try begin(request, firstVideo: video, audio: audio)
                let buffered = armingAudio; armingAudio.removeAll(); firstVideo = nil
                try record(video, audio: false)
                for a in buffered where !finishing { try record(a, audio: true) }
            }
        } else { try record(sample, audio: audio) }
    }
    private func begin(_ request: RecordingRequest, firstVideo: CMSampleBuffer, audio: CMSampleBuffer) throws {
        let t0 = CMSampleBufferGetPresentationTimeStamp(firstVideo)
        guard let vf = CMSampleBufferGetFormatDescription(firstVideo),
              let af = CMSampleBufferGetFormatDescription(audio),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(af)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame == 2,
              asbd.mSampleRate == 44_100 || asbd.mSampleRate == 48_000 else {
            throw RecorderError("44.1kHz/48kHzのステレオPCM音声を取得できません")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(vf)
        guard dimensions.width == request.selection.video.width, dimensions.height == request.selection.video.height else {
            throw RecorderError("映像の実際のサイズが選択した画質と一致しません")
        }
        let now = Date()
        let ctx = RecordingContext(request: request, startedAt: now, startPTS: t0,
                                   monotonicStart: ProcessInfo.processInfo.systemUptime)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: ctx.timeZoneIdentifier) ?? .current
        let components = calendar.dateComponents([.year, .month], from: now)
        let dir = request.settings.root.appendingPathComponent(request.instrument.rawValue, isDirectory: true)
            .appendingPathComponent(String(format: "%04d", components.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month!), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: dir.path)
        if let free = attrs[.systemFreeSize] as? NSNumber {
            let estimated = Int64(Double(request.selection.video.bitrate + 192_000) / 8 * 300 * 1.2) + 16_000_000
            guard free.int64Value >= estimated else { throw RecorderError("保存先の空き容量が不足しています（5分録画分の余裕が必要です）") }
        }
        let url = dir.appendingPathComponent(".recording-\(request.id.uuidString).partial.mp4")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw RecorderError("partialファイルが既に存在します。上書きしません: \(url.path)") }
        partialURL = url
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(dimensions.width), AVVideoHeightKey: Int(dimensions.height),
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: request.selection.video.bitrate,
                AVVideoAllowFrameReorderingKey: false]
        ]
        let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: asbd.mSampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
        guard w.canApply(outputSettings: videoSettings, forMediaType: .video), w.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
            throw RecorderError("HEVCハードウェア/AAC設定を受け付けません。形式は自動変更しません")
        }
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings, sourceFormatHint: vf)
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: af)
        vi.expectsMediaDataInRealTime = true; ai.expectsMediaDataInRealTime = true
        guard w.canAdd(vi), w.canAdd(ai) else { throw RecorderError("MP4 writerの入力を追加できません") }
        w.add(vi); w.add(ai)
        guard w.startWriting() else { throw RecorderError(w.error?.localizedDescription ?? "HEVCエンコーダーを開始できません") }
        w.startSession(atSourceTime: t0)
        writer = w; videoInput = vi; audioInput = ai; context = ctx; audioRate = asbd.mSampleRate
        timeline = MediaTimeline(start: t0, audioOffsetMs: request.settings.audioOffsetMs)
        onStarted?(ctx)
    }
    private func record(_ sample: CMSampleBuffer, audio: Bool) throws {
        guard let timeline, let context, !finishing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if audio {
            guard let format = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  asbd.mSampleRate == audioRate, asbd.mChannelsPerFrame == 2 else {
                throw RecorderError("録画中に音声形式またはサンプルレートが変化しました")
            }
            guard lastAudioPTS == nil || pts > lastAudioPTS! else { throw RecorderError("音声PTSが単調増加していません") }
            if let expected = lastAudioEndPTS, abs((pts - expected).seconds) > max(2 / asbd.mSampleRate, 0.001) {
                throw RecorderError("音声PTSに不連続を検出しました（差: \(String(format: "%.3f", (pts - expected).seconds * 1000))ms）。欠落を隠さず停止します")
            }
            lastAudioPTS = pts
            lastAudioEndPTS = pts + CMTime(value: Int64(CMSampleBufferGetNumSamples(sample)), timescale: Int32(asbd.mSampleRate))
            if let adjusted = try timeline.adjustedAudio(sample) {
                guard pendingAudio.count < 64 else { throw RecorderError("音声エンコーダーが追いつきません") }
                pendingAudio.append(adjusted)
            }
            // Offset affects the audio presentation boundary, not the capture duration.
            // Positive offset can reach end up to 500ms before video. Discard it without
            // stopping the take; video boundary or the monotonic watchdog finishes it.
        } else {
            guard let format = CMSampleBufferGetFormatDescription(sample) else { throw RecorderError("映像形式がありません") }
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            guard dims.width == context.request.selection.video.width, dims.height == context.request.selection.video.height else {
                throw RecorderError("録画中に映像形式が変化しました")
            }
            guard lastVideoPTS == nil || pts > lastVideoPTS! else { throw RecorderError("映像PTSが単調増加していません") }
            lastVideoPTS = pts
            if let duration = timeline.videoDuration(pts: pts, duration: context.request.selection.video.frameDuration) {
                let adjusted = try MediaTimeline.retime(sample, pts: pts, duration: duration)
                if pendingVideo.count >= 6 { videoDrops += 1; pendingVideo.removeFirst() }
                pendingVideo.append(adjusted)
            }
            if pts >= timeline.end { beginFinish(); return }
        }
        drain()
    }
    private func drain() {
        guard let w = writer, !finishing else { return }
        if w.status == .failed { fail(w.error?.localizedDescription ?? "writerが失敗しました"); return }
        while let a = pendingAudio.first, audioInput?.isReadyForMoreMediaData == true {
            pendingAudio.removeFirst()
            guard audioInput?.append(a) == true else { fail(w.error?.localizedDescription ?? "音声の書き込みに失敗しました"); return }
            appendedAudio += 1; accepted(a, audio: true)
        }
        while let v = pendingVideo.first, videoInput?.isReadyForMoreMediaData == true {
            pendingVideo.removeFirst()
            guard videoInput?.append(v) == true else { fail(w.error?.localizedDescription ?? "映像の書き込みに失敗しました"); return }
            appendedVideo += 1; accepted(v, audio: false)
        }
        if pendingAudio.isEmpty && pendingVideo.isEmpty { backpressureSince = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        if let since = backpressureSince, now - since > 1 { fail("エンコーダーのbackpressureが1秒継続しました"); return }
        backpressureSince = backpressureSince ?? now
        guard !retryScheduled, let id = request?.id else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self, self.request?.id == id else { return }
            self.retryScheduled = false; self.drain()
        }
    }
    private func accepted(_ sample: CMSampleBuffer, audio: Bool) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration: CMTime
        if audio, let format = CMSampleBufferGetFormatDescription(sample),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            duration = CMTime(value: Int64(CMSampleBufferGetNumSamples(sample)), timescale: Int32(asbd.mSampleRate))
        } else { duration = CMSampleBufferGetDuration(sample) }
        let end = pts + duration
        if !latestAcceptedEnd.isNumeric || end > latestAcceptedEnd { latestAcceptedEnd = end }
    }
    private func fail(_ reason: String) {
        guard request != nil, !finishing else { return }
        interruption = interruption ?? reason
        if writer != nil, context != nil { beginFinish() }
        else { complete(.failure(RecorderError(reason + (partialURL.map { "\npartial: \($0.path)" } ?? "")))) }
    }
    private func beginFinish() {
        guard !finishing, let req = request else { return }
        finishing = true
        ingressLock.lock(); ingressID = nil; ingressLock.unlock()
        guard let w = writer, let ctx = context, let url = partialURL, let timeline else {
            complete(.failure(RecorderError(interruption ?? "録画開始前に停止しました"))); return
        }
        // Flush only currently ready items. No waiting or recursive stop is allowed here.
        while let sample = pendingAudio.first, audioInput?.isReadyForMoreMediaData == true {
            pendingAudio.removeFirst()
            if audioInput?.append(sample) == true { appendedAudio += 1; accepted(sample, audio: true) }
            else { interruption = interruption ?? w.error?.localizedDescription ?? "停止時の音声書き込みに失敗しました"; break }
        }
        while let sample = pendingVideo.first, videoInput?.isReadyForMoreMediaData == true {
            pendingVideo.removeFirst()
            if videoInput?.append(sample) == true { appendedVideo += 1; accepted(sample, audio: false) }
            else { interruption = interruption ?? w.error?.localizedDescription ?? "停止時の映像書き込みに失敗しました"; break }
        }
        if !pendingAudio.isEmpty { interruption = interruption ?? "停止時に未処理の音声が残りました" }
        pendingAudio.removeAll(); pendingVideo.removeAll()
        guard w.status == .writing, latestAcceptedEnd.isNumeric, appendedAudio > 0, appendedVideo > 0 else {
            w.cancelWriting()
            complete(.failure(RecorderError((interruption ?? w.error?.localizedDescription ?? "映像と音声がそろった録画を作れませんでした") + "\npartial: \(url.path)")))
            return
        }
        let end = CMTimeMinimum(latestAcceptedEnd, timeline.end)
        w.endSession(atSourceTime: end)
        videoInput?.markAsFinished(); audioInput?.markAsFinished()
        let preservedInterruption = interruption
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.request?.id == req.id, self.finishing else { return }
            w.cancelWriting()
            self.complete(.failure(RecorderError("保存が15秒以内に完了しませんでした。partialを残しました: \(url.path)")))
        }
        w.finishWriting { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.request?.id == req.id, self.finishing else { return }
                guard w.status == .completed else {
                    self.complete(.failure(RecorderError("保存失敗: \(w.error?.localizedDescription ?? "不明")\npartial: \(url.path)"))); return
                }
                Task {
                    do {
                        let tolerance = max(ctx.request.selection.video.frameDuration.seconds, 1024.0 / 44_100) + 0.000001
                        let duration = try await Self.validate(url, maxDuration: req.settings.limitSeconds, tolerance: tolerance)
                        self.queue.async {
                            guard self.request?.id == req.id else { return }
                            self.complete(.success(RecordingResult(context: ctx, partialURL: url,
                                duration: duration, interruptedReason: preservedInterruption)))
                        }
                    } catch {
                        self.queue.async {
                            guard self.request?.id == req.id else { return }
                            self.complete(.failure(RecorderError("完成ファイルの検証失敗: \(error.localizedDescription)\npartial: \(url.path)")))
                        }
                    }
                }
            }
        }
    }
    /// Validation is also used by integration tests; hardware encoding is never silently substituted.
    public static func validate(_ url: URL, maxDuration: Double = 300, tolerance: Double = 1.0 / 30 + 0.000001) async throws -> Double {
        guard tolerance.isFinite, tolerance >= 0, maxDuration.isFinite, maxDuration > 0 else {
            throw RecorderError("尺検証の上限または許容誤差が不正です")
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard duration.isFinite, duration > 0, duration <= maxDuration + tolerance,
              let video = videos.first, let audio = audios.first else { throw RecorderError("正の尺と映像・音声トラックを検証できません") }
        let vf = try await video.load(.formatDescriptions)
        let af = try await audio.load(.formatDescriptions)
        guard vf.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }),
              af.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }) else { throw RecorderError("HEVC/AACのトラックではありません") }
        for track in [video, audio] {
            let range = try await track.load(.timeRange)
            guard range.start.isNumeric, range.duration.isNumeric, range.start >= .zero,
                  CMTimeRangeGetEnd(range).seconds <= maxDuration + tolerance else { throw RecorderError("トラックの提示範囲が上限を越えました") }
        }
        return duration
    }
    private func complete(_ result: Result<RecordingResult, Error>) {
        let callback = onFinished
        ingressLock.lock(); ingressID = nil; let dropped = videoDrops + ingressVideoDrops; ingressLock.unlock()
        if dropped > 0 { NSLog("PracticeRecorder: video frames dropped: %d", dropped) }
        request = nil; context = nil; timeline = nil; writer = nil; videoInput = nil; audioInput = nil
        partialURL = nil; onStarted = nil; onFinished = nil; firstVideo = nil; armingAudio.removeAll()
        pendingAudio.removeAll(); pendingVideo.removeAll(); finishing = false; retryScheduled = false
        backpressureSince = nil; interruption = nil; audioRate = nil; lastAudioPTS = nil; lastAudioEndPTS = nil; lastVideoPTS = nil
        latestAcceptedEnd = .invalid; appendedAudio = 0; appendedVideo = 0; videoDrops = 0
        callback?(result)
    }
}
