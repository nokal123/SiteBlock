import SiteBlockCore
import SwiftUI

/// The list of blocked sites, or a short message when there are none. A long list scrolls instead of making the panel taller.
struct BlockedListView: View {
    @ObservedObject var model: StatusModel
    /// The latest status from the daemon.
    let snapshot: StatusSnapshot

    /// The tallest the list may grow before it scrolls, in points. About nine ordinary rows fit.
    private static let maxListHeight: CGFloat = 480

    /// The measured height of all rows together. The scroll view uses it as its own height, because a SwiftUI scroll view inside a menu bar panel does not grow to fit its contents on its own and would otherwise shrink to a thin strip.
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        if snapshot.blocked.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Blocked sites").font(.subheadline.weight(.semibold))
                    Text("\(snapshot.blocked.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(snapshot.blocked, id: \.domain) { site in
                            BlockedRow(model: model, site: site, delaySeconds: snapshot.delaySeconds, canUnblock: snapshot.passwordSet)
                        }
                    }
                    // Reports the rows' real height, which changes as rows open their host list or unblock form.
                    .background(GeometryReader { proxy in Color.clear.preference(key: RowsHeightKey.self, value: proxy.size.height) })
                }
                // The list is exactly as tall as its rows, up to the cap; only a longer list scrolls. The 60-point floor keeps one row readable before the first measurement arrives.
                .frame(height: min(max(rowsHeight, 60), Self.maxListHeight))
                .onPreferenceChange(RowsHeightKey.self) { rowsHeight = $0 }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    /// The message shown before anything is blocked.
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "shield")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No sites blocked yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

/// Carries the measured height of the blocked-site rows up to the list, so the scroll view can size itself to them.
private struct RowsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    /// Keeps the largest height reported in one layout pass.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One blocked site. It shows the site name and either an "Unblock…" button or, once an unblock has been approved, a live countdown that says plainly the site is still blocked. A disclosure lists every host name SiteBlock writes for the site.
struct BlockedRow: View {
    @ObservedObject var model: StatusModel
    /// The site to show.
    let site: BlockedSiteStatus
    /// The current unblock delay, used to tell the user how long the wait will be.
    let delaySeconds: Int
    /// False while no password exists (after a password reset, before a new one is chosen), because the daemon would refuse an unblock anyway.
    let canUnblock: Bool

    /// Whether the list of host names is open.
    @State private var showHosts = false
    /// Whether the password form for starting an unblock is open.
    @State private var enteringPassword = false
    /// The password as typed.
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    /// Seconds until this site unblocks, or nil when no unblock is pending.
    private var pendingSeconds: Int? { site.unblockSecondsRemaining }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleLine
            if let pendingSeconds { stillBlockedLine(pendingSeconds) }
            if enteringPassword, pendingSeconds == nil { unblockForm }
            FeedbackLine(model: model, scope: .site(site.domain))
            hostsDisclosure
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A waiting unblock gets an orange box so it stands out from ordinary rows at a glance.
        .cardBackground(tint: pendingSeconds == nil ? nil : .orange)
        .onChange(of: enteringPassword) { _, entering in if entering { passwordFocused = true } }
    }

    /// The lock icon, the site name, and the button that fits the row's state.
    private var titleLine: some View {
        HStack(spacing: 8) {
            Image(systemName: pendingSeconds == nil ? "lock.fill" : "lock.badge.clock.fill")
                .foregroundStyle(pendingSeconds == nil ? Color.secondary : Color.orange)
                .frame(width: 18)
            Text(site.domain)
                .font(.system(.body, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(site.domain)
            Spacer(minLength: 8)
            if pendingSeconds != nil {
                // The safe choice is the prominent one: it keeps the site blocked and needs no password.
                Button("Keep blocked") { Task { _ = await model.cancelUnblock(domain: site.domain) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.isBusy)
            } else if canUnblock, !enteringPassword {
                Button("Unblock…") { enteringPassword = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    /// The line under the name for a pending unblock. It starts with "Still blocked" so nobody mistakes a waiting site for an open one.
    private func stillBlockedLine(_ seconds: Int) -> some View {
        HStack(spacing: 4) {
            Text("Still blocked").fontWeight(.semibold)
            LiveCountdown(reported: seconds, asOf: model.snapshotInstant) { left in
                left > 0 ? "· unblocks in \(Formatting.clock(left))" : "· unblocking now…"
            }
        }
        .font(.callout)
    }

    /// The password form: an explanation of what happens next, the password field, and the two buttons.
    private var unblockForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter your password to start the countdown. The site stays blocked for \(Formatting.duration(delaySeconds)) first, and you can cancel any time before then.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($passwordFocused)
                    .onSubmit(startCountdown)
                Button("Cancel", action: closeForm)
                Button("Start countdown", action: startCountdown)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || model.isBusy)
            }
            .controlSize(.small)
        }
    }

    /// The "24 hosts" toggle and, when open, the host names in two columns.
    private var hostsDisclosure: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showHosts.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(showHosts ? 90 : 0))
                        .frame(width: 10)
                    Text("\(site.hosts.count) \(site.hosts.count == 1 ? "host" : "hosts")")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Every name SiteBlock writes to the hosts file for this site")
            .accessibilityLabel(showHosts ? "Hide hosts" : "Show hosts")

            if showHosts {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 2) {
                    ForEach(site.hosts, id: \.self) { host in
                        Text(host)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(host)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    /// Closes the password form and forgets whatever was typed.
    private func closeForm() {
        password = ""
        enteringPassword = false
    }

    /// Sends the typed password to start the countdown. The field is emptied first, so the password is never left on screen whether the daemon accepts it or not.
    private func startCountdown() {
        guard !password.isEmpty, !model.isBusy else { return }
        let typed = password
        password = ""
        Task {
            if await model.unblock(domain: site.domain, password: typed) {
                enteringPassword = false
            } else {
                // The form stays open after a refusal (for example a wrong password) so the user can try again.
                passwordFocused = true
            }
        }
    }
}
