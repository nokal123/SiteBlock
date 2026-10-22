using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using SiteBlock.Core;
using SiteBlock.Integration.Tests.Support;
using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.TamperResistance;

// A person (or an editor) saving the hosts file while a pass is working on it. Expected values come from 06-windows.md § HostsEnforcer step 4: before writing, the
// enforcer reads the file once more; when someone saved it since the first read, the pass starts over from the new text, up to three times, and only then leaves the
// file for the next pass, so a concurrent save is never replaced by text built from the older copy. HostsFileEditor.Render (the specified renderer) gives the wanted text.
//
// The in-process tests make the save land exactly between the enforcer's first read and its write. The hosts path is a named pipe (a FIFO, a Unix file that hands each
// reader whatever a writer puts in), so the test decides what each read returns: the first read gets the old text and the next reads get the person's saved text. A real
// file cannot do this deterministically, because the gap between the two reads is a few microseconds. These run on macOS and Linux only, where a FIFO can be made.
public sealed class HostsConcurrentSaveTests
{
    private static readonly string[] Blocked = ["reddit.com"];
    private const string Before = "127.0.0.1 localhost\n";
    private const string HandLine = "10.9.8.7 hand-edit.example";
    private const string Saved = Before + HandLine + "\n";

    // Hands a fixed list of texts to whoever reads the FIFO, one text per read, and counts how many were taken. It opens the FIFO without blocking and polls, so it can
    // always be stopped, even when the FIFO has been replaced by a real file.
    [UnsupportedOSPlatform("windows")]
    private sealed class FifoFeeder : IDisposable
    {
        private readonly string _path;
        private readonly IReadOnlyList<string> _texts;
        private readonly Thread _thread;
        private volatile bool _stop;
        private int _delivered;

        public FifoFeeder(string path, IReadOnlyList<string> texts)
        {
            _path = path;
            _texts = texts;
            _thread = new Thread(Run) { IsBackground = true };
            _thread.Start();
        }

        public int Delivered => Volatile.Read(ref _delivered);

        private void Run()
        {
            int nonBlocking = OperatingSystem.IsMacOS() ? 0x0004 : 0x0800;
            foreach (string text in _texts)
            {
                int fd;
                // Opening a FIFO for writing without blocking fails until a reader has it open, so this waits for the enforcer's next read.
                while ((fd = Open(_path, 1 | nonBlocking)) < 0)
                {
                    if (_stop) return;
                    Thread.Sleep(1);
                }
                byte[] bytes = Encoding.UTF8.GetBytes(text);
                _ = Write(fd, bytes, bytes.Length);
                _ = Close(fd);
                Interlocked.Increment(ref _delivered);
                // Give the reader time to see the end of this text and close, so the next text never runs on into the same read.
                Thread.Sleep(30);
            }
        }

        public void Dispose()
        {
            _stop = true;
            _thread.Join(TimeSpan.FromSeconds(5));
        }

        [DllImport("libc", EntryPoint = "open", SetLastError = true)]
        private static extern int Open(string path, int flags);

        [DllImport("libc", EntryPoint = "write", SetLastError = true)]
        private static extern nint Write(int fd, byte[] buffer, nint count);

        [DllImport("libc", EntryPoint = "close", SetLastError = true)]
        private static extern int Close(int fd);
    }

    [DllImport("libc", EntryPoint = "mkfifo", SetLastError = true)]
    private static extern int MakeFifo(string path, uint mode);

    // True when the path is still a FIFO, which means nothing was written over it.
    private static bool IsFifo(string path)
    {
        var start = new ProcessStartInfo("/bin/sh") { ArgumentList = { "-c", "test -p \"$1\"", "sh", path } };
        using var test = Process.Start(start)!;
        test.WaitForExit();
        return test.ExitCode == 0;
    }

    // Replaces the sandbox hosts file with a FIFO and runs one pass on a worker, failing the test when the pass does not end within 10 seconds.
    [UnsupportedOSPlatform("windows")]
    private static (bool Result, int Delivered) EnforceAgainstFifo(TempSandbox s, IReadOnlyList<string> texts)
    {
        Assert.Equal(0, MakeFifo(s.Paths.HostsFile, Convert.ToUInt32("644", 8)));
        using var feeder = new FifoFeeder(s.Paths.HostsFile, texts);
        var enforcer = new HostsEnforcer(s.Paths, s.Log);
        var pass = Task.Run(() => enforcer.Enforce(Blocked, causedByCommand: false));
        Assert.True(pass.Wait(TimeSpan.FromSeconds(10)), "the pass did not end within 10 s (it read the file more often than the test fed it)");
        return (pass.Result, feeder.Delivered);
    }

