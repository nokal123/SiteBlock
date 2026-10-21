using System.Text;

namespace SiteBlock.Service;

/// <summary>
/// Writes one line per message, each starting with an ISO 8601 time, to a log file and to standard error.
/// A file over 1 MB is rotated before the next line: siteblockd.log becomes siteblockd.log.1, older copies move up to .3, and the oldest is deleted.
/// Callers must never pass a password, a domain or a path rule.
/// </summary>
public sealed class Log
{
    /// The size at which the file is rotated.
    public const long MaxBytes = 1024 * 1024;
    /// How many old copies are kept.
    public const int KeptCopies = 3;

    private readonly string? _file;
    private readonly object _lock = new();

    /// Creates a logger that writes to the given file (its folder is created when missing), or only to standard error when the file is null.
    public Log(string? file)
    {
        _file = file;
        if (_file is not null)
        {
            try { Directory.CreateDirectory(System.IO.Path.GetDirectoryName(_file)!); } catch { /* the first write will try again */ }
        }
    }

    /// Writes "<time> <message>". A failed write is ignored on purpose: logging must never stop the service from enforcing blocks.
    public void Write(string message)
    {
        var line = $"{DateTimeOffset.Now:yyyy-MM-ddTHH:mm:sszzz} {message}\n";
        lock (_lock)
        {
            try { Console.Error.Write(line); } catch { }
            if (_file is null) return;
            try
            {
                RotateIfNeeded();
                File.AppendAllText(_file, line, new UTF8Encoding(false));
            }
            catch { }
        }
    }

    /// Moves the current file to .1 (and older copies up one place) when it has reached MaxBytes.
    private void RotateIfNeeded()
    {
        var info = new FileInfo(_file!);
        if (!info.Exists || info.Length < MaxBytes) return;
        var oldest = $"{_file}.{KeptCopies}";
        if (File.Exists(oldest)) File.Delete(oldest);
        for (var i = KeptCopies - 1; i >= 1; i--)
        {
            var from = $"{_file}.{i}";
            if (File.Exists(from)) File.Move(from, $"{_file}.{i + 1}");
        }
        File.Move(_file!, $"{_file}.1");
    }
}
