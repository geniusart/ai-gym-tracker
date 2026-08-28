import Foundation

/// Formatting shared by the app, the widgets and the watch. Each target used
/// to carry its own copy; they drifted, so the same 102.25 kg set printed as
/// "102.3" in the executor and "102.25" in history.
enum WorkoutFormatting {

    /// Formats a weight in kg, omitting the decimal when it is an integer.
    /// 100.0 -> "100"; 102.5 -> "102.5"; 102.25 -> "102.25".
    static func weight(_ kg: Double) -> String {
        guard kg.isFinite else { return "--" }
        if kg.rounded() == kg, abs(kg) < 1e9 {
            return String(Int(kg))
        }
        return weightFormatter.string(from: NSNumber(value: kg)) ?? "\(kg)"
    }

    /// "M:SS" for anything under an hour, "H:MM:SS" above it.
    static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Compact human duration: "45s", "2 min", "2:30", "1:05:00".
    static func compactDuration(_ seconds: Int) -> String {
        let total = max(0, seconds)
        if total < 60 { return "\(total)s" }
        if total < 3600, total % 60 == 0 { return "\(total / 60) min" }
        return clock(total)
    }

    private static let weightFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.decimalSeparator = "."
        return f
    }()
}
