using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using Microsoft.Win32;
using SiteBlock.AppLogic;

namespace SiteBlock.App;

/// <summary>Downloads the update files with HttpClient: it follows GitHub's redirect to its file host, keeps no cookies and no cache, and gives up after the time limit it is given (15 seconds for the version file, 5 minutes for the package).</summary>
internal sealed class HttpUpdateDownloader : IUpdateDownloader
{
    /// <summary>One client for the life of the app, as HttpClient is meant to be used.</summary>
    private static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = true,
        MaxAutomaticRedirections = 10,
        UseCookies = false,
        AutomaticDecompression = DecompressionMethods.None,
    })
    {
        // Each request sets its own limit through a cancellation token.
        Timeout = Timeout.InfiniteTimeSpan,
    };

    /// <summary>Fetches the version file; returns its bytes only for a 200 answer of at most <paramref name="maxBytes"/> bytes within the limit, otherwise null.</summary>
    public async Task<byte[]?> FetchVersionFileAsync(Uri url, TimeSpan timeout, int maxBytes, CancellationToken ct)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(timeout);
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.CacheControl = new System.Net.Http.Headers.CacheControlHeaderValue { NoCache = true };
            using HttpResponseMessage response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, limit.Token).ConfigureAwait(false);
            if (response.StatusCode != HttpStatusCode.OK) return null;
            if (response.Content.Headers.ContentLength > maxBytes) return null;
            await using Stream body = await response.Content.ReadAsStreamAsync(limit.Token).ConfigureAwait(false);
            // Read at most one byte more than allowed, so an oversized answer is recognised without reading all of it.
            var buffer = new MemoryStream();
            byte[] chunk = new byte[8192];
            while (true)
            {
                int read = await body.ReadAsync(chunk, limit.Token).ConfigureAwait(false);
                if (read == 0) break;
                buffer.Write(chunk, 0, read);
                if (buffer.Length > maxBytes) return null;
            }
            return buffer.ToArray();
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>Downloads the package into a new file at <paramref name="destinationPath"/>; returns false on any failure, and removes a partial file.</summary>
    public async Task<bool> DownloadFileAsync(Uri url, string destinationPath, TimeSpan timeout, CancellationToken ct)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(timeout);
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            using HttpResponseMessage response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, limit.Token).ConfigureAwait(false);
            if (response.StatusCode != HttpStatusCode.OK) return false;
            await using (Stream body = await response.Content.ReadAsStreamAsync(limit.Token).ConfigureAwait(false))
            await using (var file = new FileStream(destinationPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                await body.CopyToAsync(file, limit.Token).ConfigureAwait(false);
            }
            return true;
        }
        catch (Exception)
        {
            try
            {
                File.Delete(destinationPath);
            }
            catch (Exception)
            {
                // The folder is deleted with everything in it afterwards anyway.
            }
            return false;
        }
    }
}

/// <summary>
/// Starts a program with administrator rights through ShellExecute and the "runas" verb, which makes Windows show the UAC prompt ("Do you want to allow this app to make changes to your device?").
/// Answering "No" makes Windows report error 1223 (ERROR_CANCELLED), which is reported as <see cref="ElevatedRunOutcome.Cancelled"/>.
/// </summary>
internal sealed class UacElevatedRunner : IElevatedRunner
{
    /// <summary>The Windows error number for "The operation was canceled by the user."</summary>
    private const int ErrorCancelled = 1223;

    /// <summary>Starts the program elevated with a hidden window, calls <paramref name="onStarted"/> once it runs, and waits for it to exit within <paramref name="timeout"/>.</summary>
    public async Task<ElevatedRunResult> RunAsync(string fileName, string arguments, Action onStarted, TimeSpan timeout, CancellationToken ct)
    {
        Process? process;
        try
        {
            var start = new ProcessStartInfo(fileName, arguments) { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden };
            // Process.Start waits while the UAC prompt is on screen, so it runs on a pool thread.
            process = await Task.Run(() => Process.Start(start), CancellationToken.None).ConfigureAwait(false);
        }
        catch (Win32Exception e) when (e.NativeErrorCode == ErrorCancelled)
        {
            return new ElevatedRunResult(ElevatedRunOutcome.Cancelled);
        }
        catch (Exception)
        {
            return new ElevatedRunResult(ElevatedRunOutcome.Failed);
        }
        if (process is null) return new ElevatedRunResult(ElevatedRunOutcome.Failed);

        using (process)
        {
            onStarted();
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
            limit.CancelAfter(timeout);
            try
            {
                await process.WaitForExitAsync(limit.Token).ConfigureAwait(false);
                return new ElevatedRunResult(ElevatedRunOutcome.Exited, process.ExitCode);
            }
            catch (OperationCanceledException)
            {
                return new ElevatedRunResult(ElevatedRunOutcome.TimedOut);
            }
            catch (Exception)
            {
                // The exit code of an elevated process could not be read; the install's own log says how it went.
                return new ElevatedRunResult(ElevatedRunOutcome.TimedOut);
            }
        }
    }
}

/// <summary>Keeps the dismissed update's build number in the registry, as the DWORD <c>DismissedUpdateBuild</c> under <c>HKCU\Software\SiteBlock</c>.</summary>
internal sealed class RegistryDismissedUpdateStore : IDismissedUpdateStore
{
    private const string KeyPath = @"Software\SiteBlock";
    private const string ValueName = "DismissedUpdateBuild";

    /// <summary>The stored build, or 0 when the value is missing, of another type, or unreadable.</summary>
    public int Load()
    {
        using RegistryKey? key = Registry.CurrentUser.OpenSubKey(KeyPath);
        return key?.GetValue(ValueName) is int build && build > 0 ? build : 0;
    }

    /// <summary>Writes the build as a DWORD, creating the key when needed.</summary>
    public void Save(int build)
    {
        using RegistryKey key = Registry.CurrentUser.CreateSubKey(KeyPath, writable: true);
        key.SetValue(ValueName, build, RegistryValueKind.DWord);
    }

    /// <summary>Removes the value.</summary>
    public void Clear()
    {
        using RegistryKey? key = Registry.CurrentUser.OpenSubKey(KeyPath, writable: true);
        key?.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}

/// <summary>
/// Writes the tray app's log lines to <c>%LOCALAPPDATA%\SiteBlock\Logs\app.log</c>, each with a timestamp. A file over 1 MB is renamed to <c>app.log.1</c> (replacing the older copy) before the next line.
/// Callers never pass a password, a domain, an address or a path rule. A failure to write is ignored, because logging must never break the app.
/// </summary>
internal sealed class FileAppLog : IAppLog
{
    private const long MaxBytes = 1024 * 1024;
    private readonly Lock _gate = new();
    private readonly string _path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SiteBlock", "Logs", "app.log");

    /// <summary>Appends one line with an ISO 8601 timestamp.</summary>
    public void Info(string message)
    {
        lock (_gate)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
                var info = new FileInfo(_path);
                if (info.Exists && info.Length > MaxBytes) File.Move(_path, _path + ".1", overwrite: true);
                File.AppendAllText(_path, DateTimeOffset.Now.ToString("o", System.Globalization.CultureInfo.InvariantCulture) + " " + message + Environment.NewLine, Encoding.UTF8);
            }
            catch (Exception)
            {
                // Nothing to do: a log line is never worth an error.
            }
        }
    }
}
