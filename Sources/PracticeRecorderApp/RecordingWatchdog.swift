import Foundation
import PracticeRecorderCore
import PracticeRecorderMedia

/// All timer state is confined to queue. This timer calls the writer directly,
/// without depending on MainActor, SwiftUI, or a display Timer firing.
final class RecordingWatchdog {
 private let queue = DispatchQueue(label:"PracticeRecorder.watchdog")
 private var timer: DispatchSourceTimer?
 private var currentID: UUID?
 func start(context:RecordingContext, writer:MediaWriter, expired:@escaping ()->Void) {
  queue.async { [self] in
   timer?.cancel(); currentID=context.request.id
   let deadline=RecordingDeadline(id:context.request.id,start:context.monotonicStart)
   let source=DispatchSource.makeTimerSource(queue:queue)
   source.schedule(deadline:.now() + max(0,300 - (ProcessInfo.processInfo.systemUptime-context.monotonicStart)))
   source.setEventHandler { [weak self] in
    guard let self, self.currentID == deadline.id else { return }
    writer.stop(id:deadline.id,reason:nil)
    self.timer?.cancel(); self.timer=nil; self.currentID=nil
    expired()
   }
   timer=source; source.resume()
  }
 }
 func cancel(id:UUID) { queue.async { [self] in guard currentID == id else { return }; timer?.cancel(); timer=nil; currentID=nil } }
}
