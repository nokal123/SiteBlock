import Foundation
import SiteBlockCore
import SwiftUI

/// Whether the app can currently reach the SiteBlock service.
enum DaemonConnection: Equatable {
    /// No answer has come back yet since the app started.
    case connecting
    /// The last status request was answered.
    case connected
    /// The last status request failed; the text is the sentence to show the user.
    case notRunning(String)
}

/// The part of the panel a message belongs to, so each message appears next to the control that caused it instead of in one far-away spot.
enum FeedbackScope: Hashable {
    /// The "add a site" field.
    case add
    /// One blocked-site row, named by its domain.
    case site(String)
    /// One blocked-part-of-a-site row, named by its rule text such as youtube.com/shorts.
    case rule(String)
    /// The warning banners at the top of the panel.
    case banner
    /// The delay form in Settings.
    case delay
    /// The change-password form in Settings.
    case password
    /// The uninstall form in Settings.
    case uninstall
    /// The inline "Choose a SiteBlock password" form: the one that opens at the first block, and the one the "Choose a new password" banner opens after a reset.
    case setup
}

/// One message shown inline: either a daemon error sentence or a daemon confirmation sentence.
struct Feedback: Equatable {
    /// A number that is different for every message, so a timer that was started for an old message cannot clear a newer one.
    let id: Int
    /// Where the message is shown.
    let scope: FeedbackScope
    /// The sentence to show.
    let text: String
    /// True for an error (shown in red), false for a confirmation.
    let isError: Bool
}

/// How it went when the first password was set and the first site was blocked in one go.
enum FirstBlockOutcome: Equatable {
    /// The password was not set, so nothing else was sent. The reason is shown inside the password form.
    case passwordNotSet
    /// The password was set, but the daemon refused the site (for example it is not a valid site name). The reason is shown under the add field.
    case passwordSetSiteRefused
    /// The password was set and the site is blocked.
    case blocked
}

/// The latest answer from a request: either the daemon's response or the reason none arrived, plus the moment it came back.
private struct Reply: Sendable {
    /// The daemon's response, or the client error that stopped one from arriving.
    let result: Result<Response, ClientError>
    /// When the answer arrived, measured on the monotonic clock so countdown math ignores wall-clock changes.
    let arrivedAt: ContinuousClock.Instant
}

/// Holds everything the panel shows: the latest status from the daemon, whether the daemon is reachable, and the message from the last command.
/// The daemon is the only source of truth, so this class keeps no state of its own beyond what the screen needs.
@MainActor
final class StatusModel: ObservableObject {
    /// The most recent status the daemon sent. It stays set while the daemon is unreachable so the last known data is not thrown away.
    @Published private(set) var snapshot: StatusSnapshot?
    /// When `snapshot` arrived. Countdown labels add the time elapsed since this moment to stay accurate between polls.
    @Published private(set) var snapshotInstant = ContinuousClock.now
    /// Whether the daemon answered the last request.
    @Published private(set) var connection: DaemonConnection = .connecting
    /// The message from the last command, shown for a few seconds and then cleared.
    @Published private(set) var feedback: Feedback?
    /// True while at least one command is waiting for the daemon, so the views can disable their buttons and avoid double submits.
    @Published private(set) var isBusy = false
    /// Goes up by one every time the panel closes. The panel uses it as a view identity, so closing the panel throws away typed passwords and open forms.
    @Published private(set) var closeCount = 0
    /// Goes up by one every time the panel opens, so the add field can take keyboard focus again.
    @Published private(set) var openCount = 0

    /// How often to ask the daemon for status while the panel is open.
    private static let visiblePollSeconds = 1.0
    /// How often to ask while the panel is closed, which is only enough to keep the menu bar icon honest.
    private static let hiddenPollSeconds = 30.0
    /// How long a message stays on screen.
    private static let feedbackSeconds = 6.0

    /// The socket client. It honors SITEBLOCK_SOCKET, so a sandbox daemon is reached without extra code here.
    private let client = DaemonClient()
    /// Every daemon call runs here, never on the main thread. The queue is concurrent so a status poll that is stuck waiting on a hung daemon cannot hold up a command behind it.
    private let requestQueue = DispatchQueue(label: "com.nokal.siteblock.app.requests", qos: .userInitiated, attributes: .concurrent)

    /// The repeating status poll.
    private var pollTask: Task<Void, Never>?
    /// True while a status poll is waiting on the daemon, so two polls never pile up behind a slow daemon.
    private var pollInFlight = false
    /// Whether the panel is on screen right now; it picks the poll speed.
    private var panelVisible = false
    /// Counts requests in the order they were sent. A reply that was sent before the newest reply already applied is stale and is ignored.
    private var requestCounter = 0
    /// The send order of the newest reply whose status has been applied.
    private var lastAppliedRequest = 0
    /// How many commands are waiting for the daemon.
    private var commandsInFlight = 0
    /// Counts messages, to give each one its own id.
    private var feedbackCounter = 0
    /// The timer that clears the current message.
    private var feedbackClearTask: Task<Void, Never>?

