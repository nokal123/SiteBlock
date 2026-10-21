using SiteBlock.Core;

namespace SiteBlock.AppLogic;

/// <summary>The production <see cref="IDaemonClient"/>: passes each request to Core's <see cref="DaemonClient"/>, which talks over the named pipe.</summary>
public sealed class CoreDaemonClient : IDaemonClient
{
    private readonly DaemonClient _client;

    /// <summary>Wraps <paramref name="client"/>, or a client for the installed service's pipe (or SITEBLOCK_PIPE when it is set) when none is given.</summary>
    public CoreDaemonClient(DaemonClient? client = null) => _client = client ?? new DaemonClient();

    /// <summary>Sends the request on a pool thread, so a window's thread never waits on the pipe. Failures arrive as <see cref="DaemonClientException"/>.</summary>
    public Task<Response> SendAsync(Request request, CancellationToken ct = default) => Task.Run(() => _client.SendAsync(request, ct), ct);
}

/// <summary>The real clock: <see cref="Environment.TickCount64"/> for countdowns (it keeps counting while the PC sleeps and cannot be changed by the person) and the system time for the schedule line.</summary>
public sealed class SystemClock : IClock
{
    /// <summary>The one shared instance.</summary>
    public static SystemClock Instance { get; } = new();

    /// <summary>Milliseconds since Windows started.</summary>
    public long MonotonicMilliseconds => Environment.TickCount64;

    /// <summary>The current local time.</summary>
    public DateTimeOffset Now => DateTimeOffset.Now;

    /// <summary>Waits with <see cref="Task.Delay(TimeSpan, CancellationToken)"/>.</summary>
    public Task Delay(TimeSpan delay, CancellationToken ct) => Task.Delay(delay, ct);
}

/// <summary>Runs work on the thread of a <see cref="SynchronizationContext"/> (in the app, WPF's dispatcher context). Work requested from that thread runs at once; work from other threads is posted.</summary>
public sealed class SynchronizationContextDispatcher : IUiDispatcher
{
    private readonly SynchronizationContext _context;
    private readonly int _threadId;

    /// <summary>Captures <paramref name="context"/>. It must be created on the context's own thread, so the dispatcher knows which thread may run work at once.</summary>
    public SynchronizationContextDispatcher(SynchronizationContext context)
    {
        _context = context ?? throw new ArgumentNullException(nameof(context));
        _threadId = Environment.CurrentManagedThreadId;
    }

    /// <summary>Runs the action now when already on the context's thread, otherwise posts it there and completes when it has run (or faults with its exception).</summary>
    public Task InvokeAsync(Action action)
    {
        ArgumentNullException.ThrowIfNull(action);
        if (Environment.CurrentManagedThreadId == _threadId)
        {
            action();
            return Task.CompletedTask;
        }
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _context.Post(_ =>
        {
            try
            {
                action();
                done.SetResult();
            }
            catch (Exception e)
            {
                done.SetException(e);
            }
        }, null);
        return done.Task;
    }
}

/// <summary>The dispatcher for tests and other code with no screen thread: it runs each action at once on the calling thread, one at a time.</summary>
public sealed class InlineUiDispatcher : IUiDispatcher
{
    private readonly Lock _gate = new();

    /// <summary>Runs the action now, holding a lock so two threads never change a model at the same moment.</summary>
    public Task InvokeAsync(Action action)
    {
        ArgumentNullException.ThrowIfNull(action);
        lock (_gate) action();
        return Task.CompletedTask;
    }
}

/// <summary>A dismissed-update store that keeps the value only in memory, for tests and for systems without the registry.</summary>
public sealed class InMemoryDismissedUpdateStore : IDismissedUpdateStore
{
    private int _build;

    /// <summary>Starts with <paramref name="build"/> stored (0 means nothing).</summary>
    public InMemoryDismissedUpdateStore(int build = 0) => _build = build;

    /// <summary>The stored build, or 0.</summary>
    public int Load() => _build;

    /// <summary>Stores the build.</summary>
    public void Save(int build) => _build = build;

    /// <summary>Forgets the build.</summary>
    public void Clear() => _build = 0;
}

/// <summary>A log that throws every line away.</summary>
public sealed class NullAppLog : IAppLog
{
    /// <summary>The one shared instance.</summary>
    public static NullAppLog Instance { get; } = new();

    /// <summary>Does nothing.</summary>
    public void Info(string message) { }
}
