import Foundation

/// Pure transition model. The app's sole owner is RecordingController on MainActor.
public struct TakeLifecycle {
 public private(set) var phase: RecorderPhase = .ready
 public private(set) var id: UUID?
 public init() {}
 @discardableResult public mutating func begin(id: UUID) -> Bool {
  guard phase == .ready || phase == .error else { return false }
  self.id=id; phase = .arming; return true
 }
 @discardableResult public mutating func started(id: UUID) -> Bool {
  guard self.id == id, phase == .arming else { return false }
  phase = .recording; return true
 }
 @discardableResult public mutating func stop(id: UUID) -> Bool {
  guard self.id == id, phase == .arming || phase == .recording else { return false }
  phase = .stopping; return true
 }
 @discardableResult public mutating func complete(id: UUID, failed: Bool) -> Bool {
  guard self.id == id else { return false }
  self.id=nil; phase = failed ? .error : .ready; return true
 }
}
public struct RecordingDeadline {
 public let id: UUID; public let start: Double
 public init(id:UUID,start:Double) { self.id=id; self.start=start }
 public func elapsed(now:Double) -> Double { min(300,max(0,now-start)) }
 public func expired(id:UUID,now:Double) -> Bool { self.id == id && now-start >= 300 }
}
