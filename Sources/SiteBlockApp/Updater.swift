import AppKit
import Foundation
import SiteBlockCore

/// Finds out whether a newer SiteBlock has been published and installs it when the person asks. It never installs anything by itself: an install starts with a click on "Update" and needs the Mac password, because the installer runs as root. All network and file work runs off the main thread; this class only holds the state the views show.
@MainActor
final class Updater: ObservableObject {
    /// Where the updater is in a check or an install. The views turn this into the words shown in the banner and in Settings.
    enum Phase: Equatable {
        /// Nothing is happening.
        case idle
        /// A check for a newer version is running.
        case checking
        /// The package is being downloaded.
        case downloading
        /// The download is being checked and unzipped.
        case verifying
        /// The macOS password prompt is on screen.
        case waitingForPassword
        /// The installer is running.
        case installing
        /// The install failed; the text is the sentence to show.
        case failed(String)
        /// A manual check found nothing newer.
        case upToDate
    }

    /// What a manual check reported, shown under the button in Settings.
    enum CheckResult: Equatable {
        /// The published build is not newer than the installed one.
        case upToDate
        /// GitHub could not be reached, or its answer was not usable.
        case couldNotCheck

        /// The sentence shown under the button.
        var text: String {
            switch self {
            case .upToDate: return "You're up to date."
            case .couldNotCheck: return "Couldn't check for updates. Try again later."
            }
        }

        /// True when the sentence is shown as an error.
        var isError: Bool { self == .couldNotCheck }
    }

    /// The newest published build when it is newer than the installed one, otherwise nil.
    @Published private(set) var available: UpdateInfo?
    /// What the updater is doing right now.
    @Published private(set) var phase: Phase = .idle
    /// The sentence shown after the person cancelled the password prompt, until the next install attempt or "Not now".
    @Published private(set) var notice: String?
    /// The result of the last manual check, shown in Settings until the person leaves that screen.
    @Published private(set) var checkResult: CheckResult?
    /// The newest build the person pressed "Not now" for. It is kept in UserDefaults, and a newer build shows the banner again.
    @Published private(set) var dismissedBuild: Int

    /// The UserDefaults key that holds the dismissed build number.
    private static let dismissedKey = "dismissedUpdateBuild"
    /// Seconds from app start to the first automatic check.
    private static let firstCheckDelay = 60.0
    /// Seconds between automatic checks: 24 hours.
    private static let checkInterval = 86_400.0
    /// The most bytes a `version.json` answer may have; a real one is under 300, so anything bigger is not one.
    private nonisolated static let maxVersionFileBytes = 65_536

    /// The loop that runs the automatic checks.
    private var scheduleTask: Task<Void, Never>?
    /// The install that is running, kept so it is not started twice.
    private var installTask: Task<Void, Never>?

