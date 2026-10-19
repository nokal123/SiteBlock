import AppKit
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

/// The notice shown when a password reset has cleared the password while sites are still blocked. The sites stay blocked, but none can be unblocked until a new password exists. A button opens the same two-field "Choose a SiteBlock password" form that the first block uses.
struct NoPasswordBanner: View {
    @ObservedObject var model: StatusModel
    /// Whether the password form is open in place of the button.
    let isChoosing: Bool
    /// Opens the password form.
    let choose: () -> Void
    /// Closes the password form without setting a password.
    let cancel: () -> Void

    var body: some View {
        BannerCard(icon: "key.fill", tint: .orange) {
            Text("SiteBlock has no password right now, so no site can be unblocked. Your blocked sites stay blocked.")
            if isChoosing {
                SetupView(model: model, detail: nil, submitTitle: "Set password", onSubmit: { await model.setup(password: $0) }, onCancel: cancel)
            } else {
                Button("Choose a new password", action: choose)
                    .controlSize(.small)
                    .disabled(model.isBusy)
            }
        }
    }
}

/// The warnings for anything that is waiting or wrong: a hosts file problem, a password lockout, a pending delay change, a pending uninstall, a running password reset, and a browser that has not allowed SiteBlock to control it. Each waiting item shows a live countdown and, where cancelling is allowed, a button that cancels it.
struct BannersView: View {
    @ObservedObject var model: StatusModel
    /// The latest status from the daemon.
    let snapshot: StatusSnapshot

    /// The page of System Settings where a person turns on SiteBlock's permission to control a browser.
    private static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")

    /// True when at least one banner or banner message would show. Parents use it to leave this view out entirely, because an empty stack would still add a gap.
    static func hasContent(snapshot: StatusSnapshot, feedback: Feedback?, deniedBrowserNames: [String], updateVisible: Bool) -> Bool {
        updateVisible || !snapshot.hostsFileHealthy || snapshot.lockoutSecondsRemaining != nil || snapshot.pendingDelay != nil || snapshot.uninstallSecondsRemaining != nil || snapshot.recoverySecondsRemaining != nil || feedback?.scope == .banner || needsBrowserPermission(snapshot: snapshot, deniedBrowserNames: deniedBrowserNames)
    }

    /// True when the permission banner should show: at least one path rule exists (otherwise the tab watcher has nothing to do and the permission does not matter) and at least one running browser has refused control.
    private static func needsBrowserPermission(snapshot: StatusSnapshot, deniedBrowserNames: [String]) -> Bool {
        !deniedBrowserNames.isEmpty && !(snapshot.blockedPaths ?? []).isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            if !snapshot.hostsFileHealthy { hostsWarning }
            if let seconds = snapshot.lockoutSecondsRemaining { lockout(seconds) }
            if let change = snapshot.pendingDelay { delayChange(change) }
            if let seconds = snapshot.uninstallSecondsRemaining { uninstall(seconds) }
            if let seconds = snapshot.recoverySecondsRemaining { recovery(seconds) }
            if Self.needsBrowserPermission(snapshot: snapshot, deniedBrowserNames: model.deniedBrowserNames) { browserPermission(model.deniedBrowserNames) }
            if model.updater.showsBanner, let info = model.updater.available { updateBanner(info) }
            FeedbackLine(model: model, scope: .banner)
        }
    }

    /// Says a newer version is available, with "Update" and "Not now". While an update runs, the current step replaces the buttons; after a failure or a cancelled password prompt, the sentence shows above the buttons again.
    private func updateBanner(_ info: UpdateInfo) -> some View {
        let updater = model.updater
        return BannerCard(icon: "arrow.down.circle.fill", tint: .blue) {
            Text("SiteBlock \(info.version) is available.")
            if let step = Self.stepText(updater.phase) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(step).foregroundStyle(.secondary)
                }
            } else {
                if case .failed(let text) = updater.phase { MessageLine(text: text, isError: true) }
                if let notice = updater.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Update") { updater.install() }
                        .buttonStyle(.borderedProminent)
                    Button("Not now") { updater.dismiss() }
                }
                .controlSize(.small)
            }
        }
    }

    /// The words for each step of a running update, or nil when no update step is running.
    private static func stepText(_ phase: Updater.Phase) -> String? {
        switch phase {
        case .downloading: return "Downloading…"
        case .verifying: return "Checking the download…"
        case .waitingForPassword: return "Waiting for your password…"
        case .installing: return "Installing…"
        case .idle, .checking, .failed, .upToDate: return nil
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

    /// Asks the person to let SiteBlock control the named browsers. Without that permission SiteBlock cannot see which address a tab is on, so a blocked part of a site that opens without a page load stays open until the next reload. A button opens the Automation page of System Settings, where the permission is switched on.
    private func browserPermission(_ names: [String]) -> some View {
        BannerCard(icon: "hand.raised.fill", tint: .orange) {
            // ListFormatter writes "Google Chrome", "Brave and Google Chrome" or "Brave, Google Chrome, and Microsoft Edge".
            Text("Let SiteBlock control \(ListFormatter.localizedString(byJoining: names)) so blocked parts of sites close right away.")
            Button("Open Settings") {
                if let url = Self.automationSettingsURL { NSWorkspace.shared.open(url) }
            }
            .controlSize(.small)
        }
    }
}
