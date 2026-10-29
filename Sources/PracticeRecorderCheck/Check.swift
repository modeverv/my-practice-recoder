import Foundation
import AVFoundation
import PracticeRecorderCore
import PracticeRecorderMedia

/// Explicit hardware smoke test. Does not pick an audio pair or change hardware settings.
@main struct HardwareCheck {
 static func main() async {
  do { try await run() } catch { fputs("FAILED: \(error.localizedDescription)\n",stderr); exit(1) }
 }
 static func run() async throws {
  let args=CommandLine.arguments
  func argument(_ key:String)->String? { guard let i=args.firstIndex(of:key),i+1<args.count else { return nil }; return args[i+1] }
  if args.contains("--list") {
   for d in CapturePipeline.cameras() { print("CAMERA \(d.id) \(d.name) qualities=\(CapturePipeline.supportedQualities(cameraID:d.id).map(\.title))") }
   for d in CapturePipeline.audioDevices() { print("AUDIO \(d.id) \(d.name)") }
   return
  }
  guard let camera=argument("--camera"),let audio=argument("--audio"),let left=argument("--left").flatMap(Int.init),let right=argument("--right").flatMap(Int.init),left>0,right>0 else {
   throw RecorderError("Usage: swift run PracticeRecorderCheck --list | --camera UID --audio UID --left 11 --right 12 [--seconds 6] [--output /path]")
  }
  guard AVCaptureDevice.authorizationStatus(for:.video) == .authorized, AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else { throw RecorderError("このCLIにカメラとマイクの権限がありません。アプリで許可し、別途実機テストしてください。") }
  let pipeline=CapturePipeline(); let writer=MediaWriter(); let testID=UUID()
  pipeline.onError={ error in writer.stop(id:testID,reason:error) }
  let quality:QualityProfile = args.contains("--1080") ? .p1080_30 : .p720_30
  let seconds=min(300,max(1,Double(argument("--seconds") ?? "6") ?? 6))
  let root=URL(fileURLWithPath:argument("--output") ?? NSTemporaryDirectory()+"PracticeRecorder-hardware-check",isDirectory:true)
  let selection=CaptureSelection(cameraID:camera,audioDeviceID:audio,leftChannel:left-1,rightChannel:right-1,video:quality.video)
  pipeline.onVideo={ writer.appendVideo($0) }; pipeline.onAudio={ writer.appendAudio($0) }
  pipeline.onMeter={ meter in print("METER L=\(meter.left) R=\(meter.right)") }
  let info:CaptureInfo=try await withCheckedThrowingContinuation { c in pipeline.configure(selection) { c.resume(with:$0) } }
  print("ACTUAL \(info.video.title), audio \(info.sampleRate) Hz \(info.audioChannels)ch: \(info.audioDescription), selected L=\(left) R=\(right)")
  try FileStore.preflight(root:root)
  let request=RecordingRequest(id:testID,instrument:.other,selection:.init(cameraID:camera,audioDeviceID:audio,leftChannel:left-1,rightChannel:right-1,video:info.video),settings:.init(root:root,quality:quality,audioOffsetMs:0))
  let result:RecordingResult=try await withCheckedThrowingContinuation { c in
   writer.arm(request,onStarted:{ context in
    print("START t0=\(context.startPTS.seconds) actual date=\(context.startedAt)")
    DispatchQueue.global().asyncAfter(deadline:.now()+seconds) { writer.stop(id:request.id,reason:nil) }
   },onFinished:{ c.resume(with:$0) })
  }
  pipeline.stop()
  let final=try await FileStore.finalize(result)
  print("SAVED \(final.path), measured duration=\(result.duration), interrupted=\(result.interruptedReason ?? "none")")
 }
}
