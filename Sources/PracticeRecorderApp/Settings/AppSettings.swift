import Foundation
import PracticeRecorderCore

struct AppSettings: Codable, Equatable {
    var rootPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/PracticeRecorder", isDirectory: true).path
    var cameraID = ""
    var audioDeviceID = ""
    var leftChannel = -1
    var rightChannel = -1
    var quality: QualityProfile = .p1080_30
    var audioOffsetMs = 0
    // Optional so settings written before synchronization modes still decode.
    var synchronizationMode: AVSynchronizationMode? = .automaticPTS
    var effectiveSynchronizationMode: AVSynchronizationMode { synchronizationMode ?? .automaticPTS }
    var instrument: Instrument = .guitar
}

enum SettingsStore {
    private static let key = "PracticeRecorder.settings.v1"
    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        settings.audioOffsetMs = min(500, max(-500, settings.audioOffsetMs / 10 * 10))
        if settings.leftChannel < -1 { settings.leftChannel = -1 }
        if settings.rightChannel < -1 { settings.rightChannel = -1 }
        return settings
    }
    static func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: key) }
    }
}
