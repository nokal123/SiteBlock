import SiteBlockCore
import SwiftUI

/// The first-run form that asks for a SiteBlock password twice. Nothing can be blocked or unblocked until one exists.
struct SetupView: View {
    @ObservedObject var model: StatusModel
    /// The password as typed in the first field.
    @State private var password = ""
    /// The password as typed in the second field.
    @State private var confirmation = ""
    /// A problem found on this screen without asking the daemon (the two fields differ).
    @State private var localProblem: String?
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a SiteBlock password").font(.headline)
            Text("You will need it to unblock a site, shorten the delay or uninstall. It is separate from your Mac login password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                SecureField("New password", text: $password)
                    .focused($passwordFocused)
                SecureField("Confirm password", text: $confirmation)
                    .onSubmit(submit)
            }
            .textFieldStyle(.roundedBorder)

            Text("At least \(PasswordHasher.minimumLength) characters.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("SiteBlock cannot show this password again. If you forget it, the only way back is a reset started from Terminal with your Mac administrator password, followed by a 48 hour wait.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)

            if let localProblem { MessageLine(text: localProblem, isError: true) }
            FeedbackLine(model: model, scope: .setup)

            HStack {
                Spacer()
                Button("Set password", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || confirmation.isEmpty || model.isBusy)
            }
        }
        .onAppear(perform: refocus)
        // Each time the panel opens, put the cursor back in the first field.
        .onChange(of: model.openCount) { _, _ in refocus() }
        // Typing again after a mismatch removes the old complaint.
        .onChange(of: password) { _, _ in localProblem = nil }
        .onChange(of: confirmation) { _, _ in localProblem = nil }
    }

    /// Puts the cursor in the first field. The flag is switched off and on because setting a focus flag that is already true does nothing.
    private func refocus() {
        Task {
            passwordFocused = false
            await Task.yield()
            passwordFocused = true
        }
    }

    /// Checks that both fields match, clears them either way, and asks the daemon to store the password.
    private func submit() {
        guard !password.isEmpty, !confirmation.isEmpty, !model.isBusy else { return }
        guard password == confirmation else {
            localProblem = "The two passwords are not the same."
            password = ""
            confirmation = ""
            passwordFocused = true
            return
        }
        let chosen = password
        // Both fields are emptied before the request is sent, so the password never sits on screen while the daemon works.
        password = ""
        confirmation = ""
        Task {
            if await !model.setup(password: chosen) { passwordFocused = true }
        }
    }
}