    /// Starts the schedule: the first check 60 seconds from now, then one every 24 hours.
    init() {
        dismissedBuild = UserDefaults.standard.integer(forKey: Self.dismissedKey)
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.firstCheckDelay))
            while !Task.isCancelled {
                // The updater is only held weakly, and not across the sleep, so a dropped updater also ends this loop.
                guard self != nil else { return }
                await self?.check(manual: false)
                try? await Task.sleep(for: .seconds(Self.checkInterval))
            }
        }
    }

    deinit {
        scheduleTask?.cancel()
    }

    /// True while a check or an install is running, so a second one is not started on top of it.
    var isWorking: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .waitingForPassword, .installing: return true
        case .idle, .failed, .upToDate: return false
        }
    }

    /// True while an install is running, which is when the banner shows the step in place of its buttons.
    var isInstalling: Bool {
        switch phase {
        case .downloading, .verifying, .waitingForPassword, .installing: return true
        case .idle, .checking, .failed, .upToDate: return false
        }
    }

    /// True when the update banner should show: a newer build is known and the person has not dismissed it. A running install, a failure and a cancel notice keep it on screen, so the person always sees what happened.
    var showsBanner: Bool {
        guard let info = available else { return false }
        if isInstalling || notice != nil { return true }
        if case .failed = phase { return true }
        return info.build > dismissedBuild
    }

    // MARK: - Checking

    /// Runs a check because the person pressed "Check for updates". It reports "You're up to date." or "Couldn't check for updates. Try again later." through `checkResult`.
    func checkNow() async {
        await check(manual: true)
    }

    /// Removes the manual check's result line. Settings calls it when the person leaves that screen, so the line is not stale on the next visit.
    func clearCheckResult() {
        if checkResult != nil { checkResult = nil }
        if phase == .upToDate { phase = .idle }
    }

    /// Fetches `version.json` and updates `available`. An automatic check says nothing about a failure and leaves `available` as it was; a manual check also sets `checkResult`.
    private func check(manual: Bool) async {
        guard !isWorking else { return }
        phase = .checking
        checkResult = nil
        let info = await Self.fetchVersionInfo()
        guard let info else {
            phase = .idle
            if manual { checkResult = .couldNotCheck }
            return
        }
        if UpdateCheck.isNewer(info, than: siteBlockBuildNumber) {
            available = info
            phase = .idle
            // The person asked, so a build they dismissed earlier is shown again.
            if manual { forgetDismissal() }
        } else {
            available = nil
            if manual {
                phase = .upToDate
                checkResult = .upToDate
            } else {
                phase = .idle
            }
        }
    }

    /// Downloads `version.json` and returns it only when it is a 200 answer of a sane size that `UpdateCheck.parse` accepts. Any failure gives nil. The session keeps no cookies and no disk cache, follows GitHub's redirect to its file host, and gives up after 15 seconds.
    private nonisolated static func fetchVersionInfo() async -> UpdateInfo? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let request = URLRequest(url: UpdateCheck.versionURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= maxVersionFileBytes else { return nil }
        return UpdateCheck.parse(data)
    }

    // MARK: - Dismissing

    /// Hides the banner for the offered build ("Not now"), remembers that in UserDefaults, and clears any failure or cancel message.
    func dismiss() {
        guard !isInstalling, let info = available else { return }
        notice = nil
        if case .failed = phase { phase = .idle }
        dismissedBuild = info.build
        UserDefaults.standard.set(info.build, forKey: Self.dismissedKey)
    }

    /// Forgets a dismissal, so the banner shows for the offered build again.
    private func forgetDismissal() {
        dismissedBuild = 0
        UserDefaults.standard.removeObject(forKey: Self.dismissedKey)
    }

    // MARK: - Installing

    /// Starts installing the offered build ("Update"). Does nothing when no update is known or another check or install is running.
    func install() {
        guard let info = available, !isWorking else { return }
        notice = nil
        installTask = Task { await runInstall(info) }
    }

    /// Runs the install steps in order: download, verify, copy to the staging folder, ask for the password and start the installer, then wait for it. Each step's file or network work runs off the main thread. Whatever happens, the temporary folders this app owns are removed.
    private func runInstall(_ info: UpdateInfo) async {
        var downloadFolder: URL?
        var staging: URL?
        defer { installTask = nil }
        do {
            phase = .downloading
            let folder = try await Task.detached { try await UpdateWork.download() }.value
            downloadFolder = folder

            phase = .verifying
            try await Task.detached { try UpdateWork.verify(in: folder, expectedSHA256: info.sha256) }.value

            // Only the checked zip is copied out of the download folder, which is then no longer needed. If the installer replaces this app, the old app never gets to clean up later. The root command checks and unzips this zip again by itself.
            let stagingFolder = try await Task.detached { try UpdateWork.stage(zipIn: folder) }.value
            staging = stagingFolder
            UpdateWork.remove(folder)
            downloadFolder = nil

            phase = .waitingForPassword
            let token = UUID().uuidString
            try await Task.detached { try UpdateWork.startInstaller(staging: stagingFolder, expectedSHA256: info.sha256, version: info.version, token: token) }.value
            // The root command has copied the zip into its own folder and removed the staging folder.
            staging = nil

            phase = .installing
            let exitCode = await UpdateWork.waitForInstaller(token: token)
            if exitCode == 0 {
                // The new app normally replaces this one before we get here; if this app is still running, the update is done anyway.
                available = nil
                phase = .idle
            } else {
                phase = .failed("The install didn't finish. Details are in \(UpdateWork.logPath).")
            }
        } catch UpdateStepError.cancelled {
            phase = .idle
            notice = "The update was cancelled."
        } catch UpdateStepError.downloadFailed {
            phase = .failed("The update couldn't be downloaded. Try again later.")
        } catch UpdateStepError.checksFailed {
            phase = .failed("The update didn't pass its checks, so nothing was installed.")
        } catch {
            phase = .failed("The installer couldn't be started, so nothing was installed.")
        }
        if let downloadFolder { UpdateWork.remove(downloadFolder) }
        if let staging { UpdateWork.remove(staging) }
    }
}

/// Why an install step stopped.
private enum UpdateStepError: Error {
    /// The package could not be downloaded (no network, or an answer other than 200).
    case downloadFailed
    /// The checksum, the unzip, the folder layout or a signature check failed.
    case checksFailed
    /// The person cancelled the password prompt.
    case cancelled
    /// The password prompt or the root command failed for another reason.
    case startFailed
}

