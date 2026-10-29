import Foundation

public enum AVSynchronizationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automaticPTS
    case manual

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automaticPTS: return "自動（共通PTS）"
        case .manual: return "手動補正"
        }
    }
}

/// A per-take choice of additional audio correction. Automatic mode preserves
/// the shared capture-session timeline; it does not estimate physical latency.
/// Building a plan never changes the user's stored manual correction.
public struct AVSynchronizationPlan: Equatable, Sendable {
    public let mode: AVSynchronizationMode
    public let effectiveAudioOffsetMs: Int

    public init(mode: AVSynchronizationMode, manualOffsetMs: Int) {
        self.mode = mode
        switch mode {
        case .automaticPTS:
            effectiveAudioOffsetMs = 0
        case .manual:
            let clamped = max(-500, min(500, manualOffsetMs))
            effectiveAudioOffsetMs = Int((Double(clamped) / 10).rounded(.toNearestOrAwayFromZero)) * 10
        }
    }
}
