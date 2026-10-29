import AppKit
import AVFoundation
import SwiftUI
import IOKit.pwr_mgt
import PracticeRecorderCore
import PracticeRecorderMedia

@MainActor final class RecordingController: ObservableObject {
 @Published var settings = SettingsStore.load()
 @Published private(set) var phase: RecorderPhase = .preparing
 @Published private(set) var message = "カメラと音声入力を準備します"
 @Published private(set) var elapsed: Double = 0
 @Published private(set) var meter = AudioMeter(left:0,right:0)
 @Published private(set) var captureInfo: CaptureInfo?
 @Published private(set) var cameras: [CaptureDeviceDescriptor] = []
 @Published private(set) var audioDevices: [CaptureDeviceDescriptor] = []
 @Published private(set) var supportedQualities: [QualityProfile] = []
 @Published private(set) var lastSavedURL: URL?
 @Published private(set) var effectiveAudioOffsetMs: Int?
 private var appliedSynchronizationMode: AVSynchronizationMode?
 let capture = CapturePipeline()
 private let writer = MediaWriter()
 private let watchdog = RecordingWatchdog()
 private var lifecycle = TakeLifecycle()
 private var deadline: RecordingDeadline?
 private var displayTimer: Timer?
 private var configureID = UUID()
 private var assertion: IOPMAssertionID = 0
 private var hasAssertion = false
 private var pendingExit: (() -> Void)?
 private var sleepObserver: NSObjectProtocol?
 private var prepared=false
 private var appliedSelection: CaptureSelection?
 private var appliedQuality: QualityProfile?
 private var inputFailure: String?
 var isBusy: Bool { [.arming,.recording,.stopping].contains(phase) }
 private var captureMatchesSettings: Bool { captureInfo != nil && appliedSelection?.cameraID == settings.cameraID && appliedSelection?.audioDeviceID == settings.audioDeviceID && appliedSelection?.leftChannel == settings.leftChannel && appliedSelection?.rightChannel == settings.rightChannel && appliedQuality == settings.quality && settings.leftChannel >= 0 && settings.rightChannel >= 0 && settings.leftChannel < (captureInfo?.audioChannels ?? 0) && settings.rightChannel < (captureInfo?.audioChannels ?? 0) }
 var canRecord: Bool { phase == .ready && captureMatchesSettings }
 var synchronizationDescription: String {
  guard captureMatchesSettings, let offset=effectiveAudioOffsetMs, let mode=appliedSynchronizationMode else { return "同期：入力の確定待ち" }
  if mode == .automaticPTS { return "自動同期（共通PTS）適用済み・追加補正 0 ms" }
  return "手動補正：\(offset > 0 ? "+" : "")\(offset) ms（正値は音声を遅らせます）"
 }
 func refreshSynchronization() {
  guard !isBusy else { return }
  guard captureMatchesSettings else { effectiveAudioOffsetMs=nil; appliedSynchronizationMode=nil; return }
  let plan=AVSynchronizationPlan(mode:settings.effectiveSynchronizationMode,manualOffsetMs:settings.audioOffsetMs)
  appliedSynchronizationMode=plan.mode; effectiveAudioOffsetMs=plan.effectiveAudioOffsetMs
 }
 init() {
  capture.onVideo = { [weak writer] in writer?.appendVideo($0) }
  capture.onAudio = { [weak writer] in writer?.appendAudio($0) }
  capture.onMeter = { [weak self] value in Task { @MainActor in self?.meter=value } }
  capture.onError = { [weak self] error in Task { @MainActor in self?.inputFailed(error) } }
  sleepObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
   Task { @MainActor in self?.stop(reason:"システムのスリープにより中断しました") }
  }
 }
 func prepare() {
  guard !prepared else { return }; prepared=true
  Task {
   for media in [AVMediaType.video,.audio] {
    let status=AVCaptureDevice.authorizationStatus(for:media)
    let allowed = status == .authorized ? true : (status == .notDetermined ? await AVCaptureDevice.requestAccess(for:media) : false)
    guard allowed else {
     phase = .error; message="カメラ／マイクの許可が必要です。システム設定 → プライバシーとセキュリティでPractice Recorderを許可してください。"; return
    }
   }
   applySettings()
  }
 }
 func refreshCameraQualities() { supportedQualities=CapturePipeline.supportedQualities(cameraID:settings.cameraID) }
 func applySettings() {
  guard !isBusy else { return }
  let token=UUID(); configureID=token
  appliedSelection=nil; appliedQuality=nil; inputFailure=nil
  effectiveAudioOffsetMs=nil; appliedSynchronizationMode=nil
  capture.stop()
  cameras=CapturePipeline.cameras(); audioDevices=CapturePipeline.audioDevices()
  supportedQualities=CapturePipeline.supportedQualities(cameraID:settings.cameraID)
  SettingsStore.save(settings)
  captureInfo=nil; meter = .init(left:0,right:0); phase = .preparing
  guard !settings.cameraID.isEmpty, !settings.audioDeviceID.isEmpty else { phase = .error; message="設定でカメラ・RME入力デバイスとLoopback用L/Rを選んで適用してください。"; return }
  guard supportedQualities.contains(settings.quality) else { phase = .error; message="選択カメラがこの画質に対応していません。設定で対応画質を選択してください。"; return }
  let requestedQuality=settings.quality
  let selection=CaptureSelection(cameraID:settings.cameraID,audioDeviceID:settings.audioDeviceID,leftChannel:settings.leftChannel,rightChannel:settings.rightChannel,video:settings.quality.video)
  message="入力の実形式を確認しています…"
  capture.configure(selection) { [weak self] result in Task { @MainActor in
   guard let self, self.configureID == token else { return }
   switch result {
   case .success(let info):
    self.captureInfo=info; self.appliedSelection=selection; self.appliedQuality=requestedQuality; self.phase = .ready
    self.refreshSynchronization()
    self.message=self.canRecord ? "準備完了（無音も録音できます）" : "入力は\(info.audioChannels)chです。設定でLoopbackのL/Rを明示選択してください。"
   case .failure(let error): self.phase = .error; self.message=error.localizedDescription
   }
  } }
 }
 func toggleRecording() {
  if phase == .arming || phase == .recording { stop(reason:nil); return }
  guard canRecord, let info=captureInfo else { return }
  refreshSynchronization()
  guard let offset=effectiveAudioOffsetMs else { return }
  do { try FileStore.preflight(root:URL(fileURLWithPath:settings.rootPath,isDirectory:true)) }
  catch { phase = .error; message=error.localizedDescription; return }
  let request=RecordingRequest(instrument:settings.instrument,
   selection:.init(cameraID:settings.cameraID,audioDeviceID:settings.audioDeviceID,leftChannel:settings.leftChannel,rightChannel:settings.rightChannel,video:info.video),
   settings:.init(root:URL(fileURLWithPath:settings.rootPath,isDirectory:true),quality:settings.quality,audioOffsetMs:offset))
  guard lifecycle.begin(id:request.id) else { return }
  phase = .arming; elapsed=0; lastSavedURL=nil; message="開始する映像・音声を待っています…"; acquireSleepAssertion()
  writer.arm(request,onStarted:{ [weak self, watchdog, writer] context in
   watchdog.start(context:context,writer:writer) { [weak self] in Task { @MainActor in
    guard let self, self.lifecycle.id == context.request.id else { return }
    _=self.lifecycle.stop(id:context.request.id); self.phase = .stopping; self.elapsed=300; self.message="5分に達しました。保存中…"
   } }
   Task { @MainActor in
    guard let self, self.lifecycle.started(id:context.request.id) else { return }
    self.deadline = .init(id:context.request.id,start:context.monotonicStart); self.phase = .recording; self.message="録画中"
    self.displayTimer?.invalidate()
    self.displayTimer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in
     Task { @MainActor in guard let self, self.phase == .recording else { return }; self.elapsed=self.deadline?.elapsed(now:ProcessInfo.processInfo.systemUptime) ?? 0 }
    }
   }
  },onFinished:{ [weak self, watchdog] result in
   watchdog.cancel(id:request.id)
   Task { @MainActor in await self?.finished(id:request.id,result:result) }
  })
 }
 func stop(reason:String?) {
  guard let id=lifecycle.id, lifecycle.stop(id:id) else { return }
  if let deadline { elapsed=deadline.elapsed(now:ProcessInfo.processInfo.systemUptime) }
  phase = .stopping; message="保存中…"; displayTimer?.invalidate(); displayTimer=nil
  writer.stop(id:id,reason:reason)
 }
 private func finished(id:UUID,result:Result<RecordingResult,Error>) async {
  guard lifecycle.id == id else { return }
  phase = .stopping; displayTimer?.invalidate(); displayTimer=nil
  capture.droppedVideoFrameCount { if $0 > 0 { NSLog("PracticeRecorder: capture dropped video frames: %d",$0) } }
  var failed=false
  do {
   let recording=try result.get()
   let url=try await FileStore.finalize(recording)
   lastSavedURL=url; elapsed=min(300,recording.duration)
   message = recording.interruptedReason.map { "中断した録画を保存しました：\($0)\n\(url.path)" } ?? "保存しました：\(url.lastPathComponent)"
  } catch { failed=true; message="保存できませんでした：\(error.localizedDescription)" }
  if let inputFailure { failed=true; message += "\n入力を再準備してください：\(inputFailure)" }
  _=lifecycle.complete(id:id,failed:failed); phase=failed ? .error : .ready
  deadline=nil; releaseSleepAssertion()
  if let callback=pendingExit { pendingExit=nil; callback() }
 }
 private func inputFailed(_ error:String) {
  captureInfo=nil; appliedSelection=nil; inputFailure=error
  effectiveAudioOffsetMs=nil; appliedSynchronizationMode=nil
  if isBusy { stop(reason:error) } else { phase = .error; message=error }
 }
 func requestExit(_ callback:@escaping ()->Void) {
  guard isBusy else { capture.stop(); callback(); return }
  pendingExit={ [weak self] in self?.capture.stop(); callback() }
  stop(reason:"ウィンドウを閉じる／終了するため録画を中断しました")
  // Writer has a 15s finish timeout; this also bounds a delayed filesystem finalize.
  DispatchQueue.main.asyncAfter(deadline:.now()+22) { [weak self] in
   guard let self, let pending=self.pendingExit else { return }
   self.pendingExit=nil; self.message="終了待ちがタイムアウトしました。partialファイルは保存先を確認してください。"
   self.releaseSleepAssertion(); pending()
  }
 }
 func openFolder() { NSWorkspace.shared.open(lastSavedURL?.deletingLastPathComponent() ?? URL(fileURLWithPath:settings.rootPath,isDirectory:true)) }
 func selectFolder() {
  guard !isBusy else { return }; let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=false; panel.allowsMultipleSelection=false
  if panel.runModal() == .OK, let url=panel.url { settings.rootPath=url.path }
 }
 private func acquireSleepAssertion() {
  guard !hasAssertion else { return }
  hasAssertion = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString,IOPMAssertionLevel(kIOPMAssertionLevelOn),"Practice Recorder recording/save" as CFString,&assertion) == kIOReturnSuccess
 }
 private func releaseSleepAssertion() { if hasAssertion { IOPMAssertionRelease(assertion); hasAssertion=false } }
}