/// The file, network and process work of an install. Every function here is safe to call from a background thread and none touches the views, which is why the `Updater` runs them with `Task.detached`.
private enum UpdateWork {
    /// Where the installer's output goes. The root command writes it, and the updater reads it to learn how the install ended.
    static let logPath = "/private/tmp/siteblock-update.log"
    /// The line the root command writes at the end of the log: this text, the token of this install, and the installer's exit code.
    private static let exitMarker = "SITEBLOCK-UPDATE-EXIT"
    /// How long to wait for the installer to write its exit line, in seconds. A normal install takes well under a minute.
    private static let installerTimeoutSeconds = 600

    /// The folders and files the unzipped package must contain, as paths below the unzip folder, with whether each is a folder. This is the layout `scripts/package.sh` produces.
    private static let requiredItems: [(path: String, isDirectory: Bool)] = [
        ("SiteBlock", true),
        ("SiteBlock/scripts", true),
        ("SiteBlock/build", true),
        ("SiteBlock/Install SiteBlock.command", false),
        ("SiteBlock/scripts/install.sh", false),
        ("SiteBlock/build/siteblockd", false),
        ("SiteBlock/build/siteblock", false),
        ("SiteBlock/build/SiteBlock.app", true),
    ]
    /// The three programs whose signatures must verify, as paths below the unzip folder.
    private static let signedPrograms = ["SiteBlock/build/siteblockd", "SiteBlock/build/siteblock", "SiteBlock/build/SiteBlock.app"]

