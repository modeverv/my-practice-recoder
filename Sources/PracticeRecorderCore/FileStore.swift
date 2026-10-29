import Foundation
import AVFoundation
import Darwin

public enum FileStore {
    public static let minimumFreeBytes: UInt64 = 256 * 1024 * 1024

    public static func preflight(root: URL) throws {
        guard root.isFileURL else { throw RecorderError("ローカルの保存フォルダーを選んでください。") }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let attributes = try fm.attributesOfFileSystem(forPath: root.path)
        if let free = attributes[.systemFreeSize] as? NSNumber, free.uint64Value < minimumFreeBytes {
            throw RecorderError("保存先の空き容量が不足しています。最低256MBの空きを確保してください。")
        }
        let probe = root.appendingPathComponent(".practice-recorder-write-test-\(UUID().uuidString)")
        let descriptor = probe.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw posixError("保存先に書き込めません", path: root.path) }
        close(descriptor)
        // This file belongs to this preflight alone; never remove an existing user file.
        guard probe.path.withCString({ unlink($0) }) == 0 else { throw posixError("書き込み検査ファイルを削除できません", path: probe.path) }
    }

    /// Writer must already have finished successfully. No final name is assigned to invalid media.
    public static func finalize(_ result: RecordingResult) async throws -> URL {
        let tolerance = mediaDurationTolerance(video: result.context.request.selection.video)
        return try await finalize(result, timeout: 15) { url in
            try await validatedDuration(at: url, tolerance: tolerance)
        }
    }

    // Injectable validator lets tests exercise a late AVAsset result without real-time waits.
    // Unstructured work is intentional: AVAsset loading need not respond to cancellation, and
    // a task group would wait for that child even after its timeout branch won.
    static func finalize(_ result: RecordingResult, timeout: TimeInterval,
                         validator: @escaping @Sendable (URL) async throws -> Double) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let race = FinalizationRace(continuation: continuation, timeout: timeout,
                                        partialURL: result.partialURL)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: race.deadline) {
                race.expire()
            }
            Task.detached(priority: .utility) {
                do {
                    let duration = try await validator(result.partialURL)
                    // A late validation result must never start a rename after timeout.
                    guard race.claimPublication() else { return }
                    let url = try publish(partialURL: result.partialURL, context: result.context,
                                          duration: duration, interrupted: result.interruptedReason != nil)
                    race.complete(.success(url))
                } catch {
                    race.complete(.failure(RecorderError("保存を確定できません: \(error.localizedDescription)\n未確定ファイル: \(result.partialURL.path)")))
                }
            }
        }
    }

    /// Container rounding may exceed 300s by at most one video or AAC frame.
    /// 44.1kHz is the larger AAC frame among the two supported input rates.
    static func mediaDurationTolerance(video: VideoConfiguration) -> Double {
        max(video.frameDuration.seconds, 1024.0 / 44_100.0) + 0.000001
    }

    public static func validatedDuration(at url: URL, tolerance: Double = 1.0 / 30.0 + 0.000001) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard video.count == 1, audio.count == 1 else {
            throw RecorderError("完成ファイルの映像・音声トラックまたは尺が不正です。")
        }
        var trackRanges: [CMTimeRange] = []
        for (track, expected) in [(video[0], kCMVideoCodecType_HEVC), (audio[0], kAudioFormatMPEG4AAC)] {
            let descriptions = try await track.load(.formatDescriptions)
            let range = try await track.load(.timeRange)
            guard descriptions.contains(where: { CMFormatDescriptionGetMediaSubType($0) == expected }) else {
                throw RecorderError("完成ファイルのコーデックまたはトラック終端が不正です。")
            }
            trackRanges.append(range)
        }
        try validateTiming(duration: duration, trackRanges: trackRanges, tolerance: tolerance)
        return duration
    }

    // This is the same timing validation used for the actual AVAsset above. Keeping it
    // separate permits boundary/invalid-timestamp tests without encoding five minutes.
    static func validateTiming(duration: Double, trackRanges: [CMTimeRange], tolerance: Double) throws {
        guard tolerance.isFinite, tolerance >= 0, duration.isFinite, duration > 0,
              duration <= 300 + tolerance, trackRanges.count == 2 else {
            throw RecorderError("完成ファイルの映像・音声トラックまたは尺が不正です。")
        }
        for range in trackRanges {
            let end = CMTimeRangeGetEnd(range)
            guard range.start.isNumeric, range.start >= .zero,
                  range.duration.isNumeric, range.duration > .zero,
                  end.isNumeric, end.seconds <= 300 + tolerance else {
                throw RecorderError("完成ファイルのトラック提示範囲が不正です。")
            }
        }
    }

    /// RENAME_EXCL is an atomic same-volume rename. It cannot overwrite a racing destination.
    /// Public for deterministic collision tests; production finalization validates media first.
    public static func publish(partialURL: URL, context: RecordingContext, duration: Double,
                               interrupted: Bool, idGenerator: () -> String = {
                                   String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
                               }) throws -> URL {
        guard duration.isFinite, duration > 0 else { throw RecorderError("録画の尺が不正です。") }
        let timeZone = TimeZone(identifier: context.timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        let folder = FileNaming.directory(root: context.request.settings.root,
                                          instrument: context.request.instrument, startedAt: context.startedAt,
                                          timeZone: timeZone)
        guard folder.standardizedFileURL == partialURL.deletingLastPathComponent().standardizedFileURL else {
            throw RecorderError("未確定ファイルが最終保存ディレクトリにありません。")
        }
        for _ in 0..<64 {
            let name = FileNaming.filename(instrument: context.request.instrument, startedAt: context.startedAt,
                                           duration: duration, id: idGenerator(), interrupted: interrupted,
                                           timeZone: timeZone)
            let destination = folder.appendingPathComponent(name)
            let status = partialURL.path.withCString { source in
                destination.path.withCString { target in renamex_np(source, target, UInt32(RENAME_EXCL)) }
            }
            if status == 0 { return destination }
            if errno == EEXIST { continue }
            throw posixError("録画ファイルの名前を確定できません", path: partialURL.path)
        }
        throw RecorderError("保存名の衝突が続きました。未確定ファイル: \(partialURL.path)")
    }

    private static func posixError(_ message: String, path: String) -> RecorderError {
        let code = errno
        return RecorderError("\(message): \(String(cString: strerror(code)))\n\(path)")
    }
}

