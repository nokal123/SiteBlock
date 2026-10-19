import Foundation

/// The fixed choices and the wording rules behind the app's "For a while" unblock form. They live in the library, not in the view, so they can be tested without a window. Nothing here talks to the daemon; the daemon applies its own limits again when the request arrives.
public enum TemporaryUnblockOptions {
    /// How long a site can be offered to stay open, in seconds: 15 minutes, 30 minutes, 1 hour, 2 hours and 4 hours. All of them sit inside the daemon's range of 5 minutes to 4 hours.
    public static let windowChoices = [900, 1_800, 3_600, 7_200, 14_400]

    /// The waits before a site opens, in seconds, that are offered besides the unblock delay itself: 2, 3, 4, 6, 8, 12 and 24 hours.
    private static let extraStartChoices = [2, 3, 4, 6, 8, 12, 24].map { $0 * 3_600 }

    /// The waits before a site opens that the form offers, shortest first: the unblock delay itself (the soonest the daemon allows) and every one of 2, 3, 4, 6, 8, 12 and 24 hours that is longer than the delay. With a delay of 24 hours or more, only the delay is offered.
    public static func startChoices(delaySeconds: Int) -> [Int] {
        [delaySeconds] + extraStartChoices.filter { $0 > delaySeconds }
    }

    /// Names a length of time for the pickers and the row. A whole number of hours from 1 to 24 is written in hours ("24 hours", not "1 day"), because the choices are written that way; anything else uses the usual wording ("15 minutes", "1 hour 30 minutes", "2 days").
    public static func label(forSeconds seconds: Int) -> String {
        if seconds >= 3_600, seconds <= 86_400, seconds % 3_600 == 0 {
            let hours = seconds / 3_600
            return "\(hours) \(hours == 1 ? "hour" : "hours")"
        }
        return Formatting.duration(seconds)
    }
}
