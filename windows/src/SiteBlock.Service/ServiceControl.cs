using System.ComponentModel;
using System.Security;
using Microsoft.Win32;
using System.Runtime.Versioning;
using System.ServiceProcess;

namespace SiteBlock.Service;

/// <summary>How a Windows service is set to start.</summary>
public enum ServiceStartType
{
    /// Windows starts the service by itself at boot (registry Start value 2, AUTO_START).
    Automatic,
    /// The service starts only when something asks for it (Start value 3, DEMAND_START).
    Manual,
    /// Windows refuses to start the service at all (Start value 4, DISABLED).
    Disabled,
    /// The start type could not be read.
    Unknown,
}

/// <summary>Whether a Windows service exists and, if so, whether it is running.</summary>
public enum ServiceRunState
{
    /// No service by that name is installed.
    Missing,
    /// The service is installed and not running (STOPPED).
    Stopped,
    /// The service is installed and running (RUNNING).
    Running,
    /// The service is installed and in some in-between state, such as still starting or stopping.
    Other,
}

/// <summary>What one service's configuration looks like: whether it exists, how it starts, the program it runs, and the settings that decide whether it can run at all.</summary>
/// <param name="Exists">True when a service by that name is installed. Meaningless when <paramref name="ReadFailed"/> is true.</param>
/// <param name="StartType">How the service is set to start.</param>
/// <param name="BinaryPath">The image path the service runs, as the service control manager stored it (the program in quotes, a space, then the flag), or null when it could not be read.</param>
/// <param name="TypeCode">The registry Type value (0x10 means a service in its own process), or null when unknown, which the guard leaves alone.</param>
/// <param name="Account">The account the service runs as, such as "LocalSystem", or null when unknown, which the guard leaves alone.</param>
/// <param name="Dependencies">The services this one waits for before it may start (empty when none), or null when unknown, which the guard leaves alone.</param>
/// <param name="ReadFailed">True when the configuration could not be read at all, so nothing is known about it, including whether it exists.</param>
public readonly record struct ServiceConfig(bool Exists, ServiceStartType StartType, string? BinaryPath, int? TypeCode = null, string? Account = null, IReadOnlyList<string>? Dependencies = null, bool ReadFailed = false);

/// <summary>
/// The service-control operations <see cref="ServiceGuard"/> needs, named by what they mean rather than by sc.exe text,
/// so the guard holds no command-line building or output parsing and can be driven by a fake in tests.
/// </summary>
public interface IServiceControl
{
    /// <summary>Reads the service's configuration. A missing service returns <c>Exists == false</c>.</summary>
    ServiceConfig GetConfig(string name);

    /// <summary>Reads whether the service is installed and running.</summary>
    ServiceRunState GetRunState(string name);

    /// <summary>Creates the service as an own-process service that starts automatically and runs as LocalSystem, running <paramref name="binaryPath"/>. Returns true on success.</summary>
    bool Create(string name, string displayName, string binaryPath);

    /// <summary>Sets the service to start automatically. Returns true on success.</summary>
    bool SetStartAutomatic(string name);

    /// <summary>Sets the program path the service runs. Returns true on success.</summary>
    bool SetBinaryPath(string name, string binaryPath);

    /// <summary>Sets the recovery actions: restart 5 seconds after each of the first three failures, with the failure count reset after 86,400 seconds. Returns true on success.</summary>
    bool SetRecoveryActions(string name);

    /// <summary>Puts back the settings that decide whether the service can run at all: its own process, the LocalSystem account and no dependencies on other services. Returns true on success.</summary>
    bool SetRunSettings(string name);

    /// <summary>Starts the service when it is stopped. Returns true when it is running or starting afterwards.</summary>
    bool Start(string name);

    /// <summary>Stops the service and waits up to <paramref name="timeout"/> for it to reach the stopped state. Returns true when it is stopped (or already gone).</summary>
    bool StopAndWait(string name, TimeSpan timeout);

