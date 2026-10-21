using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;

namespace SiteBlock.Core;

/// <summary>The result of one real check of whether the family DNS servers answer.</summary>
/// <param name="Reachable">True when at least one family server answered.</param>
/// <param name="Detail">A short sentence about what happened, for diagnostic output.</param>
public sealed record FamilyDNSCheck(bool Reachable, string Detail);

/// <summary>
/// The real network check: sends one DNS query for example.com (type A) by UDP to port 53 of <c>1.1.1.3</c> and of <c>1.0.0.3</c> at the same time, then waits up to 2 seconds in total for whichever answers first.
/// A server counts as answering only when a packet comes back from it with that query's random ID and the QR (this is an answer) bit set. Because both are asked together, a check takes 2 seconds at the very most.
/// </summary>
public sealed class UdpFamilyDNSProbe
{
    /// <summary>One place a query is sent: an IPv4 address and a UDP port.</summary>
    /// <param name="Host">The IPv4 address as text, for example 1.1.1.3.</param>
    /// <param name="Port">The UDP port.</param>
    public sealed record Target(string Host, int Port);

    /// <summary>The two IPv4 family servers that are asked, on the DNS port 53.</summary>
    public static IReadOnlyList<Target> FamilyTargets { get; } = [new Target("1.1.1.3", 53), new Target("1.0.0.3", 53)];

    /// <summary>How long the servers get to answer, counted from when both queries are sent.</summary>
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(2);

    private readonly IReadOnlyList<Target> _targets;

    /// <summary>Creates the check. The installed service always uses the two family servers; another list (loopback addresses and ports) exists only so the check itself can be tried against stand-in servers.</summary>
    public UdpFamilyDNSProbe(IReadOnlyList<Target>? targets = null) => _targets = targets ?? FamilyTargets;

    /// <summary>
    /// Sends the query to every server and returns as soon as one valid answer arrives, or unreachable when none has arrived after 2 seconds (or every server refused the query).
    /// Cancelling <paramref name="ct"/> throws <see cref="OperationCanceledException"/> instead of reporting unreachable.
    /// </summary>
    public async Task<FamilyDNSCheck> CheckAsync(CancellationToken ct = default)
    {
        var clients = new List<UdpClient>();
        try
        {
            // The 2-second limit starts once the queries are being sent, and cancels every wait below when it runs out.
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
            deadline.CancelAfter(Timeout);
            var waiting = new List<Task<FamilyDNSCheck?>>();
            foreach (Target target in _targets)
            {
                (UdpClient Client, ushort Id)? sent = Send(target);
                if (sent is null) continue;
                clients.Add(sent.Value.Client);
                waiting.Add(WaitForAnswerAsync(sent.Value.Client, sent.Value.Id, target.Host, deadline.Token));
            }

            while (waiting.Count > 0)
            {
                Task<FamilyDNSCheck?> finished = await Task.WhenAny(waiting).ConfigureAwait(false);
                waiting.Remove(finished);
                FamilyDNSCheck? answer = await finished.ConfigureAwait(false);
                if (answer is null) continue;
                // One valid answer is enough; stop the other waits.
                deadline.Cancel();
                return answer;
            }
            ct.ThrowIfCancellationRequested();
            return new FamilyDNSCheck(false, $"neither {string.Join(" nor ", _targets.Select(t => t.Host))} answered within {(int)Timeout.TotalSeconds} seconds");
        }
        finally
        {
            foreach (UdpClient client in clients) client.Dispose();
        }
    }

    /// <summary>
    /// Opens a UDP socket, fixes its other end to the target (so the system drops datagrams from any other address) and sends one query with a fresh random ID.
    /// Returns null when any step fails, including an address that is not IPv4.
    /// </summary>
    private static (UdpClient Client, ushort Id)? Send(Target target)
    {
        // Only a literal IPv4 address is accepted, so no name lookup ever happens here.
        if (!IPAddress.TryParse(target.Host, out IPAddress? address) || address.AddressFamily != AddressFamily.InterNetwork) return null;
        UdpClient? client = null;
        try
        {
            client = new UdpClient(AddressFamily.InterNetwork);
            // Connect on a UDP socket sends nothing. It only fixes the other end.
            client.Connect(address, target.Port);
            // A random ID from the system generator, so a forged answer cannot guess it.
            ushort id = (ushort)RandomNumberGenerator.GetInt32(0, 65_536);
            byte[] query = DNSProbePacket.Query(id);
            if (client.Send(query, query.Length) != query.Length)
            {
                client.Dispose();
                return null;
            }
            return (client, id);
        }
        catch (Exception)
        {
            client?.Dispose();
            return null;
        }
    }

