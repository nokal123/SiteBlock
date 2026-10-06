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

/// The main screen: title row, warning banners, the add field (or the first-run password form), the blocked list, and the footer.
private struct HomeView: View {
    @ObservedObject var model: StatusModel
    /// The latest status from the daemon.
    let snapshot: StatusSnapshot
    /// Opens the Settings screen.
    let openSettings: () -> Void

    /// The site name being typed.
    @State private var newSite = ""
    @FocusState private var addFocused: Bool

    /// The typed site name without surrounding spaces or line breaks (a pasted address often has them).
    private var trimmedSite: String { newSite.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(delaySeconds: snapshot.delaySeconds)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if BannersView.hasContent(snapshot: snapshot, feedback: model.feedback) { BannersView(model: model, snapshot: snapshot) }
                if snapshot.passwordSet { addSection } else { SetupView(model: model) }
                BlockedListView(model: model, snapshot: snapshot)
            }
            .padding(16)
            Divider()
            footer
        }
        .onAppear(perform: refocus)
        // Each time the panel opens, put the cursor back in the add field.
        .onChange(of: model.openCount) { _, _ in refocus() }
    }

    /// The text field and the Block button, with the daemon's answer underneath.
    private var addSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Site", text: $newSite, prompt: Text("Add a site (e.g. reddit.com)"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($addFocused)
                    .onSubmit(addSite)
                Button("Block", action: addSite)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedSite.isEmpty || model.isBusy)
            }
            FeedbackLine(model: model, scope: .add)
        }
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

    /// Asks the daemon to block the typed site. The field is emptied only when the daemon accepts it, so a typo can be fixed instead of retyped.
    private func addSite() {
        let site = trimmedSite
        guard !site.isEmpty, !model.isBusy else { return }
        Task {
            if await model.add(domain: site) { newSite = "" }
            addFocused = true
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

/// The screen shown when the daemon cannot be reached. It says what went wrong and gives the Terminal command that installs the service again.
private struct NotRunningView: View {
    @ObservedObject var model: StatusModel
    /// The sentence describing the problem, such as "The SiteBlock service isn't running."
    let message: String

    /// The command that installs and starts the service. It changes into the project folder first, so it works from any Terminal window.
    private static let reinstallCommand = "cd ~/Projects/SiteBlock && sudo scripts/install.sh"

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
                Text("While the service is stopped, nothing repairs the blocks or carries out unblocks. To start it again, run this in Terminal:")
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
