import SiteBlockCore
import SwiftUI

/// The Settings screen, shown inside the panel (a back button returns to the list) rather than in a separate window. It holds three forms (the unblock delay, the password, and uninstall) and one information box about the adult content filter. Every form needs the current password, and every password field is emptied as soon as the form is submitted.
struct SettingsView: View {
    @ObservedObject var model: StatusModel
    /// The latest status from the daemon.
    let snapshot: StatusSnapshot
    /// Returns to the main list.
    let goBack: () -> Void

    /// The delays offered in the picker, in seconds: 5 and 15 minutes, 30 minutes, 1, 2, 6, 12 and 24 hours, and 7 days.
    private static let delayChoices = [300, 900, 1_800, 3_600, 7_200, 21_600, 43_200, 86_400, 604_800]
    /// The tallest the scrolling form area may grow, in points.
    private static let maxFormHeight: CGFloat = 440

    /// The delay picked in the menu, or nil while the user has not touched it (meaning "the current delay").
    @State private var pickedDelay: Int?
    /// The password typed for the delay form.
    @State private var delayPassword = ""
    /// The three fields of the change-password form.
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    /// A problem found on this screen without asking the daemon (the new password and its confirmation differ).
    @State private var passwordProblem: String?
    /// Whether the uninstall password form is open.
    @State private var confirmingUninstall = false
    /// The password typed for the uninstall form.
    @State private var uninstallPassword = ""
    @FocusState private var uninstallFocused: Bool

    /// The delay the picker currently shows: the user's pick, or else the delay now in force.
    private var shownDelay: Int { pickedDelay ?? snapshot.delaySeconds }

