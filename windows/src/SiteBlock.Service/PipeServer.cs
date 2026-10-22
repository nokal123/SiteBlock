using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using SiteBlock.Core;

namespace SiteBlock.Service;

/// <summary>Why the pipe server could not start.</summary>
public sealed class PipeServerException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// Accepts connections on the service's named pipe and turns each into exactly one request and one response, following 03-daemon-cli-app.md § SocketServer with the
/// Windows differences in 06-windows.md § PipeServer. It does no policy work: it reads who is calling, applies the connection limits, reads one line, and passes the
/// decoded request with the caller's identity to the handler.
/// </summary>
public sealed class PipeServer
{
    /// <summary>The largest request line accepted, counting the bytes before the newline. A line of exactly this many bytes is accepted; one more is answered with badRequest.</summary>
    public const int MaxRequestBytes = 64 * 1024;
    /// <summary>How long the server waits for the whole request line before giving up on a client.</summary>
    public const int ClientTimeoutSeconds = 2;
    // The shortest read a connection gets for its request, even when the hand-off to its worker took most of the 2 seconds.
    private const long MinimumFirstReadMs = 250;
    // How many connections of one account may wait for their client to hang up at once. These waits hold a pipe instance but no limiter slot, so without a cap one
    // account that never hangs up could use up every pipe instance, including those the limiter keeps for administrators.
    private const int MaxHangUpWaitsPerUser = 4;
    /// <summary>How many pipe instances may exist at once, which is how many connections can be open at once.</summary>
    public const int MaxInstances = 32;
    /// <summary>The identity every sandbox caller gets, so admin-only commands are refused in tests as they are for a normal user on the Mac.</summary>
    public static readonly Peer SandboxPeer = new("sandbox-user", false);

    // The longest a handler may take before the client gets an internal-error answer.
    private static readonly TimeSpan HandlerTimeout = TimeSpan.FromSeconds(30);
    // The longest socket path macOS accepts (sockaddr_un holds 104 bytes); a sandbox pipe on macOS and Linux is a socket file at its full path.
    private const int MaxUnixSocketPathBytes = 103;
    // The cap on what is read and thrown away after an oversized request, so a client that never stops sending cannot hold the connection.
    private const int MaxDrainBytes = 8 * 1024 * 1024;

    private readonly string _pipeName;
    private readonly bool _sandbox;
    private readonly Func<Request, Peer, Task<Response>> _handler;
    private readonly Action<Peer> _onRejected;
    private readonly Log _log;
    // At most 4 connections at a time per non-admin caller and 32 in all, the last 4 kept for administrators.
    private readonly ConnectionLimiter _limiter = new();
    // How many hang-up waits each account has running, by user ID.
    private readonly Dictionary<string, int> _hangUpWaits = new(StringComparer.Ordinal);
    private readonly Lock _hangUpGate = new();
    private readonly CancellationTokenSource _stop = new();
    private Task? _acceptLoop;

    /// <summary>
    /// Creates a server for the pipe. <paramref name="handler"/> is called once per valid request with the caller's identity; <paramref name="onRejected"/> is told about each request or
    /// connection turned away before the handler sees it. In a sandbox every caller is <see cref="SandboxPeer"/> and the pipe name is the sandbox's own.
    /// </summary>
    public PipeServer(string pipeName, bool sandbox, Func<Request, Peer, Task<Response>> handler, Action<Peer> onRejected, Log log)
    {
        _pipeName = pipeName;
        _sandbox = sandbox;
        _handler = handler;
        _onRejected = onRejected;
        _log = log;
    }

    /// <summary>
    /// Checks whether this service may use the pipe at all, before it does anything else: it throws when the sandbox pipe path is too long for a socket, or when a live service already
    /// answers a status request on the pipe (this process is then a second copy and must leave everything alone).
    /// </summary>
    public void CheckAvailable()
    {
        // A Unix socket path must fit in 104 bytes; a longer sandbox folder is refused with a sentence instead of failing deep inside .NET.
        if (!OperatingSystem.IsWindows() && Path.IsPathFullyQualified(_pipeName) && System.Text.Encoding.UTF8.GetByteCount(_pipeName) > MaxUnixSocketPathBytes)
        {
            throw new PipeServerException($"The pipe path is not usable (it must be 1 to {MaxUnixSocketPathBytes} bytes): {_pipeName}");
        }
        if (AnotherServiceAnswers()) throw new PipeServerException("Another siteblockd is already answering on this pipe.");
    }

