import Foundation

/// Shared human-readable text for durations, so the CLI and the app say the same thing.
public enum Formatting {
    /// Describes a length of time in words using at most the two largest non-zero units, for example "45 seconds", "1 hour 5 minutes" or "2 days 3 hours".
    public static func duration(_ seconds: Int) -> String {
        var remaining = max(0, seconds)
        let units: [(name: String, size: Int)] = [("day", 86_400), ("hour", 3_600), ("minute", 60), ("second", 1)]
        var parts: [String] = []
        for unit in units {
            let count = remaining / unit.size
            remaining %= unit.size
            if count > 0 { parts.append("\(count) \(unit.name)\(count == 1 ? "" : "s")") }
            if parts.count == 2 { break }
        }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }

    /// Pads a number to at least two digits.
    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// Describes a length of time as a running clock: "29:41" under an hour, "1:05:09" under a day, "2d 03:04:05" from a day up. The leading unit is not padded.
    public static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if total >= 86_400 { return "\(days)d \(twoDigits(hours)):\(twoDigits(minutes)):\(twoDigits(secs))" }
        if total >= 3_600 { return "\(hours):\(twoDigits(minutes)):\(twoDigits(secs))" }
        return "\(minutes):\(twoDigits(secs))"
    }

    /// Turns text such as "90", "90s", "15m", "2h", "1d" or "1h30m" into seconds, or nil for anything else. A plain number is seconds, and each unit may appear only once.
    public static func parseDuration(_ text: String) -> Int? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.isEmpty { return nil }
        // Only ASCII digits count; Character.isNumber would also accept digits from other scripts.
        func isDigit(_ character: Character) -> Bool { character >= "0" && character <= "9" && character.isASCII }
        // A plain number is in seconds. Int(_:) returns nil when the digits are too many to fit, which gives the nil we want.
        if cleaned.allSatisfy(isDigit) { return Int(cleaned) }
        let unitSizes: [Character: Int] = ["d": 86_400, "h": 3_600, "m": 60, "s": 1]
        var total = 0
        var digits = ""
        var seenUnits: Set<Character> = []
        for character in cleaned {
            if isDigit(character) {
                digits.append(character)
                continue
            }
            guard let size = unitSizes[character], !digits.isEmpty, !seenUnits.contains(character), let amount = Int(digits) else { return nil }
            seenUnits.insert(character)
            let (product, productOverflow) = amount.multipliedReportingOverflow(by: size)
            let (sum, sumOverflow) = total.addingReportingOverflow(product)
            if productOverflow || sumOverflow { return nil }
            total = sum
            digits = ""
        }
        // Digits left over at the end have no unit (like "1h30"), which is not a valid combination.
        return digits.isEmpty ? total : nil
    }
}
