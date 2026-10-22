using SiteBlock.Core;

namespace SiteBlock.AppLogic;

/// <summary>
/// Holds everything the panel shows: the latest status from the service, whether the service is reachable, the message from the last command, and whether a command is waiting.
/// It asks the service for its status once a second while the panel is open and every 30 seconds otherwise, and it has one method per command. The service is the only source of truth, so this class keeps nothing beyond what the screen needs.
/// Every property changes only inside the screen dispatcher (<see cref="IUiDispatcher"/>), so a window can read them on its own thread without locks.
/// It owns the <see cref="Updater"/> and the <see cref="TabWatcher"/> (either may be null in tests) and hands the watcher the path rules of every status it applies.
/// </summary>
public sealed class StatusModel : ObservableModel, IDisposable
{
    /// <summary>How often the status is asked for while the panel is open.</summary>
    public static readonly TimeSpan VisiblePollInterval = TimeSpan.FromSeconds(1);

    /// <summary>How often the status is asked for while the panel is closed, which is only enough to keep the tray icon honest.</summary>
    public static readonly TimeSpan HiddenPollInterval = TimeSpan.FromSeconds(30);

    /// <summary>How long a message stays on screen.</summary>
    public static readonly TimeSpan FeedbackDuration = TimeSpan.FromSeconds(6);

    /// <summary>The sentence shown when the service refused a status request without saying why.</summary>
    public const string StatusRefusedText = "The SiteBlock service refused the status request.";

    /// <summary>The sentence shown when the service refused a command without saying why.</summary>
    public const string CommandRefusedText = "The SiteBlock service refused the command.";

    /// <summary>The sentence shown when talking to the service failed in a way the client does not name.</summary>
    public const string UnknownFailureText = "Could not talk to the SiteBlock service.";

    private readonly IDaemonClient _client;
    private readonly IClock _clock;
    private readonly IUiDispatcher _ui;

    private StatusSnapshot? _snapshot;
    private long _snapshotArrivedAt;
    private DaemonConnection _connection = DaemonConnection.Connecting;
    private Feedback? _feedback;
    private bool _isBusy;
    private int _openCount;
    private int _closeCount;
    private bool _panelVisible;

    // Used only inside dispatcher actions.
    private long _lastAppliedRequest;
    private int _commandsInFlight;
    private int _feedbackCounter;

    // Touched from any thread, so only through Interlocked or the lock.
    private long _requestCounter;
    private int _pollInFlight;
    private readonly Lock _pollGate = new();
    private CancellationTokenSource? _pollCancel;
    private volatile bool _pollFast;
    private bool _disposed;