    /// <summary>
    /// Starts serving; call <see cref="CheckAvailable"/> first. On macOS and Linux a socket file nobody answers on (left by a killed service) is removed first.
    /// Throws <see cref="PipeServerException"/> when the pipe cannot be created.
    /// </summary>
    public void Start()
    {
        if (!OperatingSystem.IsWindows() && Path.IsPathFullyQualified(_pipeName))
        {
            try { File.Delete(_pipeName); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw new PipeServerException($"Could not remove the old pipe file: {error.Message}", error); }
        }
        // The first instance is created here, so a failure (another program already owns the name) is reported to the caller instead of being lost in the accept loop.
        NamedPipeServerStream first;
        try
        {
            first = CreateInstance(isFirst: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or PlatformNotSupportedException)
        {
            throw new PipeServerException($"Could not create the pipe: {error.Message}", error);
        }
        _acceptLoop = Task.Run(() => AcceptLoopAsync(first, _stop.Token));
    }

    /// <summary>Stops accepting connections and, on macOS and Linux, removes the socket file. Connections already being served finish on their own; this never waits for them.</summary>
    public void Stop()
    {
        if (_stop.IsCancellationRequested) return;
        _stop.Cancel();
        try { _acceptLoop?.Wait(TimeSpan.FromSeconds(2)); } catch (AggregateException) { }
        if (!OperatingSystem.IsWindows() && Path.IsPathFullyQualified(_pipeName))
        {
            try { File.Delete(_pipeName); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    /// <summary>True when a service already answers a status request on this pipe within 2 seconds.</summary>
    private bool AnotherServiceAnswers()
    {
        try
        {
            new DaemonClient(_pipeName, TimeSpan.FromSeconds(2)).Send(new Request(Command.Status));
            return true;
        }
        catch (DaemonClientException)
        {
            return false;
        }
    }

    /// <summary>Creates one pipe instance. On Windows it carries the access list from 06-windows.md § PipeServer, and the first one refuses to join a pipe some other program created first.</summary>
    private NamedPipeServerStream CreateInstance(bool isFirst)
    {
        if (!OperatingSystem.IsWindows()) return new NamedPipeServerStream(_pipeName, PipeDirection.InOut, MaxInstances, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        return CreateWindowsInstance(_pipeName, isFirst, BuildSecurity(_sandbox));
    }

    /// <summary>
    /// Creates one Windows pipe instance with CreateNamedPipe directly, so every flag is certain: overlapped I/O (FILE_FLAG_OVERLAPPED), which is what lets the 2-second limits cancel a
    /// read that is waiting for a silent client without holding a thread; FILE_FLAG_FIRST_PIPE_INSTANCE on the first one, so creation fails when the name already exists and a program that
    /// grabbed the name first cannot pose as the service; PIPE_REJECT_REMOTE_CLIENTS, so Windows itself refuses connections from other computers; and the access list.
    /// Throws <see cref="IOException"/> when Windows refuses (for example error 231 while every instance is busy, or error 5 when another program already owns the name).
    /// </summary>
    [SupportedOSPlatform("windows")]
    private static NamedPipeServerStream CreateWindowsInstance(string name, bool isFirst, PipeSecurity security)
    {
        const uint pipeAccessDuplex = 0x3, fileFlagOverlapped = 0x40000000, fileFlagFirstPipeInstance = 0x00080000;
        // PIPE_TYPE_BYTE, PIPE_READMODE_BYTE and PIPE_WAIT are all 0.
        const uint pipeRejectRemoteClients = 0x8;
        byte[] descriptor = security.GetSecurityDescriptorBinaryForm();
        var pinned = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
        try
        {
            var attributes = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), SecurityDescriptor = pinned.AddrOfPinnedObject(), InheritHandle = 0 };
            uint openMode = pipeAccessDuplex | fileFlagOverlapped | (isFirst ? fileFlagFirstPipeInstance : 0);
            var handle = CreateNamedPipeW(@"\\.\pipe\" + name, openMode, pipeRejectRemoteClients, MaxInstances, 4096, 4096, 0, ref attributes);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastPInvokeError();
                handle.Dispose();
                throw new IOException($"CreateNamedPipe failed with Windows error {error}", unchecked((int)0x80070000) | error);
            }
            return new NamedPipeServerStream(PipeDirection.InOut, isAsync: true, isConnected: false, handle);
        }
        finally
        {
            pinned.Free();
        }
    }

    /// <summary>SECURITY_ATTRIBUTES from minwinbase.h.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public int Length;
        public IntPtr SecurityDescriptor;
        public int InheritHandle;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern Microsoft.Win32.SafeHandles.SafePipeHandle CreateNamedPipeW(string name, uint openMode, uint pipeMode, uint maxInstances, uint outBufferSize, uint inBufferSize, uint defaultTimeout, ref SecurityAttributes attributes);

    /// <summary>
    /// What every signed-in user may do with the pipe: read and write data, and read its attributes and permissions. It leaves out the right to create pipe instances, so no other program
    /// can add its own listening instance to the service's pipe and pose as the service. <see cref="DaemonClient"/> asks for exactly these rights.
    /// </summary>
    internal const PipeAccessRights ClientRights = PipeAccessRights.ReadData | PipeAccessRights.WriteData | PipeAccessRights.ReadAttributes | PipeAccessRights.ReadExtendedAttributes | PipeAccessRights.ReadPermissions;

    /// <summary>
    /// The pipe's access list: <see cref="ClientRights"/> for every signed-in user (Authenticated Users), full control for SYSTEM and Administrators, and everything denied to NETWORK, so another
    /// computer can never reach it. In a sandbox the account running the service also gets full control, because creating each further instance needs that right.
    /// </summary>
    [SupportedOSPlatform("windows")]
    internal static PipeSecurity BuildSecurity(bool sandbox)
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.NetworkSid, null), PipeAccessRights.FullControl, AccessControlType.Deny));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null), ClientRights, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        if (sandbox)
        {
            using var self = WindowsIdentity.GetCurrent();
            if (self.User is SecurityIdentifier user) security.AddAccessRule(new PipeAccessRule(user, PipeAccessRights.FullControl, AccessControlType.Allow));
        }
        return security;
    }

    /// <summary>
    /// Waits for a client on one instance, hands the connection to its own task, and creates the next instance, until stopped. When every instance is busy, creating the next one fails
    /// and the loop waits a moment and tries again.
    /// </summary>
    private async Task AcceptLoopAsync(NamedPipeServerStream first, CancellationToken stop)
    {
        NamedPipeServerStream? waiting = first;
        while (!stop.IsCancellationRequested)
        {
            if (waiting is null)
            {
                try
                {
                    waiting = CreateInstance(isFirst: false);
                }
                catch (IOException)
                {
                    // Every instance is in use. A finished connection frees one shortly.
                    try { await Task.Delay(100, stop).ConfigureAwait(false); } catch (OperationCanceledException) { break; }
                    continue;
                }
                catch (Exception error)
                {
                    // Anything else is logged and retried a second later; the loop must never end on its own, or the service would run on with no pipe.
                    _log.Write($"cannot create a pipe instance: {error.GetType().Name}");
                    try { await Task.Delay(1000, stop).ConfigureAwait(false); } catch (OperationCanceledException) { break; }
                    continue;
                }
            }
            try
            {
                await waiting.WaitForConnectionAsync(stop).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (IOException)
            {
                // The client went away between connecting and being accepted; this instance is spent.
                waiting.Dispose();
                waiting = null;
                continue;
            }
            catch (Exception error)
            {
                _log.Write($"waiting for a pipe client failed: {error.GetType().Name}");
                waiting.Dispose();
                waiting = null;
                try { await Task.Delay(1000, stop).ConfigureAwait(false); } catch (OperationCanceledException) { break; }
                continue;
            }
            var connected = waiting;
            var acceptedAt = DateTime.UtcNow;
            // The 2-second request limit counts from here, on Windows' uptime counter, so neither a slow hand-off to a worker thread nor a clock change stretches it.
            long acceptedTick = Environment.TickCount64;
            waiting = null;
            _ = Task.Run(() => ServeConnectionAsync(connected, acceptedAt, acceptedTick));
        }
        waiting?.Dispose();
    }

    /// <summary>Reads who is on the other end, applies the connection limits, and serves the connection. A connection over its limit is closed at once without a reply.</summary>
    private async Task ServeConnectionAsync(NamedPipeServerStream pipe, DateTime acceptedAt, long acceptedTick)
    {
        await using (pipe)
        {
            // The identity is read right away, before any data, because the connection limits depend on it.
            Peer peer = _sandbox ? SandboxPeer : OperatingSystem.IsWindows() ? ReadPeer(pipe, acceptedAt) : Peer.Unknown;
            if (!_limiter.Admit(peer))
            {
                _onRejected(peer);
                return;
            }
            // The slot counts requests being served. It is given back exactly once: just before the reply is written (see ServeAsync), or here when no reply goes out.
            bool released = false;
            void ReleaseSlot()
            {
                if (released) return;
                released = true;
                _limiter.Release(peer);
            }
            bool answered = false;
            try
            {
                answered = await ServeAsync(pipe, peer, ReleaseSlot, acceptedTick).ConfigureAwait(false);
            }
            catch (Exception error) when (error is IOException or ObjectDisposedException or OperationCanceledException)
            {
                // The client vanished; there is nobody to answer.
            }
            finally
            {
                ReleaseSlot();
            }
            // On Windows, closing the server end throws away bytes the client has not read yet. The client hangs up as soon as it has read its line, so the server waits for that
            // hang-up (a read that ends), for at most 2 seconds; it is a cancellable read, so a client that never reads cannot hold the instance.
            // An account already at its cap of waits gets no wait: its connection is closed at once, which can cost a client that never hangs up its reply.
            if (answered && TryStartHangUpWait(peer))
            {
                try { await DrainAsync(pipe).ConfigureAwait(false); }
                finally { EndHangUpWait(peer); }
            }
        }
    }

    /// <summary>Counts one more hang-up wait for the caller's account and returns true, or returns false when the account already has <see cref="MaxHangUpWaitsPerUser"/> running.</summary>
    private bool TryStartHangUpWait(Peer peer)
    {
        lock (_hangUpGate)
        {
            int running = _hangUpWaits.GetValueOrDefault(peer.UserId);
            if (running >= MaxHangUpWaitsPerUser) return false;
            _hangUpWaits[peer.UserId] = running + 1;
            return true;
        }
    }

    /// <summary>Counts one hang-up wait of the caller's account as finished; an account with none left has no entry.</summary>
    private void EndHangUpWait(Peer peer)
    {
        lock (_hangUpGate)
        {
            int running = _hangUpWaits.GetValueOrDefault(peer.UserId) - 1;
            if (running <= 0) _hangUpWaits.Remove(peer.UserId);
            else _hangUpWaits[peer.UserId] = running;
        }
    }

    /// <summary>
    /// The caller's identity, read from the process on the other end of the pipe: GetNamedPipeClientProcessId gives its process ID, and that process's token gives its SID and whether it is
    /// SYSTEM or an elevated member of Administrators. It needs no data from the client (impersonating the client is refused until data has been read). A process that started after the
    /// connection was accepted is a different process that reused the ID, and is not trusted. Any failure gives <see cref="Peer.Unknown"/>, so it can never grant an admin-only command.
    /// </summary>
    [SupportedOSPlatform("windows")]
    internal static Peer ReadPeer(NamedPipeServerStream pipe, DateTime acceptedAtUtc)
    {
        try
        {
            if (!PeerNative.GetNamedPipeClientProcessId(pipe.SafePipeHandle, out uint processId)) return Peer.Unknown;
            using var process = PeerNative.OpenProcess(PeerNative.ProcessQueryLimitedInformation, false, processId);
            if (process.IsInvalid) return Peer.Unknown;
            if (!PeerNative.GetProcessTimes(process, out long created, out _, out _, out _) || DateTime.FromFileTimeUtc(created) > acceptedAtUtc) return Peer.Unknown;
            if (!PeerNative.OpenProcessToken(process, PeerNative.TokenQuery | PeerNative.TokenDuplicate, out var token)) return Peer.Unknown;
            using (token)
            {
                using var identity = new WindowsIdentity(token.DangerousGetHandle());
                if (identity.User is not SecurityIdentifier user) return Peer.Unknown;
                // The Administrators check sees only enabled groups, so an administrator whose program was not started with "Run as administrator" is not an admin here.
                bool isAdmin = identity.IsSystem || new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
                return new Peer(user.Value, isAdmin);
            }
        }
        catch (Exception)
        {
            return Peer.Unknown;
        }
    }

    /// <summary>What reading a request line produced.</summary>
    private enum ReadKind
    {
        /// A complete request line, without its newline.
        Line,
        /// More than the size limit arrived before any newline.
        TooLarge,
        /// The client sent no complete line within the time limit.
        TimedOut,
        /// The client closed the connection without sending anything.
        Empty,
    }

    /// <summary>
    /// Reads bytes until a newline, the end of the stream, or the size limit, within 2 seconds of the connection being accepted, so a client that sends one byte at a time cannot hold the connection open.
    /// Only the bytes that just arrived are searched for the newline, so a large request costs time in proportion to its size.
    /// </summary>
    private static async Task<(ReadKind Kind, byte[] Line)> ReadRequestLineAsync(PipeStream pipe, long acceptedTick)
    {
        // The limit counts from when the connection was accepted, not from when this read starts; time already spent (identity, limits, a busy thread pool) is taken off.
        // A request that is already waiting still gets a short read when the hand-off to this worker was slow, so a busy service never refuses a request it has in hand.
        long remainingMs = Math.Max(MinimumFirstReadMs, ClientTimeoutSeconds * 1000L - (Environment.TickCount64 - acceptedTick));
        using var deadline = new CancellationTokenSource(TimeSpan.FromMilliseconds(remainingMs));
        var collected = new MemoryStream();
        byte[] chunk = new byte[4096];
        while (true)
        {
            int count;
            try
            {
                count = await pipe.ReadAsync(chunk, deadline.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return (ReadKind.TimedOut, []);
            }
            catch (IOException)
            {
                // A broken connection is treated like a hang-up.
                count = 0;
            }
            // End of stream: whatever arrived is the request, even without a newline.
            if (count == 0) return collected.Length == 0 ? (ReadKind.Empty, []) : (ReadKind.Line, collected.ToArray());
            long alreadyCollected = collected.Length;
            collected.Write(chunk, 0, count);
            int newlineOffset = Array.IndexOf(chunk, (byte)'\n', 0, count);
            if (newlineOffset >= 0)
            {
                long newline = alreadyCollected + newlineOffset;
                return newline > MaxRequestBytes ? (ReadKind.TooLarge, []) : (ReadKind.Line, collected.GetBuffer().AsSpan(0, (int)newline).ToArray());
            }
            if (collected.Length > MaxRequestBytes) return (ReadKind.TooLarge, []);
        }
    }

    /// <summary>Reads and throws away what a client is still sending after an oversized request, for at most 2 seconds and 8 MB, so the client's own write finishes and it can read the reply.</summary>
    private static async Task DrainAsync(PipeStream pipe)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(ClientTimeoutSeconds));
        byte[] buffer = new byte[16 * 1024];
        long total = 0;
        try
        {
            while (total < MaxDrainBytes)
            {
                int count = await pipe.ReadAsync(buffer, deadline.Token).ConfigureAwait(false);
                if (count <= 0) return;
                total += count;
            }
        }
        catch (Exception error) when (error is OperationCanceledException or IOException)
        {
        }
    }

    /// <summary>Turns a request that could not be decoded into one readable sentence.</summary>
    private static string Describe(JsonException error) => $"The request could not be understood: {error.Message}";

    /// <summary>
    /// Serves one admitted connection: reads the request, calls the handler, and writes the reply plus a newline. Every outcome ends in a reply or a clean close.
    /// Returns true when the caller should still wait for the client to hang up (a reply went out and nothing was drained yet).
    /// </summary>
    private async Task<bool> ServeAsync(NamedPipeServerStream pipe, Peer peer, Action releaseSlot, long acceptedTick)
    {
        var (kind, line) = await ReadRequestLineAsync(pipe, acceptedTick).ConfigureAwait(false);
        Response response;
        bool needsDrain = false;
        switch (kind)
        {
            case ReadKind.Empty:
                return false;
            case ReadKind.TimedOut:
                response = Response.Failure(ErrorCode.BadRequest, $"No request arrived within {ClientTimeoutSeconds} seconds.");
                _onRejected(peer);
                break;
            case ReadKind.TooLarge:
                response = Response.Failure(ErrorCode.BadRequest, $"The request is larger than {MaxRequestBytes / 1024} KB.");
                needsDrain = true;
                _onRejected(peer);
                break;
            default:
                Request request;
                try
                {
                    request = JsonCoding.Decode<Request>(line);
                }
                catch (JsonException error)
                {
                    response = Response.Failure(ErrorCode.BadRequest, Describe(error));
                    _onRejected(peer);
                    break;
                }
                // The identity comes from the pipe, read when the connection was accepted, never from the request, so a client cannot claim to be an administrator.
                try
                {
                    // A handler that never returns (a stalled engine thread) must not hold this connection's slot forever.
                    response = await _handler(request, peer).WaitAsync(HandlerTimeout).ConfigureAwait(false);
                }
                catch (Exception)
                {
                    response = Response.Failure(ErrorCode.Internal, "The SiteBlock service could not handle the request.");
                }
                break;
        }

        byte[] reply;
        try
        {
            reply = JsonCoding.Encode(response);
        }
        catch (JsonException)
        {
            // If encoding somehow fails, a fixed failure line is sent instead of nothing.
            reply = """{"error":"The reply could not be encoded.","errorCode":"internal","ok":false}"""u8.ToArray();
        }
        // The slot is given back before the reply is written, not after. A client can read its reply the instant the bytes are out and open its next connection at once; if the slot were
        // freed only after the write returned, that next connection could arrive while the finished one still counted against the same user and be turned away.
        releaseSlot();
        using var writeLimit = new CancellationTokenSource(TimeSpan.FromSeconds(ClientTimeoutSeconds));
        // The reply goes out before the drain: it is small enough for the pipe's buffer, and the client reads it once its own oversized write has been taken off its hands.
        await pipe.WriteAsync(reply.Append((byte)'\n').ToArray(), writeLimit.Token).ConfigureAwait(false);
        await pipe.FlushAsync(writeLimit.Token).ConfigureAwait(false);
        // After an oversized request the rest of it is read and thrown away here, so the client's own write finishes and it can read the refusal; that read also waits for the hang-up.
        if (needsDrain) await DrainAsync(pipe).ConfigureAwait(false);
        return !needsDrain;
    }
}

