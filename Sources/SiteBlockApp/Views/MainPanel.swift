import AppKit
import SiteBlockCore
import SwiftUI

/// The whole panel that drops down from the menu bar icon. It is always 440 points wide, so long site names and countdowns fit on one line, watches whether its window is open, and starts every opening from a clean screen.
struct MainPanel: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        PanelRouter(model: model)
            // Changing the id when the panel closes makes SwiftUI discard the screen's state, which empties any password that was typed and closes forms and Settings.
            .id(model.closeCount)
            .frame(width: 440)
            .background(WindowVisibilityObserver { model.panelVisibilityChanged($0) })
    }
}

/// Picks which screen to show: connecting, the service is not running, Settings, or the home screen.
private struct PanelRouter: View {
    @ObservedObject var model: StatusModel
    /// Whether the Settings screen is showing instead of the home screen.
    @State private var showingSettings = false

    var body: some View {
        switch model.connection {
        case .connecting:
            ConnectingView()
        case .notRunning(let message):
            NotRunningView(model: model, message: message)
        case .connected:
            if let snapshot = model.snapshot {
                // Every setting needs a password, so Settings is only reachable once one exists. After a password reset clears it, the home screen takes over again.
                if showingSettings, snapshot.passwordSet {
                    SettingsView(model: model, snapshot: snapshot) { showingSettings = false }
                } else {
                    HomeView(model: model, snapshot: snapshot) { showingSettings = true }
                }
            } else {
                ConnectingView()
            }
        }
    }
}

/// Which inline password form is open on the home screen, if any.
private enum PasswordFormMode: Equatable {
    /// The form under the add field, opened by pressing Block before any password exists. The password is chosen at the first block, not at install or first launch.
    case firstBlock
    /// The form inside the "Choose a new password" banner, offered when a password reset has cleared the password while sites are still blocked.
    case newPassword
}

/// The main screen: title row, warning banners, the add field, the blocked list, and (once a password exists) the footer with the Settings button. It looks the same whether or not a password exists yet; when none does, pressing Block opens the "Choose a SiteBlock password" form under the add field first.
private struct HomeView: View {
    @ObservedObject var model: StatusModel
    /// The latest status from the daemon.
    let snapshot: StatusSnapshot
    /// Opens the Settings screen.
    let openSettings: () -> Void

    /// The site name being typed.
    @State private var newSite = ""
    @FocusState private var addFocused: Bool
    /// The password form that is open right now, or nil when none is.
    @State private var passwordForm: PasswordFormMode?
    /// Which of the two choices under the field is selected while the typed text has a path: true for "Only this part" (a path rule), false for "Whole site".
    @State private var onlyThisPart = true

