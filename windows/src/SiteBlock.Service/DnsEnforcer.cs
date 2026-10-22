using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using SiteBlock.Core;

namespace SiteBlock.Service;

/// <summary>Empties the Windows DNS Client's cache, so a change to the hosts file or the DNS servers takes effect at once.</summary>
public static class DnsCache
{
    /// <summary>Calls DnsFlushResolverCache. Does nothing off Windows, and a failure is ignored: a stale cache entry expires on its own.</summary>
    public static void Flush()
    {
        if (!OperatingSystem.IsWindows()) return;
        try { DnsFlushResolverCache(); } catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException) { }
    }

    [DllImport("dnsapi.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DnsFlushResolverCache();
}

/// <summary>
/// Keeps every network adapter's DNS servers on Cloudflare for Families for as long as SiteBlock is installed, and lets the uninstaller put the original servers back
/// (03-daemon-cli-app.md § DNSEnforcer, 06-windows.md § DNSEnforcer). The family servers are used only while they answer on the current network, and a change is kept only when it can be read back.
/// <see cref="Enforce"/> must be called on the engine thread; the monitoring runs on its own threads and only asks for a pass.
/// </summary>
public sealed class DnsEnforcer : IDnsEnforcer
{
    /// <summary>The servers every managed adapter is set to: Cloudflare for Families, two IPv4 and two IPv6 addresses.</summary>
    public static readonly IReadOnlyList<string> FamilyServers = ["1.1.1.3", "1.0.0.3", "2606:4700:4700::1113", "2606:4700:4700::1003"];
    /// <summary>How often the fallback pass and the reachability check run in the installed service.</summary>
    public static readonly TimeSpan ProductionMonitorInterval = TimeSpan.FromSeconds(30);

    // A failure message that repeats is logged at most this often (milliseconds).
    private const long RepeatedFailureLogIntervalMs = 60_000;
    // After a change to an adapter could not be read back, that adapter is left alone this long (10 minutes, in milliseconds), so a backend that ignores writes is never retried in a loop.
    private const long RetryPauseMs = 600_000;
    // After a change notice, wait this long before reacting, so the several notices one change produces cause one pass.
    private static readonly TimeSpan SettleDelay = TimeSpan.FromMilliseconds(300);

    private readonly IDnsSettingsBackend _backend;
    private readonly FamilyDNSProbe _probe;
    private readonly Log _log;
    private readonly bool _sandbox;
    private readonly TimeSpan _monitorInterval;
    private (string Message, long At)? _lastFailure;
    // Whether the last pass found the family servers answering; null before the first. Used to log a change of state once.
    private bool? _familyReachable;
    // For each adapter whose change did not take effect, the time (TickCount64) before which it is not tried again.
    private readonly Dictionary<string, long> _retryNotBefore = new(StringComparer.OrdinalIgnoreCase);

    private CancellationTokenSource? _monitoring;
    private Timer? _fallbackTimer;
    private Action? _schedulePass;
    private NetworkAddressChangedEventHandler? _networkHandler;
    // The Windows registry watch, held as IDisposable so the code that stops it builds on every system.
    private IDisposable? _registryWatcher;
    // 1 while a settle delay after a network change is running, so a burst of notices causes one check and one pass.
    private int _settling;

    /// <summary>
    /// Creates an enforcer over a backend and a reachability probe. <paramref name="sandbox"/> turns off the DNS cache flush and the Windows change notices.
    /// <paramref name="monitorInterval"/> is how often the reachability check and the fallback pass run.
    /// </summary>
    public DnsEnforcer(IDnsSettingsBackend backend, FamilyDNSProbe probe, Log log, bool sandbox, TimeSpan monitorInterval)
    {
        _backend = backend;
        _probe = probe;
        _log = log;
        _sandbox = sandbox;
        _monitorInterval = monitorInterval;
    }

    /// <summary>
    /// Builds the enforcer for these paths. A sandbox reads network-services.json, counts the family servers as unreachable while the marker file exists, and checks once per tick
    /// (retrying after a failure once per tick too). The installed service uses the real adapters, real DNS queries and a 30-second check.
    /// </summary>
    public static DnsEnforcer Create(Paths paths, Log log, TimeSpan tickInterval)
    {
        if (paths.IsSandbox || !OperatingSystem.IsWindows())
        {
            var probe = new FamilyDNSProbe(_ => Task.FromResult(!File.Exists(paths.FamilyDnsUnreachableMarker)), paths.FamilyDnsProbeDelayFile, retryInterval: tickInterval);
            return new DnsEnforcer(new FileDnsBackend(paths.NetworkServicesFile), probe, log, sandbox: true, tickInterval);
        }
        return new DnsEnforcer(new WindowsDnsBackend(), new FamilyDNSProbe(), log, sandbox: false, ProductionMonitorInterval);
    }

    /// <summary>The latest reachability answer: true or false, or null before the first check has finished.</summary>
    public bool? FamilyReachable => _probe.Latest;

    /// <inheritdoc />
    public Dictionary<string, List<string>>? Enforce(bool adultFilterActive, IReadOnlyDictionary<string, List<string>>? savedDNS, Func<Dictionary<string, List<string>>?, bool> persist)
    {
        var saved = savedDNS?.ToDictionary(entry => entry.Key, entry => entry.Value.ToList(), StringComparer.OrdinalIgnoreCase) ?? new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        return adultFilterActive ? SetFamilyServers(saved, persist) : RestoreOriginals(saved, persist);
    }

    /// <summary>
    /// The filter-on half of a pass. With no reachability answer yet it changes nothing. While the family servers answer, every managed adapter that does not have exactly them gets them,
    /// after its current servers are recorded (through <paramref name="persist"/>, before anything is written). While they do not answer, adapters already set get their recorded servers back.
    /// </summary>
    private Dictionary<string, List<string>>? SetFamilyServers(Dictionary<string, List<string>> saved, Func<Dictionary<string, List<string>>?, bool> persist)
    {
        // Unknown: the first check has not finished. Changing the servers now could break the PC's DNS, so nothing changes until the answer arrives (which schedules a pass).
        if (_probe.Latest is not bool reachable) return saved;
        IReadOnlyList<DnsAdapter> adapters;
        try
        {
            adapters = _backend.ReadAdapters();
        }
        catch (IOException error)
        {
            LogFailure($"DNS settings could not be read: {error.Message}");
            return saved;
        }
        long now = Environment.TickCount64;
        var managed = adapters.Where(adapter => adapter.IsManaged).ToList();
        var overridden = managed.Where(adapter => saved.ContainsKey(adapter.Id) && IsFamily(adapter)).ToList();
        var candidates = managed.Where(adapter => !IsFamily(adapter) && !(_retryNotBefore.TryGetValue(adapter.Id, out long notBefore) && notBefore > now)).ToList();
        // Nothing to set and nothing set: the steady state writes nothing at all.
        if (overridden.Count == 0 && candidates.Count == 0)
        {
            _lastFailure = null;
            return saved;
        }

        if (!reachable)
        {
            if (_familyReachable != false) _log.Write("family DNS unreachable; using the network's own DNS until it answers");
            _familyReachable = false;
            PutOriginalsBack(overridden, saved);
            return saved;
        }
        bool recovering = _familyReachable == false;
        _familyReachable = true;

        var record = saved.ToDictionary(entry => entry.Key, entry => entry.Value.ToList(), StringComparer.OrdinalIgnoreCase);
        var changes = new Dictionary<string, IReadOnlyList<string>>(StringComparer.OrdinalIgnoreCase);
        bool repaired = false;
        foreach (var adapter in candidates)
        {
            // An adapter SiteBlock already overrode keeps its first recorded value, so a hand edit never replaces the real original.
            if (!record.ContainsKey(adapter.Id)) record[adapter.Id] = [.. adapter.Servers];
            else repaired = true;
            changes[adapter.Id] = Wanted(adapter);
        }
        if (changes.Count == 0)
        {
            _lastFailure = null;
            return saved;
        }
        // The originals are written down before they are replaced. If they cannot be saved, nothing changes and the next pass tries again.
        if (record.Count != saved.Count && !persist(record))
        {
            LogFailure("DNS settings not changed: the original servers could not be saved first");
            return saved;
        }

        // Each adapter is written on its own, so one that refuses the change (and is paused for 10 minutes) never stops the others or loops on every change notice.
        var failed = new List<string>();
        var written = new Dictionary<string, IReadOnlyList<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var (id, servers) in changes)
        {
            try
            {
                _backend.Apply(new Dictionary<string, IReadOnlyList<string>>(StringComparer.OrdinalIgnoreCase) { [id] = servers });
                written[id] = servers;
            }
            catch (IOException error)
            {
                LogFailure($"DNS settings could not be changed: {error.Message}");
                failed.Add(id);
            }
        }
        if (failed.Count == 0) _lastFailure = null;

        // Read the settings back. An adapter that does not hold what was just written is added to the failures.
        failed.AddRange(AdaptersThatDidNotTakeTheChange(written));
        // Every failed adapter gets its original back and is left alone for 10 minutes.
        foreach (string id in failed.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try { _backend.Apply(new Dictionary<string, IReadOnlyList<string>>(StringComparer.OrdinalIgnoreCase) { [id] = record.GetValueOrDefault(id) ?? [] }); }
            catch (IOException error) { LogFailure($"DNS settings could not be put back after a change that did not take effect: {error.Message}"); }
            _retryNotBefore[id] = Environment.TickCount64 + RetryPauseMs;
            string name = candidates.FirstOrDefault(adapter => adapter.Id.Equals(id, StringComparison.OrdinalIgnoreCase))?.Name ?? id;
            _log.Write($"DNS change did not take effect for {name}; left the network's DNS in place");
        }
        int applied = changes.Count - failed.Distinct(StringComparer.OrdinalIgnoreCase).Count();
        if (applied == 0) return record;
        if (!_sandbox) DnsCache.Flush();
        string adaptersText = $"{applied} network {(applied == 1 ? "service" : "services")}";
        if (recovering) _log.Write($"family DNS answers again; DNS settings set to the family servers for {adaptersText}");
        else if (!repaired) _log.Write($"DNS settings set to the family servers for {adaptersText}");
        else _log.Write("DNS settings repaired");
        return record;
    }

    /// <summary>The family servers this adapter should hold: all four, or only the two IPv4 servers on an adapter without IPv6.</summary>
    internal static IReadOnlyList<string> Wanted(DnsAdapter adapter) => adapter.HasIpv6 ? FamilyServers : [.. FamilyServers.Where(server => !server.Contains(':'))];

    /// <summary>True when the adapter holds exactly the family servers it should, in order.</summary>
    private static bool IsFamily(DnsAdapter adapter) => adapter.Servers.SequenceEqual(Wanted(adapter), StringComparer.OrdinalIgnoreCase);

    /// <summary>Reads the adapters back and returns the IDs of those that do not hold the servers just written for them (including adapters that disappeared or could not be read).</summary>
    private List<string> AdaptersThatDidNotTakeTheChange(IReadOnlyDictionary<string, IReadOnlyList<string>> written)
    {
        IReadOnlyList<DnsAdapter> current;
        try { current = _backend.ReadAdapters(); }
        catch (IOException) { current = []; }
        return [.. written.Keys.Order(StringComparer.Ordinal).Where(id =>
        {
            var adapter = current.FirstOrDefault(item => item.Id.Equals(id, StringComparison.OrdinalIgnoreCase));
            return adapter is null || !adapter.Servers.SequenceEqual(written[id], StringComparer.OrdinalIgnoreCase);
        })];
    }

    /// <summary>While the family servers do not answer: gives each overridden adapter its recorded servers back. The record is kept, so the family servers return as soon as they answer.</summary>
    private void PutOriginalsBack(List<DnsAdapter> overridden, Dictionary<string, List<string>> saved)
    {
        if (overridden.Count == 0)
        {
            _lastFailure = null;
            return;
        }
        var back = overridden.ToDictionary(adapter => adapter.Id, adapter => (IReadOnlyList<string>)saved[adapter.Id], StringComparer.OrdinalIgnoreCase);
        var failed = ApplyEach(back, "DNS settings could not be put back while the family servers are unreachable");
        if (failed.Count == 0) _lastFailure = null;
        if (failed.Count < back.Count && !_sandbox) DnsCache.Flush();
    }

    /// <summary>
    /// Writes each adapter's servers on its own, so one adapter that refuses never stops the others, and returns the IDs of those that failed. Each failure is logged (at most once a minute
    /// for the same message) with the given lead sentence.
    /// </summary>
    private List<string> ApplyEach(IReadOnlyDictionary<string, IReadOnlyList<string>> changes, string failureLead)
    {
        var failed = new List<string>();
        foreach (var (id, servers) in changes)
        {
            try
            {
                _backend.Apply(new Dictionary<string, IReadOnlyList<string>>(StringComparer.OrdinalIgnoreCase) { [id] = servers });
            }
            catch (IOException error)
            {
                LogFailure($"{failureLead}: {error.Message}");
                failed.Add(id);
            }
        }
        return failed;
    }

    /// <summary>The uninstall half of a pass: every recorded adapter that still exists gets its original servers back, then the record is cleared through <paramref name="persist"/>. A failed restore keeps the record.</summary>
    private Dictionary<string, List<string>>? RestoreOriginals(Dictionary<string, List<string>> saved, Func<Dictionary<string, List<string>>?, bool> persist)
    {
        if (saved.Count == 0) return null;
        IReadOnlyList<DnsAdapter> adapters;
        try
        {
            adapters = _backend.ReadAdapters();
        }
        catch (IOException error)
        {
            LogFailure($"DNS settings could not be read: {error.Message}");
            return saved;
        }
        // An adapter that was removed has nothing to restore, and one that already has its original servers needs no write.
        var changes = new Dictionary<string, IReadOnlyList<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var adapter in adapters)
        {
            if (saved.TryGetValue(adapter.Id, out var original) && !adapter.Servers.SequenceEqual(original, StringComparer.OrdinalIgnoreCase)) changes[adapter.Id] = original;
        }
        if (changes.Count > 0)
        {
            // Every adapter is tried, so one that refuses does not keep the others on the family servers after the uninstall.
            var failed = ApplyEach(changes, "DNS settings could not be restored");
            int restored = changes.Count - failed.Count;
            if (restored > 0)
            {
                if (!_sandbox) DnsCache.Flush();
                _log.Write($"DNS settings restored for {restored} network {(restored == 1 ? "service" : "services")}");
            }
            // The record stays while any adapter still lacks its originals, so a retry can restore it.
            if (failed.Count > 0) return saved;
        }
        _lastFailure = null;
        if (!persist(null)) LogFailure("DNS settings restored, but the saved record could not be cleared");
        return null;
    }

    /// <summary>Logs a failure message unless the same message was logged within the last minute.</summary>
    private void LogFailure(string message)
    {
        long now = Environment.TickCount64;
        if (_lastFailure is { } last && last.Message == message && now - last.At < RepeatedFailureLogIntervalMs) return;
        _lastFailure = (message, now);
        _log.Write(message);
    }

    // MARK: Monitoring

    /// <summary>
    /// Starts the reachability check (at once, then every monitor interval), a fallback pass on the same interval, and in production the Windows change notices: an address change,
    /// or an edit under the adapters' TCP/IP settings keys, starts a new reachability check and a pass within about a second. A changed reachability answer also asks for a pass.
    /// </summary>
    public void StartMonitoring(Action schedulePass)
    {
        if (_monitoring is not null) return;
        _monitoring = new CancellationTokenSource();
        _schedulePass = schedulePass;
        _probe.Changed += OnReachabilityChanged;
        var token = _monitoring.Token;
        _ = Task.Run(() => _probe.RunPeriodicAsync(_monitorInterval, token));
        _fallbackTimer = new Timer(_ => schedulePass(), null, _monitorInterval, _monitorInterval);
        if (_sandbox || !OperatingSystem.IsWindows()) return;
        _networkHandler = (_, _) => OnNetworkChanged();
        NetworkChange.NetworkAddressChanged += _networkHandler;
        try
        {
            _registryWatcher = new RegistryChangeWatcher([WindowsDnsBackend.Ipv4InterfacesKey, WindowsDnsBackend.Ipv6InterfacesKey], OnNetworkChanged);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            _log.Write($"DNS change notices could not be started; relying on the {(int)_monitorInterval.TotalSeconds} second check");
        }
    }

    /// <inheritdoc />
    public void StopMonitoring()
    {
        _monitoring?.Cancel();
        _probe.Changed -= OnReachabilityChanged;
        _fallbackTimer?.Dispose();
        _fallbackTimer = null;
        if (_networkHandler is not null) NetworkChange.NetworkAddressChanged -= _networkHandler;
        _networkHandler = null;
        _registryWatcher?.Dispose();
        _registryWatcher = null;
    }

    /// <summary>Called on the probe's thread when the reachability answer changes (the first answer counts as a change): asks for a pass.</summary>
    private void OnReachabilityChanged(bool reachable)
    {
        if (_monitoring is { IsCancellationRequested: false }) _schedulePass?.Invoke();
    }

    /// <summary>
    /// Called on a notification thread when Windows reports an address change or a DNS setting is edited: after a short settle delay it starts a new reachability check and asks for a pass,
    /// which repairs a hand edit from the stored answer at once. A burst of notices is folded into one.
    /// </summary>
    private void OnNetworkChanged()
    {
        if (_monitoring is not { IsCancellationRequested: false } monitoring) return;
        if (Interlocked.Exchange(ref _settling, 1) == 1) return;
        var token = monitoring.Token;
        _ = Task.Delay(SettleDelay, token).ContinueWith(settled =>
        {
            Volatile.Write(ref _settling, 0);
            if (token.IsCancellationRequested) return;
            // The check's own failure is read here so it never surfaces as an unobserved task exception; the probe already counts a failed check as "no answer".
            _ = _probe.ProbeNowAsync(token).ContinueWith(task => { _ = task.Exception; }, TaskScheduler.Default);
            _schedulePass?.Invoke();
        }, TaskScheduler.Default);
    }
}