    /// <summary>Reads packets from one server until one is a valid answer to our query (returned), or time runs out, or the network reports an error for this server (null; the other server keeps going).</summary>
    private static async Task<FamilyDNSCheck?> WaitForAnswerAsync(UdpClient client, ushort id, string host, CancellationToken token)
    {
        while (true)
        {
            try
            {
                UdpReceiveResult result = await client.ReceiveAsync(token).ConfigureAwait(false);
                if (DNSProbePacket.IsAnswer(result.Buffer, id)) return new FamilyDNSCheck(true, $"{host} answered");
                // A stray or forged packet: keep waiting for the real answer.
            }
            catch (Exception)
            {
                // Time ran out, the check was cancelled, or the network refused the port: this server's attempt ends.
                return null;
            }
        }
    }
}

/// <summary>What one pass of <see cref="FamilyDNSProbe"/> did with the check result.</summary>
/// <param name="Published">The new answer when this pass changed or confirmed it, or null when a failure was held back because it was not yet the third in a row.</param>
/// <param name="Changed">True when the published answer differs from the one before it (the first answer counts as different).</param>
/// <param name="RetryAfter">How long to wait before checking again when a failure was held back, or null when the answer is settled.</param>
public sealed record FamilyDNSStep(bool? Published, bool Changed, TimeSpan? RetryAfter);

/// <summary>
/// Keeps the latest answer to "do the family DNS servers answer on this network?" and applies the rule that one lost reply must not flip it.
/// A success is taken at once. A failure only replaces the answer after three failures in a row, rechecked 5 seconds apart; until then the previous answer (or "unknown") stands.
/// Checks never overlap. The network check itself is a constructor parameter so the rule can be tested without a network; by default it is the real UDP check.
/// </summary>
public sealed class FamilyDNSProbe
{
    /// <summary>How many failed checks in a row count as "unreachable".</summary>
    public const int DefaultFailuresBeforeUnreachable = 3;

    /// <summary>How long to wait before rechecking after a failure that did not yet change the answer.</summary>
    public static readonly TimeSpan DefaultRetryInterval = TimeSpan.FromSeconds(5);

    private readonly Func<CancellationToken, Task<bool>> _checkOnce;
    private readonly string? _delayFilePath;
    private readonly int _failuresBeforeUnreachable;
    private readonly TimeSpan _retryInterval;
    private readonly Func<TimeSpan, CancellationToken, Task> _wait;
    // Checks run one at a time, like Swift's single background queue.
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly object _lock = new();
    private bool? _latest;
    private int _consecutiveFailures;
    // True between a call to ProbeNowAsync and the moment its check starts, so a burst of network-change notices queues one check, not many.
    private bool _checkQueued;

    /// <summary>
    /// Creates the probe.
    /// <paramref name="checkOnce"/> makes one network check and says whether a family server answered; it defaults to the real UDP check.
    /// <paramref name="delayFilePath"/> is the sandbox hook: when the file exists and holds a number of seconds, every check takes that long (at most 10), so tests can show that a slow check never holds anything up.
    /// <paramref name="failuresBeforeUnreachable"/> and <paramref name="retryInterval"/> change the failure rule (3 and 5 seconds by default), and <paramref name="wait"/> replaces the real waiting so tests need no real time.
    /// </summary>
    public FamilyDNSProbe(Func<CancellationToken, Task<bool>>? checkOnce = null, string? delayFilePath = null, int failuresBeforeUnreachable = DefaultFailuresBeforeUnreachable, TimeSpan? retryInterval = null, Func<TimeSpan, CancellationToken, Task>? wait = null)
    {
        UdpFamilyDNSProbe udp = new();
        _checkOnce = checkOnce ?? (async ct => (await udp.CheckAsync(ct).ConfigureAwait(false)).Reachable);
        _delayFilePath = delayFilePath;
        _failuresBeforeUnreachable = Math.Max(1, failuresBeforeUnreachable);
        _retryInterval = retryInterval ?? DefaultRetryInterval;
        _wait = wait ?? ((span, ct) => Task.Delay(span, ct));
    }