    /// The typed site name without surrounding spaces or line breaks (a pasted address often has them).
    private var trimmedSite: String { newSite.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True when the typed text has a path after the site name (youtube.com/shorts), which is when the choice between a part of the site and the whole site is offered.
    private var hasPath: Bool { PathRuleParser.split(trimmedSite).path != nil }

    /// True when pressing Block will add a path rule instead of blocking the whole site.
    private var blocksOnlyThisPart: Bool { hasPath && onlyThisPart }

    /// The rule that "Only this part" would add, written the way the list shows it (youtube.com/shorts), or nil when the text cannot be read as a rule. Used only for the caption under the choice; the daemon checks the text again when Block is pressed.
    private var ruleCaption: String? {
        guard let rule = try? PathRuleParser.parse(trimmedSite) else { return nil }
        return PathRuleParser.display(domain: rule.domain, path: rule.path)
    }

    /// True while the first-block password form is showing. It also needs "no password yet": if one was set in the meantime (for example from Terminal) the form has nothing left to do, so it goes away and Block works normally.
    private var isChoosingFirstPassword: Bool { passwordForm == .firstBlock && !snapshot.passwordSet }

    /// True when a password reset left sites blocked but no password to unblock them with, so the banner offering a new password should show.
    private var needsNewPassword: Bool { !snapshot.passwordSet && (!snapshot.blocked.isEmpty || !(snapshot.blockedPaths ?? []).isEmpty) }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(delaySeconds: snapshot.delaySeconds)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if BannersView.hasContent(snapshot: snapshot, feedback: model.feedback) { BannersView(model: model, snapshot: snapshot) }
                if needsNewPassword {
                    NoPasswordBanner(model: model, isChoosing: passwordForm == .newPassword, choose: { passwordForm = .newPassword }, cancel: { passwordForm = nil })
                }
                addSection
                BlockedListView(model: model, snapshot: snapshot)
            }
            .padding(16)
            // The footer only holds the Settings button, which needs a password, so without one there is no footer row (and no divider above it).
            if snapshot.passwordSet {
                Divider()
                footer
            }
        }
        .onAppear(perform: refocus)
        // Each time the panel opens, put the cursor back in the add field.
        .onChange(of: model.openCount) { _, _ in refocus() }
        // Once a password exists, no password form has anything left to do, so the one that was open is closed.
        .onChange(of: snapshot.passwordSet) { _, isSet in if isSet { passwordForm = nil } }
    }

    /// The text field and the Block button, with the daemon's answer underneath. While the first-block password form is open, the field and button are switched off so the site that will be blocked cannot change, and the form sits underneath.
    private var addSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // One line above the field, so people know a part of a site can be typed as well as a whole site.
            Text("Block a whole site (youtube.com) or just part of one (youtube.com/shorts).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Site", text: $newSite, prompt: Text("Add a site (e.g. reddit.com)"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($addFocused)
                    .onSubmit(addSite)
                    .disabled(isChoosingFirstPassword)
                Button("Block", action: addSite)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedSite.isEmpty || model.isBusy || isChoosingFirstPassword)
            }
            // A typed path (youtube.com/shorts) offers the part or the whole site; "Only this part" is selected first.
            if hasPath { partOrWholeChoice }
            FeedbackLine(model: model, scope: .add)
            if isChoosingFirstPassword { firstBlockForm }
        }
        // Each time a path appears in the field, the narrow choice is selected again; the person can then widen it. This sits on the section, which is always on screen, because the choice itself exists only while the text has a path and so cannot watch for the path to appear.
        .onChange(of: hasPath) { _, nowHasPath in if nowHasPath { onlyThisPart = true } }
    }

    /// The two-choice control that appears under the field when the text has a path, and a caption that says what the selected choice will block. It is switched off with the field while the first-block password form is open.
    private var partOrWholeChoice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("What to block", selection: $onlyThisPart) {
                Text("Only this part").tag(true)
                Text("Whole site").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isChoosingFirstPassword)
            if onlyThisPart, let rule = ruleCaption {
                Text("Blocks \(rule) and everything under it. The rest of the site stays open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !onlyThisPart {
                Text("Blocks the whole site, not just the part after its name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The "Choose a SiteBlock password" form for the first block, in a gray box. It names the site that will be blocked once the password is set; Cancel closes it and leaves the typed site in the field.
    private var firstBlockForm: some View {
        SetupView(
            model: model,
            detail: "\(trimmedSite) will be blocked as soon as the password is set.",
            submitTitle: "Set password and block",
            onSubmit: setPasswordAndBlock,
            onCancel: {
                passwordForm = nil
                refocus()
            }
        )
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    /// The bottom row: the Settings button on the left. There is no Quit button, because the app always stays in the menu bar (03 § 8, § 10).
    private var footer: some View {
        HStack {
            Button(action: openSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Puts the cursor in the add field. The flag is switched off and on because setting a focus flag that is already true does nothing, and the panel's window may have taken focus away since it was last set.
    private func refocus() {
        Task {
            addFocused = false
            await Task.yield()
            addFocused = true
        }
    }

    /// Asks the daemon to block the typed site, or only the typed part of it when the text has a path and "Only this part" is selected. The field is emptied only when the daemon accepts it, so a typo can be fixed instead of retyped. When no password exists yet, nothing is sent: the password form opens instead, with the typed site kept, because the daemon refuses to block until a password is set.
    private func addSite() {
        let site = trimmedSite
        guard !site.isEmpty, !model.isBusy, !isChoosingFirstPassword else { return }
        guard snapshot.passwordSet else {
            passwordForm = .firstBlock
            return
        }
        Task {
            let accepted = blocksOnlyThisPart ? await model.addPath(rule: site) : await model.add(domain: site)
            if accepted { newSite = "" }
            addFocused = true
        }
    }

    /// Sets the chosen password and then blocks the typed site; the site is sent only if the daemon accepted the password. Returns true when the password was set, so the form can go away; if the site itself was then refused, its reason shows under the add field and the site stays typed so it can be fixed. Returns false when the password was refused, so the form stays open with the reason inside it.
    private func setPasswordAndBlock(_ password: String) async -> Bool {
        switch await model.setupThenAdd(password: password, domain: trimmedSite, onlyThisPart: blocksOnlyThisPart) {
        case .passwordNotSet:
            return false
        case .passwordSetSiteRefused:
            passwordForm = nil
            addFocused = true
            return true
        case .blocked:
            newSite = ""
            passwordForm = nil
            addFocused = true
            return true
        }
    }
}

/// The screen shown until the first answer arrives from the daemon.
private struct ConnectingView: View {
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(delaySeconds: nil)
            Divider()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting to SiteBlock…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }
}

/// The screen shown when the daemon cannot be reached. It says what went wrong, tells the user to double-click the installer in the project folder, and offers the Terminal command that does the same thing.
private struct NotRunningView: View {
    @ObservedObject var model: StatusModel
    /// The sentence describing the problem, such as "The SiteBlock service isn't running."
    let message: String

    /// The command that installs and starts the service. It is a path inside the project folder, so it only works from a Terminal window that is already in that folder; the screen says so next to it.
    private static let reinstallCommand = "sudo scripts/install.sh"

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(delaySeconds: nil)
            Divider()
            VStack(spacing: 12) {
                Image(systemName: "shield.slash")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("While the service is stopped, nothing repairs the blocks or carries out unblocks. To start it again:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Open the SiteBlock project folder and double-click Install SiteBlock.command.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Or run this in Terminal, from the project folder:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                commandBox
            }
            .padding(16)
            Divider()
            HStack {
                Button("Try again") { Task { await model.refresh() } }
                Spacer()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    /// The command in a box, with a button that copies it to the clipboard.
    private var commandBox: some View {
        HStack {
            Text(Self.reinstallCommand)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.reinstallCommand, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy the command")
            .accessibilityLabel("Copy the command")
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .cardBackground()
    }
}
