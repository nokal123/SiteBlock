import SiteBlockCore
import SwiftUI

/// What the "For a while" form collects, ready to send to the daemon.
struct TemporaryUnblockChoice {
    /// How long the site stays open, in seconds.
    let windowSeconds: Int
    /// How long to wait before it opens, in seconds.
    let startSeconds: Int
    /// The SiteBlock password.
    let password: String
}

/// The form inside a blocked row for unblocking a site (or a part of a site) for a limited time. The person picks how long it stays open (nothing is picked at first), when it opens (the soonest the unblock delay allows, unless they choose later), and types the password. A gray line shows the clock times that follow from the two picks.
struct TemporaryUnblockForm: View {
    @ObservedObject var model: StatusModel
    /// The current unblock delay in seconds. It is the soonest the site can open.
    let delaySeconds: Int
    /// Sends the choice to the daemon; returns true when the daemon accepted it.
    let onSubmit: (TemporaryUnblockChoice) async -> Bool
    /// Called by the Cancel button.
    let onCancel: () -> Void

    /// The window picked in the menu, or nil while nothing has been picked.
    @State private var windowSeconds: Int?
    /// The start wait picked in the menu, or nil while the person has not touched it (meaning the soonest).
    @State private var pickedStart: Int?
    /// The password as typed.
    @State private var password = ""
    /// Whether the password field has the cursor; set after a refusal so the person can type again at once.
    @FocusState private var passwordFocused: Bool

    /// The start waits the menu offers: the delay itself, then each longer one from the fixed list.
    private var startOptions: [Int] { TemporaryUnblockOptions.startChoices(delaySeconds: delaySeconds) }

    /// The start wait in force: the one picked, or the soonest when none is picked or the picked one is no longer offered (the delay may have grown while the form was open).
    private var startSeconds: Int {
        guard let pickedStart, startOptions.contains(pickedStart) else { return delaySeconds }
        return pickedStart
    }

    /// True when the Schedule button may be pressed: a window is picked and a password is typed.
    private var canSubmit: Bool { windowSeconds != nil && !password.isEmpty && !model.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            pickerRow("How long?") {
                Picker("How long?", selection: $windowSeconds) {
                    Text("Choose…").tag(Int?.none)
                    ForEach(TemporaryUnblockOptions.windowChoices, id: \.self) { Text(TemporaryUnblockOptions.label(forSeconds: $0)).tag(Int?.some($0)) }
                }
            }
            pickerRow("Opens in") {
                Picker("Opens in", selection: Binding(get: { startSeconds }, set: { pickedStart = $0 })) {
                    ForEach(startOptions, id: \.self) { Text(startLabel($0)).tag($0) }
                }
            }
            scheduleLine
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($passwordFocused)
                .onSubmit(submit)
            HStack(spacing: 6) {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Schedule unblock", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .controlSize(.small)
    }

    /// One labelled menu: the label on the left and the menu on the right.
    private func pickerRow<Menu: View>(_ title: String, @ViewBuilder menu: () -> Menu) -> some View {
        HStack {
            Text(title)
            Spacer()
            menu()
                .labelsHidden()
                .fixedSize()
        }
    }

    /// The menu text for a start wait; the delay itself is marked as the soonest.
    private func startLabel(_ seconds: Int) -> String {
        let text = TemporaryUnblockOptions.label(forSeconds: seconds)
        return seconds == delaySeconds ? "\(text) (soonest)" : text
    }

    /// The gray line with the clock times, such as "Opens at 3:42 PM, blocks again at 4:42 PM." It is recomputed whenever either menu changes, and once a minute so it stays right while the form is open. Until a window is picked it gives only the opening time.
    private var scheduleLine: some View {
        TimelineView(.everyMinute) { context in
            Text(scheduleText(now: context.date))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The sentence for `scheduleLine`, worked out from `now`.
    private func scheduleText(now: Date) -> String {
        let opens = now.addingTimeInterval(TimeInterval(startSeconds))
        guard let windowSeconds else { return "Opens \(clockPhrase(opens, now: now))." }
        let closes = opens.addingTimeInterval(TimeInterval(windowSeconds))
        return "Opens \(clockPhrase(opens, now: now)), blocks again \(clockPhrase(closes, now: now))."
    }

    /// Words for a moment in time: "at 3:42 PM" for today, "tomorrow at 3:42 PM" for tomorrow, and the weekday and date after that ("Tue, Oct 21 at 3:42 PM").
    private func clockPhrase(_ date: Date, now: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow at \(time)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) at \(time)"
    }

    /// Sends the choice. The password field is emptied first, so the password is never left on screen whether the daemon accepts the request or not; after a refusal the form stays open with everything else kept, and the cursor goes to the password field.
    private func submit() {
        guard let windowSeconds, !password.isEmpty, !model.isBusy else { return }
        let choice = TemporaryUnblockChoice(windowSeconds: windowSeconds, startSeconds: startSeconds, password: password)
        password = ""
        Task {
            if await !onSubmit(choice) { passwordFocused = true }
        }
    }
}
