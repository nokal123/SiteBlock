using System.IO.Pipes;
using System.Text.Json;

namespace SiteBlock.Core;

/// <summary>The reasons a request to the service can fail before a response is read.</summary>
public enum ClientError
{
    /// <summary>The pipe does not exist or could not be connected to, so the service is not running.</summary>
    NotRunning,
    /// <summary>No reply arrived in time.</summary>
    Timeout,
    /// <summary>A reply arrived but was empty or not valid JSON for a response.</summary>
    BadResponse,
}

/// <summary>The exception <see cref="DaemonClient"/> throws when a request fails; <see cref="Error"/> says why and <see cref="Exception.Message"/> is a sentence a person can read.</summary>
public sealed class DaemonClientException : Exception
{
    /// <summary>Which kind of failure this is.</summary>
    public ClientError Error { get; }

    /// <summary>Creates the exception for one kind of failure, with the standard sentence for it.</summary>
    public DaemonClientException(ClientError error) : base(MessageFor(error)) => Error = error;

    /// <summary>The sentence shown to the user for each problem (the same wording as the Mac version, with "service" in place of "daemon").</summary>
    private static string MessageFor(ClientError error) => error switch
    {
        ClientError.NotRunning => "The SiteBlock service isn't running.",
        ClientError.Timeout => "The SiteBlock service did not answer in time.",
        ClientError.BadResponse => "The SiteBlock service sent a reply that could not be understood.",
        _ => "Could not talk to the SiteBlock service.",
    };
}

/// <summary>The client side of the wire protocol, used by both the command line and the app. Each call opens a fresh connection to the named pipe, sends one request line, and reads one response line.</summary>
public sealed class DaemonClient
{
    /// <summary>How long to wait for the pipe to accept a connection before deciding the service is not running.</summary>
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(2);

    /// <summary>A reply bigger than this is treated as garbage instead of being buffered without limit.</summary>
    private const int MaxResponseBytes = 4 * 1024 * 1024;

    private readonly string _pipeName;
    private readonly TimeSpan _timeout;

    /// <summary>
    /// Creates a client. <paramref name="pipe"/> is the pipe to use; when it is null the SITEBLOCK_PIPE environment variable is used if set, so a sandbox service is reached without extra code in the callers, and otherwise the installed service's pipe.
    /// <paramref name="timeout"/> is how long to wait for a reply (10 seconds by default).
    /// </summary>
    public DaemonClient(string? pipe = null, TimeSpan? timeout = null)
    {
        _pipeName = PipeNames.ClientPipeName(pipe);
        // A zero or negative wait would cancel before anything is read, so at least a millisecond is used.
        TimeSpan wanted = timeout ?? TimeSpan.FromSeconds(10);
        _timeout = wanted < TimeSpan.FromMilliseconds(1) ? TimeSpan.FromMilliseconds(1) : wanted;
    }

    /// <summary>Sends one request and returns the service's response, or throws a <see cref="DaemonClientException"/>. It blocks the calling thread until the reply arrives.</summary>
    public Response Send(Request request)
    {
        // Running on the thread pool keeps this call from deadlocking when a window's thread (which waits for its own turn) calls it.
        return Task.Run(() => SendAsync(request)).GetAwaiter().GetResult();
    }

