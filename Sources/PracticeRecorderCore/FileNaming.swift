import Foundation

public enum FileNaming {
    /// Half seconds round upward; a 300-second take is never labelled 05m01s.
    public static func roundedSeconds(_ duration: Double) -> Int {
        guard duration.isFinite else { return 0 }
        return Int(min(300, max(0, duration)).rounded(.toNearestOrAwayFromZero))
    }

    public static func directory(root: URL, instrument: Instrument, startedAt: Date,
                                 timeZone: TimeZone = .current) -> URL {
        root.appendingPathComponent(instrument.rawValue, isDirectory: true)
            .appendingPathComponent(format("yyyy", date: startedAt, timeZone: timeZone), isDirectory: true)
            .appendingPathComponent(format("MM", date: startedAt, timeZone: timeZone), isDirectory: true)
    }

    public static func filename(instrument: Instrument, startedAt: Date, duration: Double,
                                id: String, interrupted: Bool = false,
                                timeZone: TimeZone = .current) -> String {
        let seconds = roundedSeconds(duration)
        let length = String(format: "%02dm%02ds", seconds / 60, seconds % 60)
        // IDs are identifiers, never path components supplied by the user.
        let safeID = String(id.lowercased().filter { $0.isASCII && ($0.isNumber || ("a"..."z").contains(String($0))) }.prefix(8))
        return "\(instrument.rawValue)-\(format("yyyy-MM-dd-HHmmss", date: startedAt, timeZone: timeZone))-\(length)-\(safeID)\(interrupted ? "-interrupted" : "").mp4"
    }

    private static func format(_ pattern: String, date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