    [UnixFact("a FIFO at the hosts path is how the test times the save; Windows has no FIFO files")]
    [UnsupportedOSPlatform("windows")]
    public void SaveLandsBetweenTheFirstReadAndTheWrite_PassStartsOverAndKeepsThePersonsLine()
    {
        using var s = new TempSandbox();

        // The first read sees the file before the save; every later read sees the saved file.
        var (result, delivered) = EnforceAgainstFifo(s, [Before, Saved, Saved, Saved, Saved]);

        Assert.True(result);
        Assert.False(IsFifo(s.Paths.HostsFile), "the pass never wrote the file");
        string written = File.ReadAllText(s.Paths.HostsFile);
        // The section was added to the saved text, so the person's line survives; text built from the first read would lack it.
        Assert.Equal(HostsFileEditor.Render(Saved, Blocked), written);
        Assert.Contains(HandLine, written.Split('\n'));
        // At least: the first read, the read just before the write that saw the save, and the fresh read the pass started over from.
        Assert.InRange(delivered, 3, 5);
        Assert.Equal(["hosts file repaired"], s.LogMessages());
    }

    [UnixFact("a FIFO at the hosts path is how the test times the save; Windows has no FIFO files")]
    [UnsupportedOSPlatform("windows")]
    public void SavedTextAlreadyHoldsTheSection_PassStartsOverAndWritesNothing()
    {
        using var s = new TempSandbox();
        string compliant = HostsFileEditor.Render(Saved, Blocked);

        var (result, _) = EnforceAgainstFifo(s, [Before, compliant, compliant, compliant]);

        Assert.True(result);
        // The pass started over, found the saved file already correct, and so wrote nothing: the FIFO is still there.
        Assert.True(IsFifo(s.Paths.HostsFile), "the pass wrote over a file that was already correct after the save");
        Assert.Empty(s.LogMessages());
    }

    [UnixFact("a FIFO at the hosts path is how the test times the save; Windows has no FIFO files")]
    [UnsupportedOSPlatform("windows")]
    public void SaveCollidesWithEveryAttempt_PassLeavesTheFileForTheNextPass()
    {
        using var s = new TempSandbox();
        // Every read sees a different save, so every attempt finds the file changed just before its write.
        var texts = Enumerable.Range(0, 8).Select(i => $"{Before}10.9.8.{i} save-{i}.example\n").ToList();

        var (result, delivered) = EnforceAgainstFifo(s, texts);

        // Nothing is written: the file is left as the person saved it, for the next pass.
        Assert.True(IsFifo(s.Paths.HostsFile), "the pass wrote text built from a copy that had already been replaced");
        Assert.False(result, "a pass that left the file without its section must not report the file as correct");
        Assert.DoesNotContain(s.LogMessages(), line => line.Contains("repaired", StringComparison.Ordinal) || line.Contains("removed", StringComparison.Ordinal));
        // "Up to three times": three attempts of two reads each, or, if the design's words mean three fresh starts after the first, four. Never fewer, never endless.
        Assert.InRange(delivered, 6, 8);
    }

    // A running daemon repairing while the person keeps saving. Each save puts the same text in place (the person's line, without SiteBlock's section), at random moments
    // a few ticks apart, the way a person who keeps pressing save in Notepad would. The final save must survive with the section added back, the person's line exactly
    // once, and the original lines kept. This is a soak test: a single save that lands inside the few microseconds between the enforcer's last read and its write cannot be
    // timed from outside, so the deterministic proof of the start-over rule is the FIFO tests above; this one shows the whole loop ends in the right file.
    [Fact]
    public void PersonKeepsSavingWhileTheDaemonRepairs_TheirLineSurvivesAndTheSectionIsCorrect()
    {
        using var daemon = SandboxDaemon.Start();
        daemon.SetupAndAdd("reddit.com");
        int repairsBefore = daemon.LogCount("hosts file repaired");
        string personText = SandboxDaemon.StartingHosts + HandLine + "\n";
        var random = new Random(20261022);

        for (int save = 0; save < 25; save++)
        {
            SandboxDaemon.WriteAllText(daemon.HostsPath, personText);
            Thread.Sleep(random.Next(0, 160));
        }

        var wantedSection = Expected.SectionFor(Expected.Expand("reddit.com"));
        Assert.True(Wait.Until(() => Expected.SectionLines(daemon.HostsText()) is { } lines && lines.SequenceEqual(wantedSection), 5), daemon.HostsText());
        string final = daemon.HostsText();
        var finalLines = final.Split('\n');
        Assert.Single(finalLines, line => line == HandLine);
        Assert.StartsWith(personText, final);
        // Exactly one section: a pass that wrote over a half-saved file must never leave two.
        Assert.Single(finalLines, line => line.StartsWith("# BEGIN SiteBlock", StringComparison.Ordinal));
        // Control: the daemon really repaired during the saves, so the loop raced with real passes.
        Assert.True(daemon.LogCount("hosts file repaired") > repairsBefore, daemon.LogText());
    }
}