/// <summary>
/// Watches registry keys under HKEY_LOCAL_MACHINE, and everything below them, for changed or added values with RegNotifyChangeKeyValue, and calls a function on its own thread after each change.
/// Windows only. Used for the adapters' TCP/IP settings keys, so a hand edit of an adapter's DNS servers is noticed at once.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed class RegistryChangeWatcher : IDisposable
{
    // REG_NOTIFY_CHANGE_NAME | REG_NOTIFY_CHANGE_LAST_SET: a subkey added or removed, or a value changed.
    private const int NotifyFilter = 0x1 | 0x4;

    private readonly List<RegistryKey> _keys = [];
    private readonly List<AutoResetEvent> _events = [];
    private readonly ManualResetEvent _stop = new(false);
    private readonly Thread _thread;
    private readonly Action _onChange;

    /// <summary>Opens each key that exists (a PC without IPv6 has no Tcpip6 key, which must not stop the IPv4 watch) and starts the watching thread. Throws when none can be opened.</summary>
    public RegistryChangeWatcher(IReadOnlyList<string> keyPaths, Action onChange)
    {
        _onChange = onChange;
        using var root = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        foreach (string path in keyPaths)
        {
            var key = root.OpenSubKey(path, RegistryKeyPermissionCheck.ReadSubTree, System.Security.AccessControl.RegistryRights.Notify | System.Security.AccessControl.RegistryRights.ReadKey);
            if (key is null) continue;
            _keys.Add(key);
            _events.Add(new AutoResetEvent(false));
        }
        if (_keys.Count == 0) throw new IOException("none of the watched registry keys could be opened");
        _thread = new Thread(Loop) { IsBackground = true, Name = "siteblockd.dns-registry-watch" };
        _thread.Start();
    }

    /// <summary>Arms one notice per key, waits for any of them or the stop signal, reports a change, and arms again. A notice fires once, so it is re-armed after each one.</summary>
    private void Loop()
    {
        // The keys whose notice is armed. A key whose notice cannot be armed would never fire, so it is dropped; the 30-second fallback pass still covers it.
        var active = Enumerable.Range(0, _keys.Count).Where(Arm).ToList();
        while (active.Count > 0)
        {
            WaitHandle[] handles = [_stop, .. active.Select(key => _events[key])];
            int index = WaitHandle.WaitAny(handles);
            if (index == 0) return;
            int fired = active[index - 1];
            if (!Arm(fired)) active.Remove(fired);
            try { _onChange(); } catch (Exception) { }
        }
    }

    /// <summary>Asks Windows to signal the key's event at its next change, including changes in its subkeys. Returns false when Windows refuses.</summary>
    private bool Arm(int index) => RegNotifyChangeKeyValue(_keys[index].Handle, true, NotifyFilter, _events[index].SafeWaitHandle, true) == 0;

    /// <summary>Stops the thread and closes the keys.</summary>
    public void Dispose()
    {
        _stop.Set();
        _thread.Join(TimeSpan.FromSeconds(2));
        foreach (var key in _keys) key.Dispose();
        foreach (var signal in _events) signal.Dispose();
        _stop.Dispose();
    }

    [DllImport("advapi32.dll")]
    private static extern int RegNotifyChangeKeyValue(SafeRegistryHandle key, [MarshalAs(UnmanagedType.Bool)] bool watchSubtree, int notifyFilter, SafeWaitHandle eventHandle, [MarshalAs(UnmanagedType.Bool)] bool asynchronous);
}

