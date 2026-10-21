using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;
using SiteBlock.Core;

namespace SiteBlock.Integration.Tests.Support;

// A raw client of the sandbox pipe that sends exactly the bytes a test gives it, for wire-protocol tests (malformed JSON, oversized lines, silence).
internal sealed class RawConnection : IDisposable
{
    private readonly NamedPipeClientStream _pipe;

    private RawConnection(NamedPipeClientStream pipe) => _pipe = pipe;

    // Connects to the sandbox pipe at the given path (a Unix socket on macOS and Linux, a named pipe on Windows), using the same name the real client derives.
    public static RawConnection Open(string pipePath)
    {
        var pipe = new NamedPipeClientStream(".", PipeNames.ClientPipeName(pipePath), PipeDirection.InOut, PipeOptions.Asynchronous);
        pipe.Connect(5000);
        return new RawConnection(pipe);
    }

    // Writes bytes; a server that already closed the connection is not an error here.
    public void Write(byte[] bytes)
    {
        try
        {
            _pipe.Write(bytes);
            _pipe.Flush();
        }
        catch (IOException) { }
    }

    public void Write(string text) => Write(Encoding.UTF8.GetBytes(text));

    // Reads until a newline or the end of the stream, waiting at most the given time. Returns the line without its newline, "" when the server closed without a byte, or null on timeout.
    public string? ReadLine(double seconds = 10)
    {
        var collected = new MemoryStream();
        var buffer = new byte[4096];
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        while (true)
        {
            int count;
            try { count = _pipe.ReadAsync(buffer, limit.Token).AsTask().GetAwaiter().GetResult(); }
            catch (OperationCanceledException) { return null; }
            catch (IOException) { count = 0; }
            if (count == 0) return Encoding.UTF8.GetString(collected.ToArray());
            int newline = Array.IndexOf(buffer, (byte)'\n', 0, count);
            if (newline >= 0)
            {
                collected.Write(buffer, 0, newline);
                return Encoding.UTF8.GetString(collected.ToArray());
            }
            collected.Write(buffer, 0, count);
        }
    }

    // Sends one request line (the newline is added) and returns the reply parsed as a JSON object.
    public static JsonObject Exchange(string pipePath, string requestLine, double seconds = 10)
    {
        using var connection = Open(pipePath);
        connection.Write(requestLine + "\n");
        string? reply = connection.ReadLine(seconds);
        Assert.False(string.IsNullOrEmpty(reply), $"no reply to {Shorten(requestLine)}");
        return JsonNode.Parse(reply!) as JsonObject ?? throw new Xunit.Sdk.XunitException("reply is not a JSON object: " + reply);
    }

    // The first 80 characters of a request, for failure messages.
    private static string Shorten(string text) => text.Length <= 80 ? text : text[..80] + "…";

    // Times a block, for the timeout tests.
    public static TimeSpan Time(Action action)
    {
        var clock = Stopwatch.StartNew();
        action();
        return clock.Elapsed;
    }

    public void Dispose() => _pipe.Dispose();
}
