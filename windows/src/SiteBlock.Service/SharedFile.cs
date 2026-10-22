using System.Text;

namespace SiteBlock.Service;

/// <summary>
/// Reads a whole file while letting other programs keep reading, writing, replacing or deleting it. On Windows an ordinary read (File.ReadAllText) refuses
/// other programs the right to delete or replace the file while it is open, so a service that reads a file on every pass would now and then make someone
/// else's delete or save fail. The service's sandbox stores use this for every read.
/// </summary>
internal static class SharedFile
{
    /// <summary>Returns the file's text, decoded as UTF-8. Throws the same exceptions as File.ReadAllText, such as FileNotFoundException for a missing file.</summary>
    internal static string ReadAllText(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        return reader.ReadToEnd();
    }
}
