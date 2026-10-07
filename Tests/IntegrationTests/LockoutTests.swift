import Foundation
import SiteBlockCore
import Testing

// The wrong-password lockout is shared by every command that takes a password.
// Design: 02-core-components.md § Engine ("Password check rule (shared by every command that takes a password)"); 01-overview-and-data.md § Fixed Policy Values (5 wrong passwords, then a lockout; 2 s under --policy-fast).
@Suite("Lockout across password commands")
struct LockoutTests {
    static let password = SandboxDaemon.password

    // The commands that check the password, each with the valid arguments they need (a delay in range, a long enough new password), so a refusal can only come from the password check.
    enum PasswordCommand: CaseIterable, CustomTestStringConvertible {
        case unblock, setDelay, changePassword, uninstall
        var testDescription: String { String(describing: self) }

        // Sends this command with the given password.
        func send(_ daemon: SandboxDaemon, password: String) throws -> Response {
            switch self {
            case .unblock: return try daemon.send(.unblock, domain: "reddit.com", password: password)
            case .setDelay: return try daemon.send(.setDelay, password: password, seconds: 300)
            case .changePassword: return try daemon.send(.changePassword, password: password, newPassword: "brand-new-pw-1")
            case .uninstall: return try daemon.send(.uninstall, password: password)
            }
        }
    }

    // 02 § Engine, password check rule: five wrong passwords through ANY password command start the lockout. Afterwards the right password is refused with lockedOut through that same command and through every other password command, and none of them changes anything (no countdown starts, the delay and the password stay). Once the lockout is over the original password works again, which also proves a refused changePassword did not change it.
    @Test(arguments: PasswordCommand.allCases)
    func fiveWrongPasswordsThroughOneCommandLockOutEveryPasswordCommand(command: PasswordCommand) throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            try daemon.requireTwoSecondDelay()
            for attempt in 1...5 {
                let reply = try command.send(daemon, password: "wrong-pass-\(attempt)")
                #expect(reply.errorCode == .wrongPassword, "wrong attempt \(attempt) through \(command.testDescription): \(reply.errorCode?.rawValue ?? "ok")")
            }
            let locked = try daemon.status()
            let seconds = try #require(locked.lockoutSecondsRemaining, "five wrong passwords through \(command.testDescription) did not start a lockout")
            #expect((1...2).contains(seconds))
            for other in PasswordCommand.allCases {
                let reply = try other.send(daemon, password: Self.password)
                #expect(reply.ok == false, "\(other.testDescription) with the right password was accepted during the lockout")
                #expect(reply.errorCode == .lockedOut, "right password through \(other.testDescription) during the lockout: \(reply.errorCode?.rawValue ?? "ok")")
            }
            let unchanged = try daemon.status()
            #expect(unchanged.delaySeconds == 2 && unchanged.pendingDelay == nil)
            #expect(unchanged.uninstallSecondsRemaining == nil)
            #expect(unchanged.blocked.first?.unblockSecondsRemaining == nil)

            let ended = waitUntil(timeout: 4.0, interval: 0.05) { (try? daemon.status().lockoutSecondsRemaining) == nil }
            #expect(ended != nil, "the lockout never ended")
            try daemon.send(.unblock, domain: "reddit.com", password: Self.password).requireOK()
        }
    }

    // The wrong-password count is one count for all commands: guesses spread over four different commands add up. Four wrong guesses (one per command, then unblock again) leave no lockout until the fifth, and then the right password through setDelay is refused.
    @Test func wrongPasswordsThroughDifferentCommandsAddUpToOneLockout() throws {
        try withDaemon { daemon in
            try daemon.prepare(blocking: "reddit.com")
            let sequence: [PasswordCommand] = [.unblock, .setDelay, .changePassword, .uninstall, .unblock]
            for (index, command) in sequence.enumerated() {
                let reply = try command.send(daemon, password: "wrong-pass-\(index)")
                #expect(reply.errorCode == .wrongPassword, "guess \(index + 1) through \(command.testDescription)")
                let status = try daemon.status()
                if index < 4 { #expect(status.lockoutSecondsRemaining == nil, "lockout started after only \(index + 1) wrong passwords") }
                else { #expect(status.lockoutSecondsRemaining != nil, "the fifth wrong password in total did not start a lockout") }
            }
            let refused = try PasswordCommand.setDelay.send(daemon, password: Self.password)
            #expect(refused.errorCode == .lockedOut)
        }
    }
}