/// Only the continuation and publication claim are shared between the timeout queue and
/// the detached validator. Every access is locked; filesystem I/O never runs on MainActor.
private final class FinalizationRace: @unchecked Sendable {
    let deadline: DispatchTime
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var publicationClaimed = false
    private let partialURL: URL

    init(continuation: CheckedContinuation<URL, Error>, timeout: TimeInterval, partialURL: URL) {
        self.continuation = continuation
        self.deadline = .now() + (timeout.isFinite ? max(0, timeout) : 15)
        self.partialURL = partialURL
    }

    func claimPublication() -> Bool {
        lock.lock()
        let available = continuation != nil && !publicationClaimed
        let inTime = DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds
        if available && inTime { publicationClaimed = true }
        lock.unlock()
        if available && !inTime { expire() }
        return available && inTime
    }

    func expire() {
        complete(.failure(RecorderError("保存の確定が15秒以内に完了しませんでした。未確定ファイルまたは保存先を確認してください。\n\(partialURL.path)")))
    }

    func complete(_ result: Result<URL, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        if case .success = result, DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds {
            pending?.resume(throwing: RecorderError("保存の確定が15秒以内に完了しませんでした。保存先を確認してください。\n\(partialURL.path)"))
        } else {
            pending?.resume(with: result)
        }
    }
}