    /// <summary>Sends one request and returns the service's response, or throws a <see cref="DaemonClientException"/>. Cancelling <paramref name="ct"/> throws <see cref="OperationCanceledException"/>.</summary>
    public async Task<Response> SendAsync(Request request, CancellationToken ct = default)
    {
        // One line of JSON ending in a newline is the whole request.
        byte[] line = [.. JsonSerializer.SerializeToUtf8Bytes(request), (byte)'\n'];

        await using NamedPipeClientStream pipe = OpenPipe(_pipeName);
        await ConnectAsync(pipe, ct).ConfigureAwait(false);

        // The reply timer starts once connected. Cancelling it by timeout is told apart from the caller's own cancel below.
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(_timeout);
        byte[] reply;
        try
        {
            bool writeBroke = await WriteRequestAsync(pipe, line, limit.Token).ConfigureAwait(false);
            reply = await ReadLineAsync(pipe, writeBroke, limit.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new DaemonClientException(ClientError.Timeout);
        }

        if (reply.Length == 0) throw new DaemonClientException(ClientError.BadResponse);
        try
        {
            return JsonSerializer.Deserialize<Response>(reply) ?? throw new DaemonClientException(ClientError.BadResponse);
        }
        catch (DaemonClientException)
        {
            throw;
        }
        catch (Exception)
        {
            // Invalid JSON, a wrong type, or anything a response converter refuses.
            throw new DaemonClientException(ClientError.BadResponse);
        }
    }

    /// <summary>
    /// Makes the client end of the pipe. On Windows it asks only for the rights the service grants every user (read and write data, read attributes and permissions), never the right to
    /// create pipe instances, and it allows the server only to identify the caller, not to act as it, so a program posing as the service could never borrow an administrator's rights.
    /// </summary>
    private static NamedPipeClientStream OpenPipe(string pipeName)
    {
        if (!OperatingSystem.IsWindows()) return new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        const PipeAccessRights rights = PipeAccessRights.ReadData | PipeAccessRights.WriteData | PipeAccessRights.ReadAttributes | PipeAccessRights.ReadExtendedAttributes | PipeAccessRights.ReadPermissions;
        return new NamedPipeClientStream(".", pipeName, rights, PipeOptions.Asynchronous, System.Security.Principal.TokenImpersonationLevel.Identification, HandleInheritability.None);
    }

    /// <summary>
    /// Connects the pipe, waiting up to 2 seconds. A missing pipe shows up differently on each system (a timeout on Windows, an I/O or socket error on Unix), and all of them mean no service is listening.
    /// </summary>
    private static async Task ConnectAsync(NamedPipeClientStream pipe, CancellationToken ct)
    {
        try
        {
            await pipe.ConnectAsync((int)ConnectTimeout.TotalMilliseconds, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new DaemonClientException(ClientError.NotRunning);
        }
        catch (Exception e) when (e is TimeoutException or IOException or System.Net.Sockets.SocketException or UnauthorizedAccessException)
        {
            // UnauthorizedAccessException: the pipe exists but this user may not open it, which no caller can fix either, so it reads as not available.
            throw new DaemonClientException(ClientError.NotRunning);
        }
    }

    /// <summary>Writes the whole request line. Returns true when the service closed the connection early (for example after rejecting an oversized request), so the caller still tries to read the reply it sent first.</summary>
    private static async Task<bool> WriteRequestAsync(NamedPipeClientStream pipe, byte[] bytes, CancellationToken token)
    {
        try
        {
            await pipe.WriteAsync(bytes, token).ConfigureAwait(false);
            await pipe.FlushAsync(token).ConfigureAwait(false);
            return false;
        }
        catch (IOException)
        {
            return true;
        }
        catch (ObjectDisposedException)
        {
            return true;
        }
    }

    /// <summary>Reads until a newline or the end of the stream and returns the bytes before the newline.</summary>
    private static async Task<byte[]> ReadLineAsync(NamedPipeClientStream pipe, bool writeBroke, CancellationToken token)
    {
        var collected = new List<byte>();
        byte[] chunk = new byte[4096];
        while (true)
        {
            int count;
            try
            {
                count = await pipe.ReadAsync(chunk, token).ConfigureAwait(false);
            }
            catch (Exception e) when (e is IOException or ObjectDisposedException)
            {
                // A reset after a failed write means the service hung up without a reply; otherwise keep what arrived.
                if (writeBroke) return [];
                break;
            }
            if (count == 0) break;
            collected.AddRange(chunk.AsSpan(0, count).ToArray());
            if (collected.Contains((byte)'\n')) break;
            if (collected.Count > MaxResponseBytes) throw new DaemonClientException(ClientError.BadResponse);
        }
        int newline = collected.IndexOf((byte)'\n');
        return (newline >= 0 ? collected.GetRange(0, newline) : collected).ToArray();
    }
}
