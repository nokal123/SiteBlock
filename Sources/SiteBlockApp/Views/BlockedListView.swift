import SiteBlockCore
import SwiftUI

/// The list of blocked sites and blocked parts of sites, or a short message when there are none. A long list scrolls instead of making the panel taller.
struct BlockedListView: View {
    @ObservedObject var model: StatusModel
    /// The latest status from the daemon.
    let snapshot: StatusSnapshot

    /// How many rows the list box shows at once; more rows scroll inside it.
    private static let visibleRows: CGFloat = 4
    /// The gap between two rows, in points.
    private static let rowSpacing: CGFloat = 8
    /// The height of one closed row, measured from the rows on screen. The box is sized from it so exactly four rows fit, whatever the system text size. It starts at a typical row height until the first measurement arrives.
    @State private var rowHeight: CGFloat = 56

    /// The list box's fixed height: four closed rows and the three gaps between them. It never changes with the number of rows, so the panel keeps its size; a scroll view in a menu bar panel also needs an explicit height, or it shrinks to a thin strip.
    private var listHeight: CGFloat { rowHeight * Self.visibleRows + Self.rowSpacing * (Self.visibleRows - 1) }

    /// The blocked parts of sites, or an empty list when the daemon sent none.
    private var rules: [BlockedPathStatus] { snapshot.blockedPaths ?? [] }

