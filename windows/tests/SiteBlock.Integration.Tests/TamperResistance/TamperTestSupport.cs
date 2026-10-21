using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.TamperResistance;

// A throwaway sandbox folder with a Paths pointing into it and a probe log. Deletes the folder on Dispose.
internal sealed class TempSandbox : IDisposable
{
    public string Root { get; }
    public Paths Paths { get; }
    public string LogPath { get; }
    public Log Log { get; }

    // isSandbox=false builds a non-sandbox Paths whose files still live under the temp folder, so the guards' real (non-sandbox) decision trees can be driven without touching the real machine.
    public TempSandbox(bool isSandbox = true)
    {
        Root = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "sbtamper-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Root);
        var sandboxPaths = Paths.Sandbox(Root);
        Paths = isSandbox ? sandboxPaths : sandboxPaths with { IsSandbox = false };
        // The probe log sits outside every folder the guards create, so its presence never confuses a "folder created" or "no log" assertion.
        LogPath = System.IO.Path.Combine(Root, "__probe.log");
        Log = new Log(LogPath);
    }

    // The log messages written so far, with the leading ISO timestamp (which holds no spaces) stripped off each line. Empty when nothing was logged.
    public string[] LogMessages()
    {
        if (!File.Exists(LogPath)) return [];
        return File.ReadAllLines(LogPath)
            .Where(line => line.Length > 0)
            .Select(line => { int space = line.IndexOf(' '); return space < 0 ? line : line[(space + 1)..]; })
            .ToArray();
    }

    public void Dispose()
    {
        try { Directory.Delete(Root, recursive: true); } catch { }
    }
}

// Records every IServiceControl call and returns scripted results, so ServiceGuard's decision tree runs without sc.exe.
internal sealed class FakeServiceControl : IServiceControl
{
    // What GetConfig returns until a successful Delete makes the service "gone".
    public ServiceConfig Config = new(true, ServiceStartType.Automatic, null);
    // What GetConfig returns after a successful Delete; null means the default "gone" config (Exists false).
    public ServiceConfig? ConfigAfterDelete;
    public ServiceRunState RunState = ServiceRunState.Running;
    public bool CreateResult = true;
    public bool StartResult = true;
    public bool DeleteResult = true;
    public bool SetStartAutomaticResult = true;
    public bool SetBinaryPathResult = true;
    public bool SetRecoveryActionsResult = true;
    public bool SetRunSettingsResult = true;
    public readonly List<string> Calls = [];
    public string? CreatedName;
    public string? CreatedDisplay;
    public string? CreatedBinPath;
    public string? SetBinPathValue;
    public TimeSpan? StopTimeout;
    private bool _deleted;

    public ServiceConfig GetConfig(string name)
    {
        Calls.Add("GetConfig");
        if (_deleted) return ConfigAfterDelete ?? new ServiceConfig(false, ServiceStartType.Unknown, null);
        return Config;
    }

    public ServiceRunState GetRunState(string name) { Calls.Add("GetRunState"); return RunState; }

    public bool Create(string name, string displayName, string binaryPath)
    {
        Calls.Add("Create");
        CreatedName = name;
        CreatedDisplay = displayName;
        CreatedBinPath = binaryPath;
        return CreateResult;
    }

    public bool SetStartAutomatic(string name) { Calls.Add("SetStartAutomatic"); return SetStartAutomaticResult; }
    public bool SetBinaryPath(string name, string binaryPath) { Calls.Add("SetBinaryPath"); SetBinPathValue = binaryPath; return SetBinaryPathResult; }
    public bool SetRecoveryActions(string name) { Calls.Add("SetRecoveryActions"); return SetRecoveryActionsResult; }
    public bool SetRunSettings(string name) { Calls.Add("SetRunSettings"); return SetRunSettingsResult; }
    public bool Start(string name) { Calls.Add("Start"); return StartResult; }
    public bool StopAndWait(string name, TimeSpan timeout) { Calls.Add("StopAndWait"); StopTimeout = timeout; return true; }

    public bool Delete(string name)
    {
        Calls.Add("Delete");
        if (DeleteResult) _deleted = true;
        return DeleteResult;
    }
}

// Records which jobs the watchdog asked to keep running.
internal sealed class FakeServiceGuard : IServiceGuard
{
    public readonly List<ServiceJob> EnsureCalls = [];
    public void EnsureRunning(ServiceJob job) => EnsureCalls.Add(job);
    public bool StopAndDelete(ServiceJob job, TimeSpan timeout) => true;
}
