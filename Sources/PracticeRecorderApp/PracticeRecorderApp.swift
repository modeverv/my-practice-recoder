import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
 weak var controller: RecordingController?
 private var observer: NSObjectProtocol?
 private var closing=false
 func applicationDidFinishLaunching(_ notification:Notification) {
  NSApp.setActivationPolicy(.regular)
  // The running Dock tile can retain the generic Swift-package executable icon
  // even when Finder resolves CFBundleIconFile. Set the process icon explicitly.
  if let url=Bundle.main.url(forResource:"PracticeRecorder",withExtension:"icns"),
     let icon=NSImage(contentsOf:url) {
   NSApp.applicationIconImage=icon
   NSApp.dockTile.display()
  } else {
   NSLog("PracticeRecorder: bundled Dock icon could not be loaded")
  }
  observer=NotificationCenter.default.addObserver(forName:NSWindow.didBecomeMainNotification,object:nil,queue:.main) { [weak self] notification in
   MainActor.assumeIsolated { (notification.object as? NSWindow)?.delegate=self }
  }
  NSApp.activate(ignoringOtherApps:true)
 }
 func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
  guard let controller, controller.isBusy else { return .terminateNow }
  controller.requestExit { sender.reply(toApplicationShouldTerminate:true) }
  return .terminateLater
 }
 func windowShouldClose(_ sender:NSWindow) -> Bool {
  guard !closing, let controller, controller.isBusy else { return true }
  controller.requestExit { [weak self, weak sender] in self?.closing=true; sender?.close(); NSApp.terminate(nil) }
  return false
 }
 func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
}
@main struct PracticeRecorderApp: App {
 @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
 @StateObject private var controller=RecordingController()
 var body: some Scene {
  Window("Practice Recorder",id:"recorder") {
   RecorderView(controller:controller).onAppear { delegate.controller=controller; controller.prepare() }
  }.defaultSize(width:920,height:760)
 }
}
