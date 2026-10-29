import SwiftUI
import AVFoundation
import PracticeRecorderCore

struct RecorderView: View {
    @ObservedObject var controller: RecordingController
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Practice Recorder").font(.title2.bold())
                Spacer()
                Button("設定…") { showingSettings = true }.disabled(controller.isBusy)
            }
            CameraPreview(session: controller.capture.session)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(minHeight: 230, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    Text(phaseTitle).font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white).padding(12)
                }
            Picker("楽器", selection: $controller.settings.instrument) {
                ForEach(Instrument.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).disabled(controller.isBusy)
            .onChange(of: controller.settings.instrument) { _, _ in SettingsStore.save(controller.settings) }
            VStack(spacing: 8) {
                Text(audioSelection).font(.callout).lineLimit(2)
                HStack(spacing: 24) {
                    PeakMeter(label: "L", peak: controller.meter.left)
                    PeakMeter(label: "R", peak: controller.meter.right)
                }
                Text(controller.synchronizationDescription)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(timeText).font(.system(size: 40, weight: .medium, design: .monospaced))
                .monospacedDigit().foregroundStyle(controller.phase == .recording ? Color.red : Color.primary)
                .accessibilityLabel(timeText)
            Button(action: controller.toggleRecording) {
                HStack {
                    Image(systemName: controller.phase == .recording || controller.phase == .arming ? "stop.fill" : "record.circle")
                    Text(recordButtonTitle)
                }
                .font(.title3.bold()).frame(minWidth: 230, minHeight: 34)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .tint(controller.phase == .recording ? .red : .accentColor)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!controller.canRecord && controller.phase != .recording && controller.phase != .arming)
            Text(controller.message).font(.callout)
                .foregroundStyle(controller.phase == .error ? Color.red : Color.secondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(controller.captureInfo?.video.title ?? controller.settings.quality.title) / HEVC・AAC")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("保存フォルダーをFinderで開く", action: controller.openFolder)
            }
        }
        .padding(22).frame(minWidth: 750, minHeight: 680)
        .sheet(isPresented: $showingSettings) { RecorderSettingsView(controller: controller) }
    }

    private var phaseTitle: String {
        switch controller.phase {
        case .preparing: return "準備中"
        case .ready: return "待機中"
        case .arming: return "録画準備中"
        case .recording: return "録画中"
        case .stopping: return "保存中"
        case .error: return "エラー"
        }
    }
    private var recordButtonTitle: String {
        switch controller.phase {
        case .arming: return "開始を取り消す"
        case .recording: return "停止して保存"
        case .stopping: return "保存中…"
        default: return "録画開始"
        }
    }
    private var timeText: String {
        let seconds = controller.phase == .recording || controller.phase == .stopping
            ? min(300, max(0, Int(controller.elapsed))) : 0
        let prefix = controller.phase == .recording ? "REC " : ""
        return prefix + String(format: "%02d:%02d / 05:00", seconds / 60, seconds % 60)
    }
    private var audioSelection: String {
        let name = controller.audioDevices.first(where: { $0.id == controller.settings.audioDeviceID })?.name ?? "音声デバイス未選択"
        let left = controller.settings.leftChannel >= 0 ? "Ch \(controller.settings.leftChannel + 1)" : "未選択"
        let right = controller.settings.rightChannel >= 0 ? "Ch \(controller.settings.rightChannel + 1)" : "未選択"
        return "\(name)  入力 L: \(left) / R: \(right)"
    }
}

private struct PeakMeter: View {
    let label: String
    let peak: Float
    private var db: Double { max(-60, min(0, 20 * log10(max(Double(peak), 0.000001)))) }
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption.monospaced().bold())
            GeometryReader { geometry in
                Capsule().fill(Color.secondary.opacity(0.16))
                    .overlay(alignment: .leading) {
                        Capsule().fill(peak >= 0.98 ? Color.red : Color.green)
                            .frame(width: geometry.size.width * CGFloat((db + 60) / 60))
                    }
            }.frame(height: 10)
            Text(peak > 0.000001 ? String(format: "%3.0f dB", db) : "−∞ dB")
                .font(.caption.monospaced()).frame(width: 55)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("入力\(label)、\(peak > 0.000001 ? String(format: "%.0fデシベル", db) : "無音")")
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }
    func updateNSView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        view.disableMirroring()
    }
}

private final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        disableMirroring()
    }
    func disableMirroring() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
    }
}