    /// Downloads the package into a new `SiteBlockUpdate-<random>` folder in the user's temporary folder and returns that folder. The download waits at most 5 minutes. The folder is removed again when the download fails.
    static func download() async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SiteBlockUpdate-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw UpdateStepError.downloadFailed
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let request = URLRequest(url: UpdateCheck.packageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
            let (temporaryFile, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateStepError.downloadFailed }
            try FileManager.default.moveItem(at: temporaryFile, to: folder.appendingPathComponent("SiteBlock.zip"))
        } catch {
            remove(folder)
            throw UpdateStepError.downloadFailed
        }
        return folder
    }

    /// Checks the downloaded zip as the person's account, so a bad package is refused with a friendly message before any password prompt. The checksum must match, `ditto` must unzip it, every required item must exist as the right kind of item (a symbolic link does not count), and `codesign --verify --strict` must pass on the three programs. Any failure throws `checksFailed`. The unzipped copy is only for these checks; the root command repeats every check on its own copy.
    static func verify(in folder: URL, expectedSHA256: String) throws {
        let zip = folder.appendingPathComponent("SiteBlock.zip")
        guard UpdateCheck.matchesChecksum(fileAt: zip, expected: expectedSHA256) else { throw UpdateStepError.checksFailed }
        let unzipped = folder.appendingPathComponent("unzipped", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: unzipped, withIntermediateDirectories: false)) != nil else { throw UpdateStepError.checksFailed }
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path]) else { throw UpdateStepError.checksFailed }
        for item in requiredItems {
            let type = (try? FileManager.default.attributesOfItem(atPath: unzipped.appendingPathComponent(item.path).path))?[.type] as? FileAttributeType
            guard type == (item.isDirectory ? .typeDirectory : .typeRegular) else { throw UpdateStepError.checksFailed }
        }
        for program in signedPrograms {
            guard run("/usr/bin/codesign", ["--verify", "--strict", unzipped.appendingPathComponent(program).path]) else { throw UpdateStepError.checksFailed }
        }
    }

    /// Copies only the checked zip into a fresh `/private/tmp/siteblock-update-<random>` folder and returns that folder. The folder is created first (so an existing one is never reused) and is closed to other accounts. Nothing in it is trusted later: the root command copies the zip away and checks it again.
    static func stage(zipIn folder: URL) throws -> URL {
        let staging = URL(fileURLWithPath: "/private/tmp/siteblock-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: folder.appendingPathComponent("SiteBlock.zip"), to: staging.appendingPathComponent("SiteBlock.zip"))
        } catch {
            remove(staging)
            throw UpdateStepError.startFailed
        }
        return staging
    }

    /// Shows the macOS password prompt and starts the installer as root, detached. Nothing the person's account can write is trusted after the password. The root command first copies the staged zip into a new root-owned folder (`mktemp -d`, mode 700) and removes the staging folder. In that folder it recomputes the zip's SHA-256 and compares it with the expected one, unzips it, checks the layout and runs `codesign --verify --strict` on the three programs. Only then does it start `install.sh` from that folder in a background shell that ignores the hang-up signal, and return at once. It does not use `nohup`: under the password prompt there is no terminal, and macOS's `nohup` then refuses to start ("can't detach from console"), so the installer would never run. The installer is detached because it stops and replaces this very app: a shell that was a child of the app would end with it, and the install would stop half done. The background shell removes the root folder when the installer ends and writes `SITEBLOCK-UPDATE-EXIT <token> <exit code>` as the last line of the log. Throws `cancelled` when the person cancels the prompt, and `checksFailed` when a root-side check fails.
    static func startInstaller(staging: URL, expectedSHA256: String, version: String, token: String) throws {
        // The checksum goes into a shell command, so it must be exactly 64 lowercase hex characters before it gets anywhere near one.
        guard expectedSHA256.utf8.count == 64, expectedSHA256.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else { throw UpdateStepError.checksFailed }
        // Shell lists of the layout paths, each one quoted, for the "for" loops in the root script.
        let folders = requiredItems.filter { $0.isDirectory }.map { shellQuoted($0.path) }.joined(separator: " ")
        let files = requiredItems.filter { !$0.isDirectory }.map { shellQuoted($0.path) }.joined(separator: " ")
        let programs = signedPrograms.map { shellQuoted($0) }.joined(separator: " ")
        // The detached part. $1 is the root folder and $2 the token. The folder is removed whether or not the installer succeeded.
        let installer = "/bin/bash \"$1/unzipped/SiteBlock/scripts/install.sh\"; status=$?; /bin/rm -rf \"$1\"; echo \"\(exitMarker) $2 $status\""
        // The root script. $1 is the staging folder, $2 the expected checksum, $3 the token and $4 the detached part. Exit status 3 means a check failed. The root folder is removed on any exit until the installer has been handed it.
        let rootScript = """
        root=""
        cleanup() { if [ -n "$root" ]; then /bin/rm -rf "$root"; fi; }
        trap cleanup EXIT
        root="$(/usr/bin/mktemp -d /private/tmp/siteblock-update.XXXXXX)" || exit 1
        /bin/chmod 700 "$root" || exit 1
        /bin/cp "$1/SiteBlock.zip" "$root/SiteBlock.zip" || exit 1
        /bin/rm -rf "$1"
        have="$(/usr/bin/shasum -a 256 "$root/SiteBlock.zip" | /usr/bin/awk '{print $1}')"
        [ "$have" = "$2" ] || exit 3
        /usr/bin/ditto -x -k "$root/SiteBlock.zip" "$root/unzipped" || exit 3
        unz="$root/unzipped"
        for p in \(folders); do if [ ! -d "$unz/$p" ] || [ -L "$unz/$p" ]; then exit 3; fi; done
        for p in \(files); do if [ ! -f "$unz/$p" ] || [ -L "$unz/$p" ]; then exit 3; fi; done
        for p in \(programs); do /usr/bin/codesign --verify --strict "$unz/$p" >/dev/null 2>&1 || exit 3; done
        /bin/bash -c "trap '' HUP; $4" _ "$root" "$3" > \(logPath) 2>&1 < /dev/null &
        root=""
        exit 0
        """
        let command = "/bin/bash -c \(shellQuoted(rootScript)) _ \(shellQuoted(staging.path)) \(shellQuoted(expectedSHA256)) \(shellQuoted(token)) \(shellQuoted(installer))"
        let prompt = "SiteBlock needs your Mac password to install version \(version)."
        let source = "do shell script \"\(appleScriptEscaped(command))\" with prompt \"\(appleScriptEscaped(prompt))\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { throw UpdateStepError.startFailed }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return }
        // -128 is AppleScript's "user cancelled" error; otherwise the error number is the root script's exit status, and 3 means one of its checks failed.
        switch errorInfo[NSAppleScript.errorNumber] as? Int {
        case -128: throw UpdateStepError.cancelled
        case 3: throw UpdateStepError.checksFailed
        default: throw UpdateStepError.startFailed
        }
    }

    /// Waits for the installer's exit line in the log and returns its exit code, or nil when it does not appear in 10 minutes. The token ties the line to this install, so an older log left in `/private/tmp` cannot be mistaken for it. If the installer replaces this app first, this wait simply ends with the old app.
    static func waitForInstaller(token: String) async -> Int? {
        for _ in 0..<installerTimeoutSeconds {
            if let code = exitCode(inLogFor: token) { return code }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    /// Reads the log and returns the exit code on the line written for this token, or nil while there is none.
    private static func exitCode(inLogFor token: String) -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)) else { return nil }
        let prefix = "\(exitMarker) \(token) "
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() where line.hasPrefix(prefix) {
            return Int(line.dropFirst(prefix.count))
        }
        return nil
    }

    /// Deletes a file or folder this app created. A failure is ignored: the folder is in a temporary location.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Runs a program with its output thrown away and returns true when it exits with status 0. A program that cannot be started counts as a failure.
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Wraps text in single quotes for the shell, writing each single quote inside it as `'\''`, so the shell sees the text exactly as it is.
    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes backslashes and double quotes so the text can sit inside a double-quoted AppleScript string.
    private static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
