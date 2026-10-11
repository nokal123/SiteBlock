import AppKit
import SiteBlockCore
import SwiftUI

/// The whole panel that drops down from the menu bar icon. It is always 360 points wide, watches whether its window is open, and starts every opening from a clean screen.
struct MainPanel: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        PanelRouter(model: model)
            // Changing the id when the panel closes makes SwiftUI discard the screen's state, which empties any password that was typed and closes forms and Settings.
            .id(model.closeCount)
            .frame(width: 360)
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

/// The main screen: title row, warning banners, the add field, the blocked list, and the footer. It looks the same whether or not a password exists yet; when none does, pressing Block opens the "Choose a SiteBlock password" form under the add field first.
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

    /// The typed site name without surrounding spaces or line breaks (a pasted address often has them).
    private var trimmedSite: String { newSite.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True while the first-block password form is showing. It also needs "no password yet": if one was set in the meantime (for example from Terminal) the form has nothing left to do, so it goes away and Block works normally.
    private var isChoosingFirstPassword: Bool { passwordForm == .firstBlock && !snapshot.passwordSet }

    /// True when a password reset left sites blocked but no password to unblock them with, so the banner offering a new password should show.
    private var needsNewPassword: Bool { !snapshot.passwordSet && !snapshot.blocked.isEmpty }

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
            Divider()
            footer
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
            FeedbackLine(model: model, scope: .add)
            if isChoosingFirstPassword { firstBlockForm }
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

    /// The bottom row: Settings on the left and Quit on the right.
    private var footer: some View {
        HStack {
            if snapshot.passwordSet {
                Button(action: openSettings) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .help("Quits this menu bar app. Blocking keeps running.")
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

    /// Asks the daemon to block the typed site. The field is emptied only when the daemon accepts it, so a typo can be fixed instead of retyped. When no password exists yet, nothing is sent: the password form opens instead, with the typed site kept, because the daemon refuses to block until a password is set.
    private func addSite() {
        let site = trimmedSite
        guard !site.isEmpty, !model.isBusy, !isChoosingFirstPassword else { return }
        guard snapshot.passwordSet else {
            passwordForm = .firstBlock
            return
        }
        Task {
            if await model.add(domain: site) { newSite = "" }
            addFocused = true
        }
    }

    /// Sets the chosen password and then blocks the typed site; the site is sent only if the daemon accepted the password. Returns true when the password was set, so the form can go away; if the site itself was then refused, its reason shows under the add field and the site stays typed so it can be fixed. Returns false when the password was refused, so the form stays open with the reason inside it.
    private func setPasswordAndBlock(_ password: String) async -> Bool {
        switch await model.setupThenAdd(password: password, domain: trimmedSite) {
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
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
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