/// <summary>The Windows calls <see cref="PipeServer.ReadPeer"/> uses to find out who is on the other end of a pipe connection.</summary>
[SupportedOSPlatform("windows")]
internal static class PeerNative
{
    /// PROCESS_QUERY_LIMITED_INFORMATION: enough to read a process's times and open its token, and granted for almost every process.
    public const uint ProcessQueryLimitedInformation = 0x1000;
    /// TOKEN_QUERY: read the token's user and groups.
    public const uint TokenQuery = 0x0008;
    /// TOKEN_DUPLICATE: WindowsIdentity duplicates the token it is given.
    public const uint TokenDuplicate = 0x0002;

    /// <summary>Gets the ID of the process that opened the client end of the pipe.</summary>
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetNamedPipeClientProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint processId);

    /// <summary>Opens a process with the given rights; the handle is invalid when it fails.</summary>
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern Microsoft.Win32.SafeHandles.SafeProcessHandle OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint processId);

    /// <summary>Reads when the process was created (as a FILETIME in UTC), and when it exited and how long it ran.</summary>
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetProcessTimes(Microsoft.Win32.SafeHandles.SafeProcessHandle process, out long creation, out long exit, out long kernel, out long user);

    /// <summary>Opens the process's access token.</summary>
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool OpenProcessToken(Microsoft.Win32.SafeHandles.SafeProcessHandle process, uint access, out Microsoft.Win32.SafeHandles.SafeAccessTokenHandle token);
}
