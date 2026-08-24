import Foundation

enum DurationFormatter {
  static func string(from duration: TimeInterval) -> String {
    guard duration.isFinite, duration >= 0 else { return "0:00" }
    let totalSeconds = Int(duration.rounded(.down))
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
  }
}
