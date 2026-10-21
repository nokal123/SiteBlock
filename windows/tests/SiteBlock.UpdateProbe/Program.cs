using SiteBlock.App;
using SiteBlock.AppLogic;

namespace SiteBlock.UpdateProbe;

/// <summary>
/// Runs the tray app's real updater once against update addresses given on the command line, so the live update test can point it at a local test server
/// without the shipped app ever accepting such addresses. It uses the app's own downloader and elevated runner, checks for an update, installs it when one is
/// offered, and prints one "key value" line per result for e2e.ps1 to read.
/// </summary>
internal static class Program
{
    /// <summary>
    /// Usage: <c>SiteBlock.UpdateProbe &lt;version file URL&gt; &lt;package URL&gt; &lt;installed build&gt;</c>. Prints <c>available</c>, <c>check</c>, and after an install attempt
    /// <c>phase</c>, <c>failure</c>, <c>notice</c> and <c>stillAvailable</c>. Exits 64 for a usage mistake and 0 otherwise; the caller judges the printed results.
    /// </summary>
    private static async Task<int> Main(string[] args)
    {
        if (args.Length != 3 || !Uri.TryCreate(args[0], UriKind.Absolute, out Uri? versionUrl) || !Uri.TryCreate(args[1], UriKind.Absolute, out Uri? packageUrl) || !int.TryParse(args[2], out int installedBuild))
        {
            Console.Error.WriteLine("usage: SiteBlock.UpdateProbe <version file URL> <package URL> <installed build>");
            return 64;
        }
        var options = new UpdaterOptions { InstalledBuild = installedBuild, VersionUrl = versionUrl, PackageUrl = packageUrl };
        using var updater = new Updater(new HttpUpdateDownloader(), new UacElevatedRunner(), new InMemoryDismissedUpdateStore(), SystemClock.Instance, new InlineUiDispatcher(), options);
        await updater.CheckNowAsync();
        Console.WriteLine($"available {updater.Available?.Build.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "none"}");
        Console.WriteLine($"check {updater.CheckResult?.ToString() ?? "none"}");
        if (updater.Available is null) return 0;
        await updater.InstallAsync();
        Console.WriteLine($"phase {updater.Phase.Kind}");
        Console.WriteLine($"failure {updater.Phase.FailureText ?? ""}");
        Console.WriteLine($"notice {updater.Notice ?? ""}");
        Console.WriteLine($"stillAvailable {updater.Available is not null}");
        return 0;
    }
}