    var body: some View {
        if snapshot.blocked.isEmpty && rules.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // The heading above the box names the first group, so the panel is the same height whichever groups exist.
                groupHeading(snapshot.blocked.isEmpty ? "Blocked parts of sites" : "Blocked sites", count: snapshot.blocked.isEmpty ? rules.count : snapshot.blocked.count)
                // Both groups share this one scroll box, so its height stays the same however many sites and rules there are.
                ScrollView {
                    VStack(alignment: .leading, spacing: Self.rowSpacing) {
                        // With no sites, the blocked parts are the first group, and its heading is the one above the box, so only its note is left to show here.
                        if snapshot.blocked.isEmpty { limitsNote }
                        ForEach(snapshot.blocked, id: \.domain) { site in
                            BlockedRow(model: model, item: siteItem(site), delaySeconds: snapshot.delaySeconds, canUnblock: snapshot.passwordSet)
                        }
                        // With sites above them, the blocked parts get their own heading and note inside the box.
                        if !snapshot.blocked.isEmpty && !rules.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                groupHeading("Blocked parts of sites", count: rules.count)
                                limitsNote
                            }
                            .padding(.top, 6)
                        }
                        ForEach(rules, id: \.rule) { rule in
                            BlockedRow(model: model, item: ruleItem(rule), delaySeconds: snapshot.delaySeconds, canUnblock: snapshot.passwordSet)
                        }
                    }
                }
                .frame(height: listHeight)
                .onPreferenceChange(ClosedRowHeightKey.self) { measured in if measured > 0, measured < .infinity { rowHeight = measured } }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    /// A group's title with the number of entries next to it.
    private func groupHeading(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text("\(count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The one line under the "Blocked parts of sites" heading that says which browsers can enforce a part of a site.
    private var limitsNote: some View {
        Text("Works in Chrome, Firefox, Edge and Brave. Safari can only block whole sites.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What a row needs to show and control one blocked site.
    private func siteItem(_ site: BlockedSiteStatus) -> BlockedRow.Item {
        BlockedRow.Item(
            title: site.domain,
            pendingSeconds: site.unblockSecondsRemaining,
            scope: .site(site.domain),
            detail: .hosts(site.hosts),
            unblock: { password in await model.unblock(domain: site.domain, password: password) },
            keepBlocked: { await model.cancelUnblock(domain: site.domain) }
        )
    }

    /// What a row needs to show and control one blocked part of a site. The rule text (for example youtube.com/shorts) is what goes back to the daemon.
    private func ruleItem(_ rule: BlockedPathStatus) -> BlockedRow.Item {
        BlockedRow.Item(
            title: rule.rule,
            pendingSeconds: rule.unblockSecondsRemaining,
            scope: .rule(rule.rule),
            detail: .rule(domain: rule.domain, path: rule.path),
            unblock: { password in await model.unblockPath(rule: rule.rule, password: password) },
            keepBlocked: { await model.cancelUnblockPath(rule: rule.rule) }
        )
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

/// Carries the height of the shortest row up to the list, which is the height of a closed row.
private struct ClosedRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    /// Keeps the smallest height reported in one layout pass.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

/// One blocked site or one blocked part of a site. It shows the name and either an "Unblock…" button or, once an unblock has been approved, a live countdown that says plainly it is still blocked. A disclosure underneath shows what is blocked: the host names written to the hosts file for a site, or the sentence that explains a path rule.
struct BlockedRow: View {
    /// What the row shows below its name when the disclosure is open.
    enum Detail {
        /// Every host name SiteBlock writes to the hosts file for a site.
        case hosts([String])
        /// The domain and path of a path rule.
        case rule(domain: String, path: String)
    }

    /// Everything a row needs to know about the site or rule it shows, and the two things it can ask the daemon to do.
    struct Item {
        /// The name shown in the row: the domain, or the rule such as youtube.com/shorts.
        let title: String
        /// Seconds until the unblock finishes, or nil when no unblock is pending.
        let pendingSeconds: Int?
        /// Where this row's messages appear.
        let scope: FeedbackScope
        /// What the disclosure shows.
        let detail: Detail
        /// Starts the unblock countdown with the typed password; returns true when the daemon accepted it.
        let unblock: (String) async -> Bool
        /// Cancels a pending unblock; returns true when the daemon accepted it.
        let keepBlocked: () async -> Bool
    }

    @ObservedObject var model: StatusModel
    /// The site or rule to show.
    let item: Item
    /// The current unblock delay, used to tell the user how long the wait will be.
    let delaySeconds: Int
    /// False while no password exists (after a password reset, before a new one is chosen), because the daemon would refuse an unblock anyway.
    let canUnblock: Bool

    /// Whether the details are open.
    @State private var showDetail = false
    /// Whether the password form for starting an unblock is open.
    @State private var enteringPassword = false
    /// The password as typed.
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    /// Seconds until this row unblocks, or nil when no unblock is pending.
    private var pendingSeconds: Int? { item.pendingSeconds }

    /// True when the row shows only its title line and the closed detail line, with no countdown, no unblock form and no message, which is the row height the list box is sized from.
    private var isPlainClosed: Bool { !showDetail && !enteringPassword && pendingSeconds == nil && model.feedback?.scope != item.scope }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleLine
            if let pendingSeconds { stillBlockedLine(pendingSeconds) }
            if enteringPassword, pendingSeconds == nil { unblockForm }
            FeedbackLine(model: model, scope: item.scope)
            detailDisclosure
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Only a plain closed row reports its height, because an open host list, an unblock form or a pending countdown makes a row taller, and the list sizes its box from closed rows.
        .background(GeometryReader { proxy in Color.clear.preference(key: ClosedRowHeightKey.self, value: isPlainClosed ? proxy.size.height : .infinity) })
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
            Text(item.title)
                .font(.system(.body, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.title)
            Spacer(minLength: 8)
            if pendingSeconds != nil {
                // The safe choice is the prominent one: it keeps the site blocked and needs no password.
                Button("Keep blocked") { Task { _ = await item.keepBlocked() } }
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
            Text("Enter your password to start the countdown. It stays blocked for \(Formatting.duration(delaySeconds)) first, and you can cancel any time before then.")
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

    /// The text on the disclosure toggle: the number of hosts for a site, or a fixed label for a path rule.
    private var detailLabel: String {
        switch item.detail {
        case .hosts(let hosts): return "\(hosts.count) \(hosts.count == 1 ? "host" : "hosts")"
        case .rule: return "What this blocks"
        }
    }

    /// The tooltip on the disclosure toggle.
    private var detailHelp: String {
        switch item.detail {
        case .hosts: return "Every name SiteBlock writes to the hosts file for this site"
        case .rule: return "Which addresses this rule blocks"
        }
    }

    /// The "24 hosts" toggle (or "What this blocks" for a path rule) and, when open, the host names in two columns or the sentence that explains the rule.
    private var detailDisclosure: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showDetail.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(showDetail ? 90 : 0))
                        .frame(width: 10)
                    Text(detailLabel)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(detailHelp)
            .accessibilityLabel(showDetail ? "Hide details" : "Show details")

            if showDetail {
                switch item.detail {
                case .hosts(let hosts):
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 2) {
                        ForEach(hosts, id: \.self) { host in
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
                case .rule(let domain, let path):
                    Text("Blocks every address on \(domain) and its subdomains whose path starts with \(path). The rest of the site stays open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 14)
                }
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
            if await item.unblock(typed) {
                enteringPassword = false
            } else {
                // The form stays open after a refusal (for example a wrong password) so the user can try again.
                passwordFocused = true
            }
        }
    }
}
