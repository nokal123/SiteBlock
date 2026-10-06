import AppKit
import SiteBlockCore
import SwiftUI

/// Shared look for the boxes that group content in the panel.
extension View {
    /// Draws the soft rounded box used behind rows, banners and settings sections. `tint` colors the box (for example orange for "waiting"); without it the box is a neutral gray that works in light and dark mode.
    func cardBackground(tint: Color? = nil) -> some View {
        let fill = tint?.opacity(0.12) ?? Color.primary.opacity(0.06)
        let edge = tint?.opacity(0.35) ?? Color.primary.opacity(0.08)
        return background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(edge, lineWidth: 1))
    }
}

/// A label whose countdown number ticks down every second on its own, so it keeps moving smoothly between status polls and keeps moving even if the daemon stops answering.
struct LiveCountdown: View {
    /// Seconds left as of the last daemon reply.
    let reported: Int
    /// When that reply arrived.
    let asOf: ContinuousClock.Instant
    /// Builds the sentence from the seconds left right now.
    let label: (Int) -> String

    var body: some View {
        // The schedule is anchored to a fixed date so the once-a-second rhythm is not restarted every time the panel redraws after a poll.
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 1)) { _ in
            // Digits are all the same width so the text does not jitter as the numbers change.
            Text(label(CountdownMath.remaining(reported: reported, asOf: asOf))).monospacedDigit()
        }
    }
}

/// One line of text with a small icon in front: red for an error, gray with a green check for a confirmation.
struct MessageLine: View {
    /// The sentence to show.
    let text: String
    /// True for an error.
    let isError: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.green)
            Text(text)
                .foregroundStyle(isError ? Color.red : Color.secondary)
                // Without this, long sentences are cut off to one line instead of wrapping.
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Shows the model's current message, but only when the message belongs to this part of the panel.
struct FeedbackLine: View {
    @ObservedObject var model: StatusModel
    /// The part of the panel this line sits in.
    let scope: FeedbackScope

    var body: some View {
        if let feedback = model.feedback, feedback.scope == scope {
            MessageLine(text: feedback.text, isError: feedback.isError)
                .transition(.opacity)
        }
    }
}

/// A titled box that groups related controls in the Settings screen.
struct SectionCard<Content: View>: View {
    /// The heading shown at the top of the box.
    let title: String
    /// The controls inside the box.
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// The title row at the top of the panel: the shield icon, the app name, and the current unblock delay when it is known.
struct PanelHeader: View {
    /// The current unblock delay, or nil when the daemon has not answered.
    let delaySeconds: Int?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("SiteBlock").font(.headline)
            Spacer(minLength: 8)
            if let delaySeconds {
                Label("Unblock delay: \(Formatting.duration(delaySeconds))", systemImage: "timer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("After you enter your password, a site stays blocked for \(Formatting.duration(delaySeconds)) before it opens.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Watches the window that hosts the panel and reports when it becomes visible or hidden.
/// A menu bar panel keeps its view alive while closed, so the usual appear and disappear callbacks are not a reliable signal; the window's own visibility is.
struct WindowVisibilityObserver: NSViewRepresentable {
    /// Called with true when the window is on screen and false when it is hidden.
    let onChange: (Bool) -> Void

    /// Creates the invisible view that does the watching.
    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onChange: onChange)
    }

    /// Keeps the callback current when SwiftUI rebuilds this wrapper.
    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    /// An empty AppKit view that listens for window visibility notifications once it is placed in a window.
    final class ObserverView: NSView {
        /// Called with the window's visibility.
        var onChange: (Bool) -> Void
        /// The notification subscriptions, kept so they can be removed.
        private var tokens: [NSObjectProtocol] = []

        /// Creates the view with the callback to use.
        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        /// Required by AppKit; this view is never created from a nib.
        required init?(coder: NSCoder) {
            fatalError("ObserverView is created in code only")
        }

        /// Removes the subscriptions when the view goes away.
        deinit {
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
        }

        /// Subscribes to the new window's visibility notifications and reports its current state.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens = []
            guard let window else {
                onChange(false)
                return
            }
            // Occlusion changes when the window is shown or hidden. Becoming key means the panel was just opened by a click on the icon.
            let center = NotificationCenter.default
            let reportNames: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification]
            tokens = reportNames.map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.report() }
            }
            // A menu bar panel closes the moment it stops being the key window (a click anywhere else). Treating that as "hidden" at once means typed passwords are discarded even if the window's own visibility flags lag behind.
            tokens.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.onChange(false) })
            report()
        }

        /// Tells the callback whether the window is currently showing.
        private func report() {
            let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
            onChange(visible)
        }
    }
}
