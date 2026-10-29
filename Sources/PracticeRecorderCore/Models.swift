import Foundation
import CoreMedia

public enum Instrument: String, Codable, CaseIterable, Identifiable, Sendable {
 case guitar, bass, drums, piano, other
 public var id: String { rawValue }
 public var title: String { rawValue.capitalized }
}
public enum QualityProfile: String, Codable, CaseIterable, Identifiable, Sendable {
 case p1080_30, p1080_60, p720_30
 public var id: String { rawValue }
 public var title: String { switch self { case .p1080_30: return "1080p30"; case .p1080_60: return "1080p60"; case .p720_30: return "720p30" } }
 public var video: VideoConfiguration {
  switch self {
  case .p1080_30: return .init(width:1920,height:1080,frameDuration:CMTime(value:1,timescale:30),bitrate:3_000_000)
  case .p1080_60: return .init(width:1920,height:1080,frameDuration:CMTime(value:1,timescale:60),bitrate:5_000_000)
  case .p720_30: return .init(width:1280,height:720,frameDuration:CMTime(value:1,timescale:30),bitrate:1_500_000)
  }
 }
}
public struct VideoConfiguration: Equatable, Sendable {
 public let width: Int; public let height: Int; public let frameDuration: CMTime; public let bitrate: Int
 public init(width:Int,height:Int,frameDuration:CMTime,bitrate:Int) { self.width=width; self.height=height; self.frameDuration=frameDuration; self.bitrate=bitrate }
 public var title: String { "\(width)×\(height) / \(String(format:"%.3f", 1 / frameDuration.seconds)) fps" }
}
public struct CaptureSelection: Sendable {
 public let cameraID: String; public let audioDeviceID: String; public let leftChannel: Int; public let rightChannel: Int; public let video: VideoConfiguration
 public init(cameraID:String,audioDeviceID:String,leftChannel:Int,rightChannel:Int,video:VideoConfiguration) { self.cameraID=cameraID; self.audioDeviceID=audioDeviceID; self.leftChannel=leftChannel; self.rightChannel=rightChannel; self.video=video }
}
public struct RecordingSettings: Sendable {
 public let root: URL; public let quality: QualityProfile; public let audioOffsetMs: Int
 public let limitSeconds: Double = 300
 public init(root:URL,quality:QualityProfile,audioOffsetMs:Int) { self.root=root; self.quality=quality; self.audioOffsetMs=audioOffsetMs }
}
public struct RecordingRequest: Sendable {
 public let id: UUID; public let instrument: Instrument; public let selection: CaptureSelection; public let settings: RecordingSettings
 public init(id:UUID = UUID(),instrument:Instrument,selection:CaptureSelection,settings:RecordingSettings) { self.id=id; self.instrument=instrument; self.selection=selection; self.settings=settings }
}
public struct RecordingContext: Sendable {
 public let request: RecordingRequest; public let startedAt: Date; public let startPTS: CMTime; public let monotonicStart: Double; public let timeZoneIdentifier: String
 public init(request:RecordingRequest,startedAt:Date,startPTS:CMTime,monotonicStart:Double,timeZoneIdentifier:String = TimeZone.current.identifier) { self.request=request; self.startedAt=startedAt; self.startPTS=startPTS; self.monotonicStart=monotonicStart; self.timeZoneIdentifier=timeZoneIdentifier }
}
public enum RecorderPhase: String, Sendable { case preparing, ready, arming, recording, stopping, error }
public struct CaptureDeviceDescriptor: Identifiable, Sendable {
 public let id: String; public let name: String
 public init(id:String,name:String) { self.id=id; self.name=name }
}
public struct CaptureInfo: Sendable {
 public let video: VideoConfiguration; public let audioChannels: Int; public let sampleRate: Double; public let audioDescription: String
 public init(video:VideoConfiguration,audioChannels:Int,sampleRate:Double,audioDescription:String) { self.video=video; self.audioChannels=audioChannels; self.sampleRate=sampleRate; self.audioDescription=audioDescription }
}
public struct AudioMeter: Sendable {
 public let left: Float; public let right: Float
 public init(left:Float,right:Float) { self.left=left; self.right=right }
}
public struct RecordingResult: Sendable {
 public let context: RecordingContext; public let partialURL: URL; public let duration: Double; public let interruptedReason: String?
 public init(context:RecordingContext,partialURL:URL,duration:Double,interruptedReason:String?) { self.context=context; self.partialURL=partialURL; self.duration=duration; self.interruptedReason=interruptedReason }
}
public struct RecorderError: LocalizedError, Sendable {
 public let message: String
 public init(_ message:String) { self.message=message }
 public var errorDescription: String? { message }
}