    /// <summary>Deletes the service. Returns true when it is gone (including when it was already gone).</summary>
    bool Delete(string name);
}

/// <summary>
/// The real Windows service control. It reads a service's settings from its registry key
/// (HKLM\SYSTEM\CurrentControlSet\Services\<name>, where the service control manager keeps them), because those value
/// names are the same in every Windows language while sc.exe's printed labels are not. It changes settings with sc.exe and
/// starts and stops services with <see cref="ServiceController"/>.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class ScServiceControl : IServiceControl
{
    // ERROR_SERVICE_DOES_NOT_EXIST: sc.exe exits with this code when no service by that name is installed.
    private const int ServiceDoesNotExist = 1060;
    private static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(10);

    // sc.exe is run from %SystemRoot%\System32, not a bare "sc" on PATH, so a planted sc.exe cannot be run instead.
    private static string ScExe => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "sc.exe");

    // Reads the service's settings from its registry key in the 64-bit view. A missing key means no such service; a key that cannot be opened or read says nothing about the service, so it is reported as unread rather than missing, which would make the guard try to create a service that is still there.
    public ServiceConfig GetConfig(string name)
    {
        try
        {
            using var root = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
            using var key = root.OpenSubKey($@"SYSTEM\CurrentControlSet\Services\{name}");
            if (key is null) return new ServiceConfig(false, ServiceStartType.Unknown, null);
            // ImagePath is read exactly as stored, so it compares with the path sc.exe wrote.
            return ServiceConfigReader.FromValues(key.GetValue("Start"), key.GetValue("Type"), key.GetValue("ImagePath", null, RegistryValueOptions.DoNotExpandEnvironmentNames), key.GetValue("ObjectName"), key.GetValue("DependOnService"), key.GetValue("DependOnGroup"), key.GetValue("DeleteFlag"));
        }
        catch (Exception error) when (error is SecurityException or UnauthorizedAccessException or IOException)
        {
            return new ServiceConfig(true, ServiceStartType.Unknown, null, ReadFailed: true);
        }
    }

    // Reads the run state through ServiceController; a service that does not exist makes the status read throw, which is mapped to Missing.
    public ServiceRunState GetRunState(string name)
    {
        try
        {
            using var controller = new ServiceController(name);
            return controller.Status switch
            {
                ServiceControllerStatus.Stopped => ServiceRunState.Stopped,
                ServiceControllerStatus.Running => ServiceRunState.Running,
                _ => ServiceRunState.Other,
            };
        }
        catch (InvalidOperationException)
        {
            // ServiceController wraps ERROR_SERVICE_DOES_NOT_EXIST in InvalidOperationException when the service is not installed.
            return ServiceRunState.Missing;
        }
    }

    // Creates the service with the key= value spacing sc.exe requires, quoting the image path and display name.
    public bool Create(string name, string displayName, string binaryPath)
    {
        var commandLine = $"create {name} binPath= {Quote(binaryPath)} start= auto obj= LocalSystem DisplayName= {Quote(displayName)}";
        return ProcessRunner.RunRaw(ScExe, commandLine, CommandTimeout).Succeeded;
    }

    // Puts the start type back to automatic.
    public bool SetStartAutomatic(string name) => ProcessRunner.RunRaw(ScExe, $"config {name} start= auto", CommandTimeout).Succeeded;

    // Puts the image path back to the wanted program and flag.
    public bool SetBinaryPath(string name, string binaryPath) => ProcessRunner.RunRaw(ScExe, $"config {name} binPath= {Quote(binaryPath)}", CommandTimeout).Succeeded;

    // Sets the restart-three-times recovery actions, matching the Mac's KeepAlive behavior.
    public bool SetRecoveryActions(string name) => ProcessRunner.RunRaw(ScExe, $"failure {name} reset= 86400 actions= restart/5000/restart/5000/restart/5000", CommandTimeout).Succeeded;

    // Puts back its own process, the LocalSystem account and no dependencies; "depend= /" is sc.exe's way of writing an empty dependency list.
    public bool SetRunSettings(string name) => ProcessRunner.RunRaw(ScExe, $"config {name} type= own obj= LocalSystem depend= /", CommandTimeout).Succeeded;

    // Starts the service only when it is stopped; a service already running or coming up is left alone, so starting never throws on a pending state.
    public bool Start(string name)
    {
        try
        {
            using var controller = new ServiceController(name);
            controller.Refresh();
            if (controller.Status == ServiceControllerStatus.Stopped) { controller.Start(); return true; }
            return controller.Status is ServiceControllerStatus.Running or ServiceControllerStatus.StartPending;
        }
        catch (InvalidOperationException) { return false; }
        catch (Win32Exception) { return false; }
    }

    // Stops the service if it can be stopped, then waits up to the timeout for it to reach the stopped state.
    public bool StopAndWait(string name, TimeSpan timeout)
    {
        try
        {
            using var controller = new ServiceController(name);
            controller.Refresh();
            if (controller.Status != ServiceControllerStatus.Stopped && controller.CanStop) controller.Stop();
            // WaitForStatus throws its own TimeoutException when the service does not reach Stopped in time; the final Refresh tells the real outcome.
            try { controller.WaitForStatus(ServiceControllerStatus.Stopped, timeout); }
            catch (System.ServiceProcess.TimeoutException) { }
            controller.Refresh();
            return controller.Status == ServiceControllerStatus.Stopped;
        }
        // A service that is already gone counts as stopped; a real failure to control it counts as not stopped.
        catch (InvalidOperationException) { return true; }
        catch (Win32Exception) { return false; }
    }

    // Deletes the service; a service that was already gone counts as deleted.
    public bool Delete(string name)
    {
        var result = ProcessRunner.Run(ScExe, ["delete", name], CommandTimeout);
        return result.Succeeded || result.ExitCode == ServiceDoesNotExist;
    }

    // Wraps a value in double quotes for one sc.exe argument, escaping any inner quotes with a backslash, so the image path's own quotes survive argv parsing.
    private static string Quote(string value) => $"\"{value.Replace("\"", "\\\"")}\"";
}