/// <summary>
/// The read-only report <c>siteblockd --print-dns-plan</c> prints: what SiteBlock found on each adapter and what it would do. It reads the adapters and runs one reachability check,
/// never changes anything and needs no administrator rights.
/// </summary>
public static class DnsPlan
{
    /// <summary>Builds the report for these paths (the real adapters and a real check, or the sandbox stand-ins). Throws <see cref="IOException"/> when the adapters cannot be read.</summary>
    public static string Text(Paths paths)
    {
        bool sandbox = paths.IsSandbox || !OperatingSystem.IsWindows();
        IDnsSettingsBackend backend = !paths.IsSandbox && OperatingSystem.IsWindows() ? new WindowsDnsBackend() : new FileDnsBackend(paths.NetworkServicesFile);
        var adapters = backend.ReadAdapters();
        FamilyDNSCheck check = sandbox
            ? (File.Exists(paths.FamilyDnsUnreachableMarker)
                ? new FamilyDNSCheck(false, "pretending the family servers do not answer (the sandbox marker file exists)")
                : new FamilyDNSCheck(true, "pretending the family servers answer (sandbox)"))
            : new UdpFamilyDNSProbe().CheckAsync().GetAwaiter().GetResult();
        var lines = new List<string>
        {
            "SiteBlock DNS plan (read-only: nothing was changed)",
            sandbox ? $"Mode: sandbox ({paths.NetworkServicesFile})" : "Mode: this PC's real network settings",
            $"Family DNS reachability: {(check.Reachable ? "reachable" : "UNREACHABLE")} ({check.Detail})",
            $"Family servers: {string.Join(", ", DnsEnforcer.FamilyServers)}",
            $"Network adapters: {adapters.Count}",
        };
        foreach (var adapter in adapters)
        {
            lines.Add($"- {adapter.Id}");
            lines.Add($"    name: {adapter.Name}");
            lines.Add($"    interface type: {adapter.InterfaceType}");
            if (adapter.Description.Length > 0) lines.Add($"    description: {adapter.Description}");
            lines.Add($"    enabled: {(adapter.IsEnabled ? "yes" : "no")}");
            lines.Add($"    skipped: {(adapter.SkipReason is string reason ? $"yes, {reason}" : "no")}");
            lines.Add($"    current servers: {(adapter.Servers.Count == 0 ? "(none set by hand; the network's own DNS is used)" : string.Join(", ", adapter.Servers))}");
            lines.Add($"    SiteBlock would set: {WouldSet(adapter, check)}");
        }
        return string.Join("\n", lines) + "\n";
    }

    /// <summary>Describes what a pass would do to one adapter right now.</summary>
    private static string WouldSet(DnsAdapter adapter, FamilyDNSCheck check)
    {
        if (adapter.SkipReason is string reason) return $"nothing ({reason})";
        if (adapter.Servers.SequenceEqual(DnsEnforcer.Wanted(adapter), StringComparer.OrdinalIgnoreCase))
        {
            return check.Reachable ? "nothing (already the family servers)" : "its saved servers back (the family servers do not answer); the saved servers are in SiteBlock's state, which this report does not read";
        }
        if (!check.Reachable) return "nothing (the family servers do not answer on this network, so the network's own DNS stays)";
        return $"{string.Join(", ", DnsEnforcer.Wanted(adapter))} (the current servers would be saved first)";
    }
}
