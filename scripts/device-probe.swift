import Foundation
import AVFoundation
import CoreAudio
print("Camera permission: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue); microphone permission: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (0=notDetermined, 2=denied, 3=authorized)")
for media in [AVMediaType.video, .audio] {
 for d in AVCaptureDevice.DiscoverySession(deviceTypes: media == .video ? [.builtInWideAngleCamera, .external] : [.microphone, .external], mediaType: media, position: .unspecified).devices {
  print("DEVICE \(media.rawValue) name=\(d.localizedName) uid=\(d.uniqueID)")
 }
}
final class Probe: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
 var audio = false; var video = false
 func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
  if let f = CMSampleBufferGetFormatDescription(sample) {
   if output is AVCaptureAudioDataOutput, !audio, let a = CMAudioFormatDescriptionGetStreamBasicDescription(f) { audio=true; print("ACTUAL AUDIO ASBD: \(a.pointee)") }
   if output is AVCaptureVideoDataOutput, !video { video=true; print("ACTUAL VIDEO: \(CMVideoFormatDescriptionGetDimensions(f)) PTS=\(CMSampleBufferGetPresentationTimeStamp(sample))") }
  }
 }
}
let s=AVCaptureSession(); let p=Probe(); let q=DispatchQueue(label:"probe")
for media in [AVMediaType.video, .audio] {
 guard AVCaptureDevice.authorizationStatus(for: media) == .authorized else { print("SKIP \(media.rawValue): permission unavailable; no permission reset or settings change"); continue }
 let ds=AVCaptureDevice.DiscoverySession(deviceTypes: media == .video ? [.builtInWideAngleCamera, .external] : [.microphone, .external], mediaType: media, position: .unspecified).devices
 let d=media == .audio ? ds.first(where: { $0.localizedName.lowercased().contains("fireface") || $0.localizedName.lowercased().contains("rme") }) : (ds.first(where: { $0.localizedName.contains("HP HD") }) ?? ds.first(where: { $0.localizedName.contains("MacBook") }))
 guard let d else { print("SKIP: selected hardware absent"); continue }
 do {
  let i=try AVCaptureDeviceInput(device:d); if s.canAddInput(i) { s.addInput(i) }
  if media == .audio { let o=AVCaptureAudioDataOutput(); o.audioSettings=nil; o.setSampleBufferDelegate(p,queue:q); if s.canAddOutput(o) { s.addOutput(o) } }
  else { let o=AVCaptureVideoDataOutput(); o.setSampleBufferDelegate(p,queue:q); if s.canAddOutput(o) { s.addOutput(o) } }
 } catch { print("ERROR: \(error)") }
}
if !s.inputs.isEmpty {
 print("inputs=\(s.inputs.count) outputs=\(s.outputs.count)")
 s.startRunning(); print("running=\(s.isRunning) connections=\(s.connections.count)")
 RunLoop.current.run(until:Date().addingTimeInterval(5)); s.stopRunning()
}
print("Probe finished; received audio=\(p.audio) video=\(p.video)")