    /// <summary>The sandbox stand-in for the network: the family servers count as unreachable exactly while the marker file exists (looked at on every check), and the optional delay file slows each check.</summary>
    public static FamilyDNSProbe ForSandbox(string markerPath, string? delayFilePath = null) =>
        new(_ => Task.FromResult(!File.Exists(markerPath)), delayFilePath);

    /// <summary>The latest published answer, or null while no check has finished (the "unknown" state, in which the DNS enforcer leaves settings as they are). Safe to read from any thread.</summary>
    public bool? Latest
    {
        get { lock (_lock) return _latest; }
    }

    /// <summary>Raised with the new answer whenever the published answer differs from the one before it. The first answer counts as different.</summary>
    public event Action<bool>? Changed;

    /// <summary>
    /// Runs one check and applies the failure rule. A success is published at once. A failure is published only when it is the third in a row (or later);
    /// otherwise nothing is published and the result says how long to wait before the next try.
    /// </summary>
    public async Task<FamilyDNSStep> RunOnceAsync(CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            lock (_lock) _checkQueued = false;
            bool reachable = await CheckWithDelayAsync(ct).ConfigureAwait(false);
            // A check that finished after the caller asked to stop must not publish anything.
            ct.ThrowIfCancellationRequested();

            bool changed = false;
            bool? published = null;
            TimeSpan? retryAfter = null;
            lock (_lock)
            {
                bool? previous = _latest;
                if (reachable) _consecutiveFailures = 0;
                else _consecutiveFailures++;

                if (reachable || _consecutiveFailures >= _failuresBeforeUnreachable)
                {
                    _latest = reachable;
                    published = reachable;
                    changed = previous != reachable;
                }
                else
                {
                    retryAfter = _retryInterval;
                }
            }
            if (changed) Changed?.Invoke(reachable);
            return new FamilyDNSStep(published, changed, retryAfter);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Checks again and again, waiting out the retry interval after each held-back failure, until an answer is published, then returns that answer.</summary>
    public async Task<bool> CheckSettledAsync(CancellationToken ct = default)
    {
        while (true)
        {
            FamilyDNSStep step = await RunOnceAsync(ct).ConfigureAwait(false);
            if (step.RetryAfter is null) return step.Published ?? Latest ?? false;
            await _wait(step.RetryAfter.Value, ct).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Asks for a check right away (the service calls this when Windows reports a network change), unless one is already waiting to start, in which case it returns the current answer.
    /// </summary>
    public async Task<bool?> ProbeNowAsync(CancellationToken ct = default)
    {
        lock (_lock)
        {
            if (_checkQueued) return _latest;
            _checkQueued = true;
        }
        return await CheckSettledAsync(ct).ConfigureAwait(false);
    }

    /// <summary>Runs a settled check now and then every <paramref name="interval"/> until cancelled (30 seconds in the installed service). Returns when <paramref name="ct"/> is cancelled.</summary>
    public async Task RunPeriodicAsync(TimeSpan interval, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                await CheckSettledAsync(ct).ConfigureAwait(false);
                await _wait(interval, ct).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            // Stopping is the normal way out.
        }
    }

    /// <summary>
    /// Makes one network check, then applies the sandbox delay. The check runs first so a test that changes the marker file while a slow check is waiting sees the answer from when the check started.
    /// An error from the check itself counts as "no answer", because a broken network call is a failed check, not a reason to crash the service.
    /// </summary>
    private async Task<bool> CheckWithDelayAsync(CancellationToken ct)
    {
        bool reachable;
        try
        {
            reachable = await _checkOnce(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            reachable = false;
        }
        TimeSpan? delay = ReadDelay();
        if (delay is not null) await Task.Delay(delay.Value, ct).ConfigureAwait(false);
        return reachable;
    }

    /// <summary>Reads the sandbox delay file: a number of seconds, capped at 10, or null when there is no file, no number, or the number is not above zero.</summary>
    private TimeSpan? ReadDelay()
    {
        if (_delayFilePath is null) return null;
        try
        {
            if (!double.TryParse(File.ReadAllText(_delayFilePath).Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out double seconds)) return null;
            return seconds > 0 ? TimeSpan.FromSeconds(Math.Min(seconds, 10)) : null;
        }
        catch (Exception)
        {
            return null;
        }
    }
}
