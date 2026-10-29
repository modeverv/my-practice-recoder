import AVFoundation
import PracticeRecorderCore

// Capture session owns captureQueue. Sample callbacks run on its serial deliveryQueue.
// Buffers are retained Swift references; no borrowed AudioBuffer pointer crosses callbacks.
// Writer accepts retained CMSampleBuffer, bounds pending work, and owns a separate serial queue.
// Completion callbacks may run on background queues. App state/UI belongs only to MainActor.
// Install sample/meter/error callbacks before configuring; do not mutate them while running.
public protocol CaptureProviding: AnyObject {
 var session: AVCaptureSession { get }
 var onVideo: ((CMSampleBuffer) -> Void)? { get set }
 var onAudio: ((CMSampleBuffer) -> Void)? { get set }
 var onMeter: ((AudioMeter) -> Void)? { get set }
 var onError: ((String) -> Void)? { get set }
 func configure(_ selection: CaptureSelection, completion: @escaping (Result<CaptureInfo, Error>) -> Void)
 func stop()
}
public protocol WriterProviding: AnyObject {
 func arm(_ request: RecordingRequest, onStarted: @escaping (RecordingContext) -> Void, onFinished: @escaping (Result<RecordingResult, Error>) -> Void)
 func appendVideo(_ sample: CMSampleBuffer)
 func appendAudio(_ sample: CMSampleBuffer)
 func stop(id: UUID, reason: String?)
}