    /// <summary>Creates the model. Nothing is sent until <see cref="Start"/> is called.</summary>
    public StatusModel(IDaemonClient client, IClock clock, IUiDispatcher ui, Updater? updater = null, TabWatcher? tabWatcher = null)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _ui = ui ?? throw new ArgumentNullException(nameof(ui));
        Updater = updater;
        TabWatcher = tabWatcher;
        _snapshotArrivedAt = clock.MonotonicMilliseconds;
        // Views that watch only this model must redraw when the update state changes, so the updater's changes are passed on.
        if (updater is not null) updater.PropertyChanged += (_, _) => OnPropertyChanged(nameof(Updater));
    }

    /// <summary>The clock the model and its countdowns use.</summary>
    public IClock Clock => _clock;

    /// <summary>Looks for a newer SiteBlock and installs it when the person asks; null when the model was made without one.</summary>
    public Updater? Updater { get; }

    /// <summary>Reloads browser tabs that moved onto a blocked part of a site; null when the model was made without one.</summary>
    public TabWatcher? TabWatcher { get; }

    /// <summary>The most recent status the service sent. It stays set while the service is unreachable, so the last known data is not thrown away.</summary>
    public StatusSnapshot? Snapshot { get => _snapshot; private set => SetField(ref _snapshot, value); }

    /// <summary>When <see cref="Snapshot"/> arrived, on the monotonic clock. Countdowns subtract the time since then, so they keep moving between polls.</summary>
    public long SnapshotArrivedAt { get => _snapshotArrivedAt; private set => SetField(ref _snapshotArrivedAt, value); }

    /// <summary>Whether the service answered the last request.</summary>
    public DaemonConnection Connection { get => _connection; private set => SetField(ref _connection, value); }

    /// <summary>True when the service cannot be reached, which is when the tray shows the slashed shield.</summary>
    public bool ServiceUnreachable => _connection.State == ConnectionState.NotRunning;

    /// <summary>The message from the last command, cleared after <see cref="FeedbackDuration"/>.</summary>
    public Feedback? Feedback { get => _feedback; private set => SetField(ref _feedback, value); }

    /// <summary>True while at least one command waits for the service, so the panel can turn its buttons off and avoid double submits.</summary>
    public bool IsBusy { get => _isBusy; private set => SetField(ref _isBusy, value); }

    /// <summary>Goes up by one each time the panel opens.</summary>
    public int OpenCount { get => _openCount; private set => SetField(ref _openCount, value); }

    /// <summary>Goes up by one each time the panel closes. The panel throws away typed passwords and open forms when it changes.</summary>
    public int CloseCount { get => _closeCount; private set => SetField(ref _closeCount, value); }

    /// <summary>Whether the panel is on screen, which picks the poll speed.</summary>
    public bool PanelVisible { get => _panelVisible; private set => SetField(ref _panelVisible, value); }

    /// <summary>The seconds left on a countdown the latest status reported as <paramref name="reported"/>, counting the time since that status arrived.</summary>
    public int Remaining(long reported) => CountdownMath.Remaining(reported, SnapshotArrivedAt, _clock.MonotonicMilliseconds);

    /// <summary>Starts polling the service at once, and starts the updater's schedule and the tab watcher's loop.</summary>
    public void Start()
    {
        RestartPolling();
        Updater?.Start();
        TabWatcher?.Start();
    }

    /// <summary>Stops polling, the updater's schedule and the tab watcher.</summary>
    public void Dispose()
    {
        lock (_pollGate)
        {
            if (_disposed) return;
            _disposed = true;
            _pollCancel?.Cancel();
            _pollCancel?.Dispose();
            _pollCancel = null;
        }
        Updater?.Dispose();
        TabWatcher?.Dispose();
    }

    // ---- Panel visibility ----

    /// <summary>Called when the panel opens or closes. Opening asks for the status at once and polls every second; closing slows polling to every 30 seconds and clears the message.</summary>
    public async Task PanelVisibilityChangedAsync(bool visible)
    {
        bool changed = false;
        await _ui.InvokeAsync(() =>
        {
            if (visible == PanelVisible) return;
            changed = true;
            PanelVisible = visible;
            if (visible) OpenCount++;
            else
            {
                CloseCount++;
                ClearFeedback(null);
            }
        }).ConfigureAwait(false);
        if (!changed) return;
        _pollFast = visible;
        // Opening polls immediately instead of waiting out a 30 second wait, so the panel never opens on old data.
        if (visible) RestartPolling();
    }

    // ---- Polling ----

    /// <summary>Starts (or restarts) the poll loop on a pool thread.</summary>
    private void RestartPolling()
    {
        CancellationToken token;
        lock (_pollGate)
        {
            if (_disposed) return;
            _pollCancel?.Cancel();
            _pollCancel?.Dispose();
            _pollCancel = new CancellationTokenSource();
            token = _pollCancel.Token;
        }
        _ = Task.Run(() => PollLoopAsync(token), CancellationToken.None);
    }

    /// <summary>Asks for the status, waits one interval (1 second with the panel open, 30 seconds otherwise), and repeats until cancelled.</summary>
    private async Task PollLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            // One failed refresh (an exception from the window thread, say) must not end polling for good; the next interval tries again.
            try { await RefreshAsync().ConfigureAwait(false); }
            catch (Exception error) when (error is not OperationCanceledException) { }
            try
            {
                await _clock.Delay(_pollFast ? VisiblePollInterval : HiddenPollInterval, token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    /// <summary>Asks the service for its status and applies the answer. Does nothing when a status request is already waiting, so polls never pile up behind a slow service.</summary>
    public async Task RefreshAsync()
    {
        if (Interlocked.CompareExchange(ref _pollInFlight, 1, 0) != 0) return;
        try
        {
            long order = NextRequestOrder();
            Reply reply = await PerformAsync(new Request(Command.Status)).ConfigureAwait(false);
            await _ui.InvokeAsync(() =>
            {
                if (reply.Response is { } response)
                {
                    if (response.Ok && response.Status is { } status) ApplyStatus(status, order, reply.ArrivedAt);
                    else ApplyFailure(response.Error ?? StatusRefusedText, order);
                }
                else ApplyFailure(reply.FailureText!, order);
            }).ConfigureAwait(false);
        }
        finally
        {
            Volatile.Write(ref _pollInFlight, 0);
        }
    }

    // ---- Commands ----

    /// <summary>Blocks a whole site at once. A password must already be set; the panel asks for one first when none is. Returns true when the service accepted it.</summary>
    public Task<bool> AddAsync(string domain) => RunAsync(new Request(Command.Add, Domain: domain), FeedbackScope.Add);

    /// <summary>Blocks only the typed part of a site (such as youtube.com/shorts) at once. The text goes to the service as typed. Returns true when the service accepted it.</summary>
    public Task<bool> AddPathAsync(string rule) => RunAsync(new Request(Command.AddPath, Domain: rule), FeedbackScope.Add);

    /// <summary>
    /// The first block: sets the password and, only when the service accepts it, blocks the site (or only the typed part when <paramref name="onlyThisPart"/> is true).
    /// Both requests count as one piece of work, so the buttons stay off in the gap between them.
    /// </summary>
    public async Task<FirstBlockOutcome> SetupThenAddAsync(string password, string domain, bool onlyThisPart)
    {
        await _ui.InvokeAsync(BeginWork).ConfigureAwait(false);
        try
        {
            if (!await SetupAsync(password).ConfigureAwait(false)) return FirstBlockOutcome.PasswordNotSet;
            bool accepted = onlyThisPart ? await AddPathAsync(domain).ConfigureAwait(false) : await AddAsync(domain).ConfigureAwait(false);
            return accepted ? FirstBlockOutcome.Blocked : FirstBlockOutcome.PasswordSetSiteRefused;
        }
        finally
        {
            await _ui.InvokeAsync(EndWork).ConfigureAwait(false);
        }
    }

    /// <summary>Starts the unblock countdown for a site; it stays blocked until the countdown ends. Returns true when the service accepted it.</summary>
    public Task<bool> UnblockAsync(string domain, string password) => RunAsync(new Request(Command.Unblock, Domain: domain, Password: password), FeedbackScope.Site(domain));

    /// <summary>Schedules a temporary unblock of a site: it stays blocked for the start wait, opens for the window, then is blocked again on its own. Returns true when the service accepted it.</summary>
    public Task<bool> TemporaryUnblockAsync(string domain, TemporaryUnblockChoice choice) =>
        RunAsync(new Request(Command.TemporaryUnblock, Domain: domain, Password: choice.Password, Seconds: choice.WindowSeconds, StartSeconds: choice.StartSeconds), FeedbackScope.Site(domain));

    /// <summary>Cancels a pending unblock or a temporary unblock (waiting or open) so the site stays blocked. Needs no password.</summary>
    public Task<bool> CancelUnblockAsync(string domain) => RunAsync(new Request(Command.CancelUnblock, Domain: domain), FeedbackScope.Site(domain));

    /// <summary>Starts the unblock countdown for a blocked part of a site, named by its rule text. Returns true when the service accepted it.</summary>
    public Task<bool> UnblockPathAsync(string rule, string password) => RunAsync(new Request(Command.UnblockPath, Domain: rule, Password: password), FeedbackScope.Rule(rule));

    /// <summary>Schedules a temporary unblock of a blocked part of a site, like <see cref="TemporaryUnblockAsync"/>. Returns true when the service accepted it.</summary>
    public Task<bool> TemporaryUnblockPathAsync(string rule, TemporaryUnblockChoice choice) =>
        RunAsync(new Request(Command.TemporaryUnblockPath, Domain: rule, Password: choice.Password, Seconds: choice.WindowSeconds, StartSeconds: choice.StartSeconds), FeedbackScope.Rule(rule));

    /// <summary>Cancels a pending unblock or a temporary unblock of a blocked part of a site. Needs no password.</summary>
    public Task<bool> CancelUnblockPathAsync(string rule) => RunAsync(new Request(Command.CancelUnblockPath, Domain: rule), FeedbackScope.Rule(rule));

    /// <summary>Asks for a new unblock delay. A longer delay applies at once; a shorter one waits out the current delay first.</summary>
    public Task<bool> SetDelayAsync(long seconds, string password) => RunAsync(new Request(Command.SetDelay, Password: password, Seconds: seconds), FeedbackScope.Delay);

    /// <summary>Drops a requested shorter delay so the current one stays. Needs no password.</summary>
    public Task<bool> CancelDelayChangeAsync() => RunAsync(new Request(Command.CancelDelayChange), FeedbackScope.Banner);

    /// <summary>Replaces the password after the service checks the old one.</summary>
    public Task<bool> ChangePasswordAsync(string oldPassword, string newPassword) => RunAsync(new Request(Command.ChangePassword, Password: oldPassword, NewPassword: newPassword), FeedbackScope.Password);

    /// <summary>Sets the password: the first one, or a new one after a password reset cleared the old one. Returns true when the service accepted it.</summary>
    public Task<bool> SetupAsync(string password) => RunAsync(new Request(Command.Setup, Password: password), FeedbackScope.Setup);

    /// <summary>Starts the uninstall countdown. SiteBlock is removed when it ends unless it is cancelled first.</summary>
    public Task<bool> UninstallAsync(string password) => RunAsync(new Request(Command.Uninstall, Password: password), FeedbackScope.Uninstall);

    /// <summary>Cancels a pending uninstall. Needs no password.</summary>
    public Task<bool> CancelUninstallAsync() => RunAsync(new Request(Command.CancelUninstall), FeedbackScope.Banner);

    /// <summary>Cancels a running password reset. Needs no password.</summary>
    public Task<bool> CancelRecoveryAsync() => RunAsync(new Request(Command.RecoveryCancel), FeedbackScope.Banner);

    /// <summary>Sends one command, applies the status it returns, and shows the service's sentence next to the control in <paramref name="scope"/>. Returns true when the service said ok.</summary>
    private async Task<bool> RunAsync(Request request, FeedbackScope scope)
    {
        await _ui.InvokeAsync(BeginWork).ConfigureAwait(false);
        try
        {
            long order = NextRequestOrder();
            Reply reply = await PerformAsync(request).ConfigureAwait(false);
            if (reply.Response is { Ok: true } accepted)
            {
                await _ui.InvokeAsync(() =>
                {
                    if (accepted.Status is { } status) ApplyStatus(status, order, reply.ArrivedAt);
                    if (accepted.Message is { } message) Show(message, false, scope);
                }).ConfigureAwait(false);
                return true;
            }
            if (reply.Response is { } refused)
            {
                await _ui.InvokeAsync(() => Show(refused.Error ?? CommandRefusedText, true, scope)).ConfigureAwait(false);
                // A refusal carries no status, so ask again at once: a wrong password may just have started a lockout the panel should show.
                await RefreshAsync().ConfigureAwait(false);
                return false;
            }
            await _ui.InvokeAsync(() =>
            {
                Show(reply.FailureText!, true, scope);
                // Only "not running" means the connection is gone; a timeout on one command does not make the whole panel unusable.
                if (reply.ClientError == ClientError.NotRunning) ApplyFailure(reply.FailureText!, order);
            }).ConfigureAwait(false);
            return false;
        }
        finally
        {
            await _ui.InvokeAsync(EndWork).ConfigureAwait(false);
        }
    }

    /// <summary>Counts one more command in flight and marks the model busy. Runs on the dispatcher.</summary>
    private void BeginWork()
    {
        _commandsInFlight++;
        IsBusy = true;
    }

    /// <summary>Counts one command as finished and clears the busy flag when none is left. Runs on the dispatcher.</summary>
    private void EndWork()
    {
        _commandsInFlight = Math.Max(0, _commandsInFlight - 1);
        IsBusy = _commandsInFlight > 0;
    }

    // ---- Talking to the service ----

    /// <summary>The answer to one request: the response, or why none arrived, plus when it came back on the monotonic clock.</summary>
    private sealed record Reply(Response? Response, ClientError? ClientError, string? FailureText, long ArrivedAt);

    /// <summary>Hands out the next send-order number. The number is taken when the request is sent, so a reply to an older request can be recognised and ignored.</summary>
    private long NextRequestOrder() => Interlocked.Increment(ref _requestCounter);

    /// <summary>Sends one request and turns every outcome into a <see cref="Reply"/>; it never throws.</summary>
    private async Task<Reply> PerformAsync(Request request)
    {
        try
        {
            Response response = await _client.SendAsync(request).ConfigureAwait(false);
            return new Reply(response, null, null, _clock.MonotonicMilliseconds);
        }
        catch (DaemonClientException e)
        {
            return new Reply(null, e.Error, e.Message, _clock.MonotonicMilliseconds);
        }
        catch (Exception)
        {
            // Anything else (which the client should never throw) is shown as a general failure and does not mark the service as stopped.
            return new Reply(null, null, UnknownFailureText, _clock.MonotonicMilliseconds);
        }
    }

    /// <summary>
    /// Stores a fresh status and marks the service reachable, unless a newer reply was already applied. A status equal to the one shown is not stored again (and its arrival time is not kept), so the panel is not redrawn for nothing.
    /// Every applied status hands its path rules (minus those a temporary unblock has open) to the tab watcher. Runs on the dispatcher.
    /// </summary>
    private void ApplyStatus(StatusSnapshot status, long order, long arrivedAt)
    {
        // Two requests can be in flight at once. When the older one answers last, its data is out of date.
        if (order <= _lastAppliedRequest) return;
        _lastAppliedRequest = order;
        if (Connection.State != ConnectionState.Connected)
        {
            Connection = DaemonConnection.Connected;
            OnPropertyChanged(nameof(ServiceUnreachable));
        }
        if (status.Equals(Snapshot)) return;
        // The arrival time is set before the snapshot, so a view redrawing on the snapshot change already counts down from the right moment.
        SnapshotArrivedAt = arrivedAt;
        Snapshot = status;
        TabWatcher?.SetRules(status.WatchedPathRules);
    }

    /// <summary>Marks the service unreachable with the sentence that says why, unless a newer reply was already applied. Runs on the dispatcher.</summary>
    private void ApplyFailure(string text, long order)
    {
        if (order <= _lastAppliedRequest) return;
        _lastAppliedRequest = order;
        Connection = DaemonConnection.NotRunning(text);
        OnPropertyChanged(nameof(ServiceUnreachable));
    }

    // ---- Messages ----

    /// <summary>Shows a message in the given place and starts the timer that removes it. Runs on the dispatcher.</summary>
    private void Show(string text, bool isError, FeedbackScope scope)
    {
        int id = ++_feedbackCounter;
        Feedback = new Feedback(id, scope, text, isError);
        _ = ClearLaterAsync(id);
    }

    /// <summary>Waits <see cref="FeedbackDuration"/> and then removes the message with this id, if it is still the one on screen.</summary>
    private async Task ClearLaterAsync(int id)
    {
        try
        {
            await _clock.Delay(FeedbackDuration, CancellationToken.None).ConfigureAwait(false);
            await _ui.InvokeAsync(() => ClearFeedback(id)).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // A message that is never cleared is harmless; the next message or panel close replaces it.
        }
    }

    /// <summary>Removes the current message. With an id, removes it only when that message is still the one on screen, so an old timer cannot clear a newer message. Runs on the dispatcher.</summary>
    private void ClearFeedback(int? id)
    {
        if (id is not null && Feedback?.Id != id) return;
        Feedback = null;
    }
}