    /// Creates the model and starts polling the daemon right away, so the menu bar icon is correct even before the panel is opened.
    init() {
        restartPolling()
    }

    /// The SF Symbol for the menu bar: a half-filled shield normally, and a slashed shield when the service cannot be reached.
    var menuIconName: String {
        if case .notRunning = connection { return "shield.slash" }
        return "shield.lefthalf.filled"
    }

    // MARK: - Panel visibility

    /// Called by the panel when it opens or closes. Opening polls at once and speeds up polling; closing slows polling down and wipes transient screen state.
    func panelVisibilityChanged(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        if visible {
            openCount += 1
            // Poll immediately instead of waiting out a 30 second sleep, so the panel never opens on old data.
            restartPolling()
        } else {
            closeCount += 1
            clearFeedback()
        }
    }

    // MARK: - Polling

    /// Starts (or restarts) the poll loop. The loop holds the model only weakly, so a model that is dropped also stops its loop.
    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let seconds = await self?.pollOnce() else { return }
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    /// Runs one status poll and returns how long to wait before the next one.
    private func pollOnce() async -> Double {
        await refresh()
        return panelVisible ? Self.visiblePollSeconds : Self.hiddenPollSeconds
    }

    /// Asks the daemon for its status and applies the answer. Does nothing when a poll is already waiting on the daemon.
    func refresh() async {
        guard !pollInFlight else { return }
        pollInFlight = true
        defer { pollInFlight = false }
        let order = nextRequestOrder()
        let reply = await perform(Request(command: .status))
        switch reply.result {
        case .success(let response):
            if response.ok, let status = response.status {
                applyStatus(status, order: order, arrivedAt: reply.arrivedAt)
            } else {
                applyFailure(response.error ?? "The SiteBlock service refused the status request.", order: order)
            }
        case .failure(let error):
            applyFailure(error.localizedDescription, order: order)
        }
    }

    // MARK: - Commands

    /// Blocks a site at once. No password is typed for this, but one must already be set: the daemon refuses with "set a password first" otherwise, which is why the panel asks for one before it calls this. Returns true when the daemon accepted it.
    func add(domain: String) async -> Bool {
        await run(Request(command: .add, domain: domain), scope: .add)
    }

    /// Blocks only the typed part of a site (for example youtube.com/shorts) at once. The text goes to the daemon as typed, and the daemon works out the site and the path. Returns true when the daemon accepted it.
    func addPath(rule: String) async -> Bool {
        await run(Request(command: .addPath, domain: rule), scope: .add)
    }

    /// The first block: sets the SiteBlock password, and only when the daemon accepts it, blocks `domain` (the whole site, or only the typed part of it when `onlyThisPart` is true). If the password is refused (too short, or one is already set), no block is requested at all.
    func setupThenAdd(password: String, domain: String, onlyThisPart: Bool = false) async -> FirstBlockOutcome {
        // Both requests count as one piece of work, so the buttons stay disabled in the gap between them.
        commandsInFlight += 1
        isBusy = true
        defer {
            commandsInFlight -= 1
            isBusy = commandsInFlight > 0
        }
        guard await setup(password: password) else { return .passwordNotSet }
        let accepted = onlyThisPart ? await addPath(rule: domain) : await add(domain: domain)
        return accepted ? .blocked : .passwordSetSiteRefused
    }

    /// Starts the unblock countdown for a site. The site stays blocked until the countdown ends. Returns true when the daemon accepted it.
    func unblock(domain: String, password: String) async -> Bool {
        await run(Request(command: .unblock, domain: domain, password: password), scope: .site(domain))
    }

    /// Cancels a pending unblock so the site stays blocked for good. Needs no password.
    func cancelUnblock(domain: String) async -> Bool {
        await run(Request(command: .cancelUnblock, domain: domain), scope: .site(domain))
    }

    /// Starts the unblock countdown for a blocked part of a site, named by its rule text. The rule stays blocked until the countdown ends. Returns true when the daemon accepted it.
    func unblockPath(rule: String, password: String) async -> Bool {
        await run(Request(command: .unblockPath, domain: rule, password: password), scope: .rule(rule))
    }

    /// Cancels a pending unblock of a blocked part of a site so it stays blocked for good. Needs no password.
    func cancelUnblockPath(rule: String) async -> Bool {
        await run(Request(command: .cancelUnblockPath, domain: rule), scope: .rule(rule))
    }

    /// Asks for a new unblock delay. A longer delay applies at once; a shorter one waits out the current delay first.
    func setDelay(seconds: Int, password: String) async -> Bool {
        await run(Request(command: .setDelay, password: password, seconds: seconds), scope: .delay)
    }

    /// Drops a requested shorter delay so the current one stays. Needs no password.
    func cancelDelayChange() async -> Bool {
        await run(Request(command: .cancelDelayChange), scope: .banner)
    }

    /// Replaces the password after the daemon checks the old one.
    func changePassword(old: String, new: String) async -> Bool {
        await run(Request(command: .changePassword, password: old, newPassword: new), scope: .password)
    }

