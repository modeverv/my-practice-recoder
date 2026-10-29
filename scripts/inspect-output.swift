import Foundation
import AVFoundation
@main struct InspectOutput {
 static func main() async throws {
  guard CommandLine.arguments.count == 2 else { fatalError("Usage: swift -parse-as-library scripts/inspect-output.swift PATH.mp4 (use scripts/inspect-output.sh)") }
  let asset=AVURLAsset(url:URL(fileURLWithPath:CommandLine.arguments[1]))
  print("duration=\(try await asset.load(.duration).seconds)")
  for track in try await asset.load(.tracks) {
   let range=try await track.load(.timeRange)
   let formats=try await track.load(.formatDescriptions)
   print("track=\(track.mediaType.rawValue) start=\(range.start.seconds) end=\(CMTimeRangeGetEnd(range).seconds) codec=\(formats.map { String(format:"%08x",CMFormatDescriptionGetMediaSubType($0)) })")
   if track.mediaType == .video {
    print("dimensions=\(try await track.load(.naturalSize)) nominalFPS=\(try await track.load(.nominalFrameRate))")
   }
  }
  if let audio=try await asset.loadTracks(withMediaType:.audio).first {
   let reader=try AVAssetReader(asset:asset)
   let output=AVAssetReaderTrackOutput(track:audio,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false])
   reader.add(output); guard reader.startReading() else { throw reader.error! }
   var sum=0.0, peak:Float=0; var count=0
   while let sample=output.copyNextSampleBuffer(),let block=CMSampleBufferGetDataBuffer(sample) {
    let n=CMBlockBufferGetDataLength(block)
    var data=[Float](repeating:0,count:n/4)
    let status=data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:n,destination:$0.baseAddress!) }
    guard status == noErr else { fatalError("decode PCM copy failed") }
    for v in data { guard v.isFinite else { fatalError("nonfinite PCM") }; sum += Double(v*v); peak=max(peak,abs(v)); count+=1 }
   }
   guard reader.status == .completed,count>0 else { throw reader.error ?? NSError(domain:"decode",code:1) }
   print("decodedAudio samples=\(count) RMS=\(sqrt(sum/Double(count))) peak=\(peak)")
  }
 }
}