/// <summary>
/// Turns the values of a service's registry key into a <see cref="ServiceConfig"/>. It is plain logic with no Windows calls,
/// kept apart from <see cref="ScServiceControl"/> so its tests run on every platform. Each argument is the value as
/// RegistryKey.GetValue returns it: an int for a number, a string, a string array for a list, or null when the value is absent.
/// </summary>
internal static class ServiceConfigReader
{
    internal static ServiceConfig FromValues(object? start, object? type, object? imagePath, object? objectName, object? dependOnService, object? dependOnGroup, object? deleteFlag)
    {
        // A service marked for deletion is removed by Windows as soon as it stops, so it counts as gone: the uninstaller is done with it, and the guard's recreate simply fails (and is retried) until Windows has removed it.
        if (deleteFlag is int flag && flag != 0) return new ServiceConfig(false, ServiceStartType.Unknown, null);
        var startType = start is int code ? StartTypeFromCode(code) : ServiceStartType.Unknown;
        int? typeCode = type is int number ? number : null;
        // Services and service groups it waits for both count; with neither value present the list is empty, which is how the registry records "no dependencies".
        var dependencies = new List<string>();
        foreach (var list in new[] { dependOnService, dependOnGroup })
            if (list is string[] names) dependencies.AddRange(names.Where(entry => !string.IsNullOrWhiteSpace(entry)));
        return new ServiceConfig(true, startType, imagePath as string, typeCode, objectName as string, dependencies);
    }

    // Turns the registry's numeric start code into the enum; any code other than 2, 3 or 4 is Unknown. A delayed automatic start is code 2 as well.
    private static ServiceStartType StartTypeFromCode(int code) => code switch
    {
        2 => ServiceStartType.Automatic,
        3 => ServiceStartType.Manual,
        4 => ServiceStartType.Disabled,
        _ => ServiceStartType.Unknown,
    };
}