    /// The picker's options: the standard choices, plus the current delay when it is not one of them (for example 45 minutes set from Terminal), so the picker never shows an empty selection.
    private var delayOptions: [Int] {
        Array(Set(Self.delayChoices + [snapshot.delaySeconds])).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    if BannersView.hasContent(snapshot: snapshot, feedback: model.feedback) { BannersView(model: model, snapshot: snapshot) }
                    delaySection
                    passwordSection
                    if snapshot.adultFilterEnabled == true { adultFilterSection }
                    uninstallSection
                }
                .padding(16)
            }
            .frame(maxHeight: Self.maxFormHeight)
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            Text("SiteBlock service \(snapshot.version)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }

    /// The top row: a back button on the left and the screen title in the middle.
    private var navigationBar: some View {
        ZStack {
            Text("Settings").font(.headline)
            HStack {
                Button(action: goBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Delay

    /// The form for changing how long an unblock waits.
    private var delaySection: some View {
        SectionCard(title: "Unblock delay") {
            HStack {
                Text("Wait before a site opens")
                Spacer()
                Picker("Delay", selection: Binding(get: { shownDelay }, set: { pickedDelay = $0 })) {
                    ForEach(delayOptions, id: \.self) { Text(Formatting.duration($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text(delayHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $delayPassword)
                .textFieldStyle(.roundedBorder)
                .onSubmit(applyDelay)
            FeedbackLine(model: model, scope: .delay)
            HStack {
                Spacer()
                Button("Change delay", action: applyDelay)
                    .buttonStyle(.borderedProminent)
                    .disabled(shownDelay == snapshot.delaySeconds || delayPassword.isEmpty || model.isBusy)
            }
        }
    }

    /// Explains what picking the current choice will do: a longer delay applies at once, a shorter one has to wait.
    private var delayHint: String {
        let current = Formatting.duration(snapshot.delaySeconds)
        if shownDelay < snapshot.delaySeconds {
            return "A shorter delay only starts after the current wait of \(current) has passed. You can cancel the change before then."
        }
        if shownDelay > snapshot.delaySeconds { return "A longer delay applies right away." }
        return "Unblocking a site now takes \(current). A longer delay applies right away; a shorter one waits out the current delay first."
    }

    /// Sends the chosen delay with the typed password, and empties the password field before the daemon answers.
    private func applyDelay() {
        guard shownDelay != snapshot.delaySeconds, !delayPassword.isEmpty, !model.isBusy else { return }
        let seconds = shownDelay
        let typed = delayPassword
        delayPassword = ""
        Task {
            // After a success the picker goes back to following the daemon's delay, so it shows the real current value.
            if await model.setDelay(seconds: seconds, password: typed) { pickedDelay = nil }
        }
    }

    // MARK: - Password

    /// The form for replacing the password.
    private var passwordSection: some View {
        SectionCard(title: "Password") {
            VStack(spacing: 6) {
                SecureField("Current password", text: $oldPassword)
                SecureField("New password", text: $newPassword)
                SecureField("Confirm new password", text: $confirmPassword)
                    .onSubmit(changePassword)
            }
            .textFieldStyle(.roundedBorder)
            Text("At least \(PasswordHasher.minimumLength) characters. The new password applies at once.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let passwordProblem { MessageLine(text: passwordProblem, isError: true) }
            FeedbackLine(model: model, scope: .password)
            HStack {
                Spacer()
                Button("Change password", action: changePassword)
                    .buttonStyle(.borderedProminent)
                    .disabled(oldPassword.isEmpty || newPassword.isEmpty || confirmPassword.isEmpty || model.isBusy)
            }
        }
        // Typing again after a mismatch removes the old complaint.
        .onChange(of: newPassword) { _, _ in passwordProblem = nil }
        .onChange(of: confirmPassword) { _, _ in passwordProblem = nil }
    }

    /// Checks that the new password matches its confirmation, empties all three fields, and asks the daemon to change the password.
    private func changePassword() {
        guard !oldPassword.isEmpty, !newPassword.isEmpty, !confirmPassword.isEmpty, !model.isBusy else { return }
        let old = oldPassword
        let new = newPassword
        let matches = newPassword == confirmPassword
        // The fields are emptied whatever happens next, so a password never stays on screen.
        oldPassword = ""
        newPassword = ""
        confirmPassword = ""
        guard matches else {
            passwordProblem = "The new password and its confirmation are not the same."
            return
        }
        Task { _ = await model.changePassword(old: old, new: new) }
    }

    // MARK: - Adult content filter

    /// The information box about the adult content filter. It has no controls: the filter is always on, and only uninstalling SiteBlock removes it. The box is left out when the SiteBlock service is an older version that does not report the filter.
    private var adultFilterSection: some View {
        SectionCard(title: "Adult content filter: always on") {
            Text("SiteBlock blocks adult websites in every browser, including sites that are not on your list. It uses the family DNS servers from Cloudflare, and it turns on SafeSearch and the adult-site filter in Chrome. It has no switch and no password. It is removed only by uninstalling SiteBlock.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("A VPN that supplies its own DNS servers can bypass the DNS part.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Uninstall

    /// The uninstall box. Uninstalling needs the password and then waits 48 hours, or the unblock delay if that is longer, and the wait can be cancelled.
    private var uninstallSection: some View {
        SectionCard(title: "Uninstall") {
            // The installed service always uses the production policy, so its 48-hour minimum is the one that applies.
            Text("Uninstalling removes SiteBlock and every block. It needs your password and then waits \(Formatting.duration(max(Policy.production.minUninstallSeconds, snapshot.delaySeconds))), and every site stays blocked until then. You can cancel during the wait.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if snapshot.uninstallSecondsRemaining != nil {
                Text("An uninstall is already scheduled. Cancel it from the notice at the top of this screen.")
                    .font(.callout)
            } else if confirmingUninstall {
                uninstallForm
            } else {
                Button("Uninstall SiteBlock…", role: .destructive) { confirmingUninstall = true }
                    .foregroundStyle(.red)
            }
            FeedbackLine(model: model, scope: .uninstall)
        }
    }

    /// The password field and the confirm and cancel buttons for starting an uninstall.
    private var uninstallForm: some View {
        HStack(spacing: 6) {
            SecureField("Password", text: $uninstallPassword)
                .textFieldStyle(.roundedBorder)
                .focused($uninstallFocused)
                .onSubmit(startUninstall)
            Button("Cancel") {
                uninstallPassword = ""
                confirmingUninstall = false
            }
            Button("Start uninstall", role: .destructive, action: startUninstall)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(uninstallPassword.isEmpty || model.isBusy)
        }
        .controlSize(.small)
        .onAppear { uninstallFocused = true }
    }

    /// Sends the uninstall request with the typed password, and empties the field before the daemon answers.
    private func startUninstall() {
        guard !uninstallPassword.isEmpty, !model.isBusy else { return }
        let typed = uninstallPassword
        uninstallPassword = ""
        Task {
            if await model.uninstall(password: typed) {
                confirmingUninstall = false
            } else {
                // The form stays open after a refusal so the user can retry.
                uninstallFocused = true
            }
        }
    }
}
