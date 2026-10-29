import AVFoundation
import PracticeRecorderCore

/// Session mutations are confined to captureQueue. Delegate/readiness state is confined to
/// deliveryQueue; it never waits for captureQueue. Callbacks must return promptly.
public final class CapturePipeline: NSObject, CaptureProviding, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public let session = AVCaptureSession()
    public var onVideo: ((CMSampleBuffer) -> Void)?
    public var onAudio: ((CMSampleBuffer) -> Void)?
    public var onMeter: ((AudioMeter) -> Void)?
    public var onError: ((String) -> Void)?
    private let captureQueue = DispatchQueue(label: "PracticeRecorder.capture", qos: .userInitiated)
    private let deliveryQueue = DispatchQueue(label: "PracticeRecorder.capture.delivery", qos: .userInitiated)
    private var selection: CaptureSelection?
    private var actualVideo: VideoConfiguration?
    // Identity gates reject already-queued callbacks from a removed output after reconfigure.
    private var activeVideoOutput: AVCaptureVideoDataOutput?
    private var activeAudioOutput: AVCaptureAudioDataOutput?
    private var audioASBD: AudioStreamBasicDescription?
    private var gotVideo = false
    private var readyCompletion: ((Result<CaptureInfo, Error>) -> Void)?
    private var began: Double = 0
    private var lastVideo: Double = 0
    private var lastAudio: Double = 0
    private var lastMeter: Double = 0
    private var failureReported = false
    private var monitor: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var droppedFrames = 0

    public override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice else { return }
            self?.deliveryQueue.async { [weak self] in
                guard let self, let selected = self.selection, [selected.cameraID, selected.audioDeviceID].contains(device.uniqueID) else { return }
                self.fail("選択したデバイスが切断されました: \(device.localizedName)")
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "キャプチャでエラーが発生しました。"
            self?.deliveryQueue.async { self?.fail(message) }
        })
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); monitor?.cancel() }

    public static func cameras() -> [CaptureDeviceDescriptor] {
        videoDevices().map { CaptureDeviceDescriptor(id: $0.uniqueID, name: $0.localizedName) }
    }
    public static func audioDevices() -> [CaptureDeviceDescriptor] {
        soundDevices().map { CaptureDeviceDescriptor(id: $0.uniqueID, name: $0.localizedName) }
    }
    private static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
    }
    private static func soundDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    private static func formatChoice(device: AVCaptureDevice, video: VideoConfiguration) -> (AVCaptureDevice.Format, CMTime)? {
        let fps = 1 / video.frameDuration.seconds
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == video.width, dimensions.height == video.height else { continue }
            for range in format.videoSupportedFrameRateRanges {
                if fps >= range.minFrameRate && fps <= range.maxFrameRate { return (format, video.frameDuration) }
                // Treat a native 29.97/59.94 mode as that actual rational duration, never 30/60.
                if abs(range.maxFrameRate - fps) < 0.12 { return (format, range.minFrameDuration) }
            }
        }
        return nil
    }
    public static func supportedQualities(cameraID: String) -> [QualityProfile] {
        guard let device = videoDevices().first(where: { $0.uniqueID == cameraID }) else { return [] }
        return QualityProfile.allCases.filter { formatChoice(device: device, video: $0.video) != nil }
    }

    public func configure(_ selection: CaptureSelection, completion: @escaping (Result<CaptureInfo, Error>) -> Void) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            // Detach old delegates before flushing delivery work and installing new outputs.
            for output in self.session.outputs {
                (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
                (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            }
            self.deliveryQueue.sync {
                self.monitor?.cancel(); self.monitor = nil
                self.readyCompletion?(.failure(RecorderError("設定変更により準備を中止しました。")))
                self.readyCompletion = nil; self.selection = nil
                self.activeVideoOutput = nil; self.activeAudioOutput = nil
            }
            do {
                guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                      AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw RecorderError("カメラと音声入力の権限が必要です。システム設定で許可してください。") }
                guard let camera = Self.videoDevices().first(where: { $0.uniqueID == selection.cameraID }) else { throw RecorderError("選択したカメラが接続されていません。") }
                guard let audio = Self.soundDevices().first(where: { $0.uniqueID == selection.audioDeviceID }) else { throw RecorderError("選択した音声デバイスが接続されていません。別の入力へ自動切替は行いません。") }
                guard let (format, duration) = Self.formatChoice(device: camera, video: selection.video) else { throw RecorderError("このカメラは選択画質に対応していません。設定から対応画質を選択してください。") }
                self.session.beginConfiguration()
                self.session.inputs.forEach(self.session.removeInput)
                self.session.outputs.forEach(self.session.removeOutput)
                do {
                    for device in [camera, audio] {
                        let input = try AVCaptureDeviceInput(device: device)
                        guard self.session.canAddInput(input) else { throw RecorderError("キャプチャ入力を追加できません: \(device.localizedName)") }
                        self.session.addInput(input)
                    }
                    // Only the camera's format/frame duration is set. No audio device properties are written.
                    try camera.lockForConfiguration()
                    camera.activeFormat = format
                    camera.activeVideoMinFrameDuration = duration
                    camera.activeVideoMaxFrameDuration = duration
                    camera.unlockForConfiguration()
                    let videoOutput = AVCaptureVideoDataOutput()
                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                    videoOutput.setSampleBufferDelegate(self, queue: self.deliveryQueue)
                    let audioOutput = AVCaptureAudioDataOutput()
                    audioOutput.audioSettings = nil
                    audioOutput.setSampleBufferDelegate(self, queue: self.deliveryQueue)
                    guard self.session.canAddOutput(videoOutput), self.session.canAddOutput(audioOutput) else { throw RecorderError("映像・音声出力を追加できません。") }
                    self.session.addOutput(videoOutput); self.session.addOutput(audioOutput)
                    if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
                    self.session.commitConfiguration()
                } catch { self.session.commitConfiguration(); throw error }
                let actual = VideoConfiguration(width: selection.video.width, height: selection.video.height, frameDuration: duration, bitrate: selection.video.bitrate)
                self.deliveryQueue.sync {
                    self.activeVideoOutput = self.session.outputs.compactMap { $0 as? AVCaptureVideoDataOutput }.first
                    self.activeAudioOutput = self.session.outputs.compactMap { $0 as? AVCaptureAudioDataOutput }.first
                    self.selection = selection; self.actualVideo = actual; self.audioASBD = nil; self.gotVideo = false
                    self.failureReported = false; self.droppedFrames = 0
                    self.readyCompletion = completion; self.began = ProcessInfo.processInfo.systemUptime
                    self.lastVideo = self.began; self.lastAudio = self.began
                    let timer = DispatchSource.makeTimerSource(queue: self.deliveryQueue)
                    timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
                    timer.setEventHandler { [weak self] in self?.checkInputs() }
                    self.monitor = timer; timer.resume()
                }
                self.session.startRunning()
            } catch { completion(.failure(error)) }
        }
    }
    public func stop() { stop(completion: {}) }
    public func stop(completion: @escaping () -> Void) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            self.deliveryQueue.async {
                self.monitor?.cancel(); self.monitor = nil; self.selection = nil
                self.activeVideoOutput = nil; self.activeAudioOutput = nil
                self.readyCompletion?(.failure(RecorderError("キャプチャ準備を中止しました。"))); self.readyCompletion = nil
                completion()
            }
        }
    }
    private func checkInputs() {
        guard selection != nil, !failureReported else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if readyCompletion != nil {
            if now - began > 3 { fail("3秒以内に映像と音声の両方を取得できませんでした（無音と入力断は別です）。") }
        } else if now - lastAudio > 2 || now - lastVideo > 2 {
            fail("入力が2秒以上途絶えました。映像: \(String(format:"%.1f",now-lastVideo))秒 / 音声: \(String(format:"%.1f",now-lastAudio))秒")
        }
    }
    private func fail(_ message: String) {
        guard !failureReported else { return }; failureReported = true
        if let completion = readyCompletion { readyCompletion = nil; completion(.failure(RecorderError(message))) }
        else { onError?(message) }
    }
    private func completeIfReady() {
        guard let completion = readyCompletion, gotVideo, let video = actualVideo, let asbd = audioASBD else { return }
        readyCompletion = nil
        completion(.success(CaptureInfo(video: video, audioChannels: Int(asbd.mChannelsPerFrame), sampleRate: asbd.mSampleRate, audioDescription: "\(Int(asbd.mSampleRate)) Hz / \(asbd.mChannelsPerFrame) ch / \(asbd.mBitsPerChannel) bit / flags \(asbd.mFormatFlags)")))
    }
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let selected = selection, !failureReported, CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferGetPresentationTimeStamp(sampleBuffer).isValid else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if output === activeVideoOutput {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer), let video = actualVideo else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            guard dimensions.width == video.width, dimensions.height == video.height else { fail("カメラの実解像度が選択画質と一致しません。録画は開始できません。"); return }
            lastVideo = now; gotVideo = true; completeIfReady(); onVideo?(sampleBuffer)
        } else if output === activeAudioOutput {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer), let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { fail("音声ASBDが取得できません。"); return }
            let asbd = pointer.pointee
            if let old = audioASBD, !PCMExtractor.hasSameSignalFormat(old, asbd) {
                NSLog("PracticeRecorder: native audio format changed from %@ to %@", String(describing: old), String(describing: asbd))
                fail("音声デバイスの形式が変わりました。設定は変更していません。再準備してください。"); return
            }
            guard asbd.mSampleRate == 44_100 || asbd.mSampleRate == 48_000 else { fail("入力\(asbd.mSampleRate) Hzは未対応です。デバイス設定は変更していません。44.1/48 kHzが必要です。"); return }
            audioASBD = asbd; lastAudio = now
            do {
                if selected.leftChannel >= 0 && selected.rightChannel >= 0 {
                    let extracted = try PCMExtractor.extract(sampleBuffer, left: selected.leftChannel, right: selected.rightChannel)
                    onAudio?(extracted.sampleBuffer)
                    if now - lastMeter >= 0.075 { lastMeter = now; onMeter?(extracted.meter) }
                }
                completeIfReady()
            } catch { fail(error.localizedDescription) }
        }
    }
    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === activeVideoOutput { droppedFrames += 1 }
    }
    public func droppedVideoFrameCount(completion: @escaping (Int) -> Void) { deliveryQueue.async { completion(self.droppedFrames) } }
}
