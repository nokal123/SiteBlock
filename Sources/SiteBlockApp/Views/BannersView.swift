import SiteBlockCore
import SwiftUI

/// One colored box at the top of the panel: an icon, a message, and an optional button underneath.
private struct BannerCard<Content: View>: View {
    /// The SF Symbol shown at the left.
    let icon: String
    /// The color of the box and the icon.
    let tint: Color
    /// The message and any button.
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .cardBackground(tint: tint)
    }
}

/// The warnings for anything that is waiting or wrong: a hosts file problem, a password lockout, a pending delay change, a pending uninstall and a running password reset. Each waiting item shows a live countdown and, where cancelling is allowed, a button that cancels it.
struct BannersView: View {
    @ObservedObject var model: StatusModel
    /// The latest status from the daemon.
    let snapshot: StatusSnapshot

    /// True when at least one banner or banner message would show. Parents use it to leave this view out entirely, because an empty stack would still add a gap.
    static func hasContent(snapshot: StatusSnapshot, feedback: Feedback?) -> Bool {
        !snapshot.hostsFileHealthy || snapshot.lockoutSecondsRemaining != nil || snapshot.pendingDelay != nil || snapshot.uninstallSecondsRemaining != nil || snapshot.recoverySecondsRemaining != nil || feedback?.scope == .banner
    }

    var body: some View {
        VStack(spacing: 8) {
            if !snapshot.hostsFileHealthy { hostsWarning }
            if let seconds = snapshot.lockoutSecondsRemaining { lockout(seconds) }
            if let change = snapshot.pendingDelay { delayChange(change) }
            if let seconds = snapshot.uninstallSecondsRemaining { uninstall(seconds) }
            if let seconds = snapshot.recoverySecondsRemaining { recovery(seconds) }
            FeedbackLine(model: model, scope: .banner)
        }
    }

    /// Warns that the last check of the hosts file found it wrong and could not fix it, which means some sites may not actually be blocked.
    private var hostsWarning: some View {
        BannerCard(icon: "exclamationmark.triangle.fill", tint: .red) {
            Text("SiteBlock could not confirm that the hosts file is correct. Some sites may not be blocked right now.")
        }
    }

    /// Says password checks are paused after too many wrong passwords, and for how much longer.
    private func lockout(_ seconds: Int) -> some View {
        BannerCard(icon: "lock.trianglebadge.exclamationmark.fill", tint: .orange) {
            LiveCountdown(reported: seconds, asOf: model.snapshotInstant) { left in
                "Too many wrong passwords. Password checks resume in \(Formatting.clock(left))."
            }
        }
    }

    /// Says a shorter unblock delay has been requested and when it will take effect, with a button to drop the request.
    private func delayChange(_ change: PendingDelayStatus) -> some View {
        BannerCard(icon: "timer", tint: .orange) {
            LiveCountdown(reported: change.secondsRemaining, asOf: model.snapshotInstant) { left in
                "The unblock delay changes to \(Formatting.duration(change.newDelaySeconds)) in \(Formatting.clock(left))."
            }
            Button("Keep current delay") { Task { _ = await model.cancelDelayChange() } }
                .controlSize(.small)
                .disabled(model.isBusy)
        }
    }

    /// Says an uninstall is scheduled and when it will happen, with a button to cancel it.
    private func uninstall(_ seconds: Int) -> some View {
        BannerCard(icon: "trash.fill", tint: .red) {
            LiveCountdown(reported: seconds, asOf: model.snapshotInstant) { left in
                "SiteBlock will uninstall in \(Formatting.clock(left))."
            }
            Button("Cancel uninstall") { Task { _ = await model.cancelUninstall() } }
                .controlSize(.small)
                .disabled(model.isBusy)
        }
    }

    /// Says a forgotten-password reset is running and when the password will be cleared, with a button to cancel it. Blocked sites stay blocked either way.
    private func recovery(_ seconds: Int) -> some View {
        BannerCard(icon: "key.fill", tint: .orange) {
            LiveCountdown(reported: seconds, asOf: model.snapshotInstant) { left in
                "A password reset is running. The password will be cleared in \(Formatting.clock(left)). Blocked sites stay blocked."
            }
            Button("Cancel reset") { Task { _ = await model.cancelRecovery() } }
                .controlSize(.small)
                .disabled(model.isBusy)
        }
    }
}
