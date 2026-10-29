import SwiftUI
import PracticeRecorderCore

struct RecorderSettingsView: View {
    @ObservedObject var controller: RecordingController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("録画設定").font(.title2.bold())
            Form {
                LabeledContent("保存先") {
                    Text(controller.settings.rootPath).lineLimit(2).textSelection(.enabled)
                    Button("選択…", action: controller.selectFolder)
                }
                Picker("カメラ", selection: $controller.settings.cameraID) {
                    Text("選択してください").tag("")
                    ForEach(controller.cameras) { Text($0.name).tag($0.id) }
                }
                .onChange(of: controller.settings.cameraID) { _, _ in controller.refreshCameraQualities() }
                Picker("音声入力", selection: $controller.settings.audioDeviceID) {
                    Text("選択してください").tag("")
                    ForEach(controller.audioDevices) { Text($0.name).tag($0.id) }
                }
                .onChange(of: controller.settings.audioDeviceID) { _, _ in
                    controller.settings.leftChannel = -1
                    controller.settings.rightChannel = -1
                }
                HStack {
                    Text("デバイス変更後は、実際の入力形式を再検出してください。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("入力・画質を再検出", action: controller.applySettings)
                }
                Picker("画質", selection: $controller.settings.quality) {
                    ForEach(controller.supportedQualities) { Text($0.title).tag($0) }
                }
                if let info = controller.captureInfo {
                    LabeledContent("取得形式", value: "\(info.video.title) / \(Int(info.sampleRate)) Hz・\(info.audioChannels) ch")
                    HStack {
                        channelPicker("入力 L", selection: $controller.settings.leftChannel, count: info.audioChannels)
                        channelPicker("入力 R", selection: $controller.settings.rightChannel, count: info.audioChannels)
                    }
                } else {
                    Text("音声バッファを取得すると、L/Rを選択できます。")
                        .foregroundStyle(.secondary)
                }
                Text("TotalMixのLoopbackに対応する入力を、左右それぞれ選択してください。番号は1始まりです。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("映像・音声の同期", selection: synchronizationMode) {
                    ForEach([AVSynchronizationMode.automaticPTS, .manual]) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                if controller.settings.effectiveSynchronizationMode == .manual {
                    Stepper(value: $controller.settings.audioOffsetMs, in: -500...500, step: 10) {
                        Text("音声補正: \(controller.settings.audioOffsetMs > 0 ? "+" : "")\(controller.settings.audioOffsetMs) ms")
                            .monospacedDigit()
                    }
                    .onChange(of: controller.settings.audioOffsetMs) { _, _ in controller.refreshSynchronization() }
                    Text("正値は映像に対して音声を遅らせます。負値は早めます。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("入力確定時に映像・音声の共通PTSを採用し、追加オフセット0msで自動同期します。カメラ内部やLiveの処理遅延を測定する機能ではありません。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(controller.synchronizationDescription)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.formStyle(.grouped)
            Text(controller.message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack {
                Text("録画は1テイク最大5分。自動で次の録画は開始しません。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("適用して閉じる") { controller.applySettings(); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 720)
            .disabled(controller.isBusy)
    }

    private var synchronizationMode: Binding<AVSynchronizationMode> {
        Binding(
            get: { controller.settings.effectiveSynchronizationMode },
            set: {
                controller.settings.synchronizationMode = $0
                controller.refreshSynchronization()
            }
        )
    }

    private func channelPicker(_ label: String, selection: Binding<Int>, count: Int) -> some View {
        Picker(label, selection: selection) {
            Text("未選択").tag(-1)
            ForEach(0..<max(0, count), id: \.self) { Text("Ch \($0 + 1)").tag($0) }
        }
    }
}