    /// Sets the SiteBlock password: the first one, or a new one after a forgotten-password reset has cleared the old one. Returns true when the daemon accepted it.
    func setup(password: String) async -> Bool {
        await run(Request(command: .setup, password: password), scope: .setup)
    }

    /// Starts the uninstall countdown. SiteBlock is removed when it ends unless it is cancelled first.
    func uninstall(password: String) async -> Bool {
        await run(Request(command: .uninstall, password: password), scope: .uninstall)
    }

    /// Cancels a pending uninstall. Needs no password.
    func cancelUninstall() async -> Bool {
        await run(Request(command: .cancelUninstall), scope: .banner)
    }

    /// Cancels a running forgotten-password reset. Needs no password.
    func cancelRecovery() async -> Bool {
        await run(Request(command: .recoveryCancel), scope: .banner)
    }

    /// Sends one command, applies the status it returns, and shows the daemon's message next to the control in `scope`. Returns true when the daemon said ok.
    private func run(_ request: Request, scope: FeedbackScope) async -> Bool {
        commandsInFlight += 1
        isBusy = true
        defer {
            commandsInFlight -= 1
            isBusy = commandsInFlight > 0
        }
        let order = nextRequestOrder()
        let reply = await perform(request)
        switch reply.result {
        case .success(let response) where response.ok:
            if let status = response.status { applyStatus(status, order: order, arrivedAt: reply.arrivedAt) }
            if let message = response.message { show(message, isError: false, scope: scope) }
            return true
        case .success(let response):
            show(response.error ?? "The SiteBlock service refused the command.", isError: true, scope: scope)
            // A refusal carries no status, so ask again right away. A wrong password may just have started a lockout that the panel should now show.
            await refresh()
            return false
        case .failure(let error):
            show(error.localizedDescription, isError: true, scope: scope)
            // Only "not running" means the connection is gone; a timeout on one command does not make the whole panel unusable.
            if error == .notRunning { applyFailure(error.localizedDescription, order: order) }
            return false
        }
    }

    // MARK: - Talking to the daemon

    /// Hands out the next send-order number; the number is taken when the request is sent, not when the reply arrives.
    private func nextRequestOrder() -> Int {
        requestCounter += 1
        return requestCounter
    }

    /// Sends one request on the background queue and resumes with the reply. The main thread is never blocked, even when the daemon hangs until the client's 10 second timeout.
    private func perform(_ request: Request) async -> Reply {
        let client = client
        return await withCheckedContinuation { continuation in
            requestQueue.async {
                let result: Result<Response, ClientError>
                do {
                    result = .success(try client.send(request))
                } catch let error as ClientError {
                    result = .failure(error)
                } catch {
                    result = .failure(.ioFailure(error.localizedDescription))
                }
                continuation.resume(returning: Reply(result: result, arrivedAt: ContinuousClock.now))
            }
        }
    }

    /// Stores a fresh status and marks the daemon as reachable, unless a newer reply was already applied.
    private func applyStatus(_ status: StatusSnapshot, order: Int, arrivedAt: ContinuousClock.Instant) {
        // Two requests can be in flight at once. If the older one answers last, its data is out of date and must not overwrite the newer data.
        guard order > lastAppliedRequest else { return }
        lastAppliedRequest = order
        snapshot = status
        snapshotInstant = arrivedAt
        if connection != .connected { connection = .connected }
    }

    /// Marks the daemon as unreachable, unless a newer reply was already applied.
    private func applyFailure(_ text: String, order: Int) {
        guard order > lastAppliedRequest else { return }
        lastAppliedRequest = order
        connection = .notRunning(text)
    }

    // MARK: - Messages

    /// Shows a message in the given place and starts the timer that removes it.
    private func show(_ text: String, isError: Bool, scope: FeedbackScope) {
        feedbackCounter += 1
        let id = feedbackCounter
        withAnimation(.easeOut(duration: 0.15)) { feedback = Feedback(id: id, scope: scope, text: text, isError: isError) }
        feedbackClearTask?.cancel()
        feedbackClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.feedbackSeconds))
            guard !Task.isCancelled else { return }
            self?.clearFeedback(id: id)
        }
    }

    /// Removes the current message. When an id is given, removes it only if that message is still the one on screen, so an old timer cannot clear a newer message.
    private func clearFeedback(id: Int? = nil) {
        if let id, feedback?.id != id { return }
        feedbackClearTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { feedback = nil }
    }
}

/// Small helpers for countdown labels that tick between polls.
enum CountdownMath {
    /// The seconds left on a countdown that the daemon reported as `reported` seconds when the reply arrived at `asOf`. Never goes below 0.
    static func remaining(reported: Int, asOf: ContinuousClock.Instant, now: ContinuousClock.Instant = ContinuousClock.now) -> Int {
        let parts = (now - asOf).components
        let elapsed = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        // The daemon rounds up to whole seconds, so rounding up here keeps a running countdown from showing 0 early.
        return max(0, Int((Double(reported) - max(0, elapsed)).rounded(.up)))
    }
}
