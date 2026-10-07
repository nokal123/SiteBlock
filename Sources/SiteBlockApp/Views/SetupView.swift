import SiteBlockCore
import SwiftUI

/// The inline "Choose a SiteBlock password" form: a new-password field, a confirm field, the minimum length, a warning that the password cannot be shown again, and two buttons.
/// It is not a screen of its own. The home panel shows it under the add field when Block is pressed before any password exists, and inside the "Choose a new password" banner after a password reset. Before anything is sent it checks that the two entries match and are long enough, so a typo costs nothing.
struct SetupView: View {
    @ObservedObject var model: StatusModel
    /// A sentence under the title that says what happens next (for example "reddit.com will be blocked as soon as the password is set."), or nil for none.
    let detail: String?
    /// What the main button says, such as "Set password and block".
    let submitTitle: String
    /// Called with the chosen password once the local checks pass. It returns true when the form has done its job and can go away, and false when the form should stay open for another try.
    let onSubmit: (String) async -> Bool
    /// Called by the Cancel button.
    let onCancel: () -> Void

    /// The password as typed in the first field.
    @State private var password = ""
    /// The password as typed in the second field.
    @State private var confirmation = ""
    /// A problem found on this form without asking the daemon (the two fields differ, or the password is too short).
    @State private var localProblem: String?
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a SiteBlock password").font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Blocking needs a password so every block can be undone later. It is separate from your Mac login password.")
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
            .font(.body)

            Text("At least \(PasswordHasher.minimumLength) characters.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("SiteBlock cannot show this password again, and you need it to unblock a site, shorten the delay or uninstall. If you forget it, the only way back is a reset started from Terminal with your Mac administrator password, followed by a 48 hour wait.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)

            if let localProblem { MessageLine(text: localProblem, isError: true) }
            FeedbackLine(model: model, scope: .setup)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(submitTitle, action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || confirmation.isEmpty || model.isBusy)
            }
        }
        .onAppear(perform: refocus)
        // Each time the panel opens, put the cursor back in the first field.
        .onChange(of: model.openCount) { _, _ in refocus() }
        // Typing again after a complaint removes it. Emptying the fields on submit must not remove it, so only a non-empty entry counts.
        .onChange(of: password) { _, typed in if !typed.isEmpty { localProblem = nil } }
        .onChange(of: confirmation) { _, typed in if !typed.isEmpty { localProblem = nil } }
    }

    /// Puts the cursor in the first field. The flag is switched off and on because setting a focus flag that is already true does nothing.
    private func refocus() {
        Task {
            passwordFocused = false
            await Task.yield()
            passwordFocused = true
        }
    }

    /// Empties both fields, checks that the two entries match and are long enough, and only then hands the password to `onSubmit`. A mismatch or a weak password is shown inline and nothing is sent.
    private func submit() {
        guard !password.isEmpty, !confirmation.isEmpty, !model.isBusy else { return }
        let chosen = password
        let matches = password == confirmation
        // Both fields are emptied whatever happens next, so the password never sits on screen while the daemon works or after a complaint.
        password = ""
        confirmation = ""
        guard matches else {
            localProblem = "The two passwords are not the same."
            passwordFocused = true
            return
        }
        // The same rule the daemon applies (length, and not only spaces), asked of the same code, so the sentence is the one the daemon would have sent.
        do {
            try PasswordHasher.validateNew(chosen)
        } catch {
            localProblem = error.localizedDescription
            passwordFocused = true
            return
        }
        Task {
            if await !onSubmit(chosen) { passwordFocused = true }
        }
    }
}
