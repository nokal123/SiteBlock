import Foundation

/// Reads passwords for the command-line tool, either from the terminal with echo turned off or, when input is piped, from lines of standard input.
enum PasswordPrompt {
    /// True when standard input is a terminal, so a person is typing and echo should be switched off.
    static var isInteractive: Bool { isatty(STDIN_FILENO) != 0 }

    /// Asks for one password. With a terminal it shows the prompt and reads with `readpassphrase` (a C function that turns off echo so the password does not appear while typing). With piped input it prints nothing and reads the next line of standard input, which is how tests and scripts supply passwords. Returns nil when there is nothing to read (end of input, or an error). A trailing newline is removed, and nothing else is changed, so spaces inside or around a password are kept.
    static func read(prompt: String) -> String? {
        if isInteractive {
            var buffer = [CChar](repeating: 0, count: 1024)
            defer { _ = buffer.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
            guard readpassphrase(prompt, &buffer, buffer.count, RPP_ECHO_OFF) != nil else { return nil }
            return String(cString: buffer)
        }
        // readLine uses the shared stdin buffer, so successive calls return successive lines.
        return readLine(strippingNewline: true)
    }

    /// Asks for a new password twice when a person is typing, and checks that both entries match. With piped input the second line is the confirmation if one is present; when the input has only one line, it is used as is. Returns nil when no password could be read; throws a mismatch message when the two entries differ.
    static func readNew(prompt: String, confirmPrompt: String) throws -> String? {
        guard let first = read(prompt: prompt) else { return nil }
        guard let second = read(prompt: confirmPrompt) else {
            // Piped input with a single line has no confirmation to compare; a person at a terminal cannot reach this branch except by pressing Ctrl-D, which cancels.
            return isInteractive ? nil : first
        }
        if first != second { throw PromptError.mismatch }
        return first
    }
}

/// Problems with what the user typed at a password prompt.
enum PromptError: Error {
    /// The new password and its confirmation were different.
    case mismatch
}
