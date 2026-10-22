using System.Text;
using System.Text.Json.Nodes;
using SiteBlock.Core;
using SiteBlock.Integration.Tests.Support;

namespace SiteBlock.Integration.Tests.Daemon;

// Raw bytes over the real sandbox pipe. Expected values: 01-overview-and-data.md § Wire Protocol (one JSON line each way; a line of up to 65,536 bytes accepted;
// the 2-second wait for the request line), 03-daemon-cli-app.md § SocketServer (badRequest answers and the connection limits), 05-testing-and-operations.md § Integration Tests.
public sealed class WireProtocolTests
{
    // Asserts a reply is a refusal with the given code and a readable sentence, and carries no status.
    private static void AssertRefused(JsonObject reply, string code)
    {
        Assert.False((bool)reply["ok"]!);
        Assert.Equal(code, (string?)reply["errorCode"]);
        Assert.False(string.IsNullOrWhiteSpace((string?)reply["error"]));
    }

    [Fact]
    public void InvalidJson_GetsBadRequest()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);

        AssertRefused(RawConnection.Exchange(daemon.PipePath, "{\"command\": \"status\""), "badRequest");
        AssertRefused(RawConnection.Exchange(daemon.PipePath, "not json at all"), "badRequest");
        AssertRefused(RawConnection.Exchange(daemon.PipePath, "[\"status\"]"), "badRequest");
    }

    [Fact]
    public void UnknownOrMissingCommand_GetsBadRequest()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);

        AssertRefused(RawConnection.Exchange(daemon.PipePath, "{\"command\":\"frobnicate\"}"), "badRequest");
        AssertRefused(RawConnection.Exchange(daemon.PipePath, "{\"domain\":\"reddit.com\"}"), "badRequest");
        AssertRefused(RawConnection.Exchange(daemon.PipePath, "{\"command\":42}"), "badRequest");
    }

    [Fact]
    public void ValidStatusLine_GetsOneJsonLineWithTheSnapshot()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);

        var reply = RawConnection.Exchange(daemon.PipePath, "{\"command\":\"status\"}");

        Assert.True((bool)reply["ok"]!);
        var status = (JsonObject)reply["status"]!;
        Assert.False((bool)status["passwordSet"]!);
        Assert.Equal(2, (int)status["delaySeconds"]!);
        Assert.True((bool)status["adultFilterEnabled"]!);
        Assert.Empty((JsonArray)status["blocked"]!);
        // 01-overview-and-data.md § StatusSnapshot says "<version> (build <n>)" while 02 § Models and 03 § siteblock CLI say the bare siteBlockVersion; both readings start with "<series>.<n>".
        Assert.Matches(@"^\d+\.\d+\.\d+( \(build \d+\))?$", (string)status["version"]!);
    }

    // A status request padded with an ignored field so its line is exactly the given number of bytes (without the newline).
    private static string StatusLineOfLength(int bytes)
    {
        const string head = "{\"command\":\"status\",\"pad\":\"";
        const string tail = "\"}";
        string line = head + new string('a', bytes - head.Length - tail.Length) + tail;
        Assert.Equal(bytes, Encoding.UTF8.GetByteCount(line));
        return line;
    }

    [Fact]
    public void RequestLineOfExactly65536Bytes_IsAccepted()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);

        var reply = RawConnection.Exchange(daemon.PipePath, StatusLineOfLength(65_536));

        Assert.True((bool)reply["ok"]!, reply.ToJsonString());
    }

    [Fact]
    public void RequestLineOf65537Bytes_GetsBadRequestAndTheDaemonKeepsAnswering()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);

        AssertRefused(RawConnection.Exchange(daemon.PipePath, StatusLineOfLength(65_537)), "badRequest");
        // A far larger request with no newline at all is refused the same way.
        AssertRefused(RawConnection.Exchange(daemon.PipePath, new string('x', 300_000)), "badRequest");
        Assert.True(daemon.Send(new Request(Command.Status)).Ok);
    }

    [Fact]
    public async Task SilentClient_GetsBadRequestAfterTwoSecondsWhileOtherClientsAreAnswered()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        using var silent = RawConnection.Open(daemon.PipePath);
        var clock = System.Diagnostics.Stopwatch.StartNew();
        string? reply = null;
        TimeSpan silentAnsweredAt = TimeSpan.Zero;
        var waiting = Task.Run(() => { reply = silent.ReadLine(10); silentAnsweredAt = clock.Elapsed; });

        // While the silent client waits, a normal client is served.
        await Task.Delay(300);
        Assert.True(daemon.Send(new Request(Command.Status)).Ok);
        TimeSpan otherAnsweredAt = clock.Elapsed;
        await waiting;

        // The point is that the normal client does not wait behind the silent one. A server that served one connection at a time would answer it only after the silent
        // client's 2-second limit ran out, so it must be answered first. This compares the two moments rather than holding the normal answer to a fixed 1.5 seconds,
        // because that bound failed under load (1.89 s, with every test class running in parallel) while the order was still right.
        Assert.True(otherAnsweredAt < silentAnsweredAt, $"the normal client was answered at {otherAnsweredAt.TotalSeconds:0.00} s, not before the silent client's timeout reply at {silentAnsweredAt.TotalSeconds:0.00} s");
        Assert.False(string.IsNullOrEmpty(reply), "the silent client got no reply");
        var json = (JsonObject)JsonNode.Parse(reply!)!;
        AssertRefused(json, "badRequest");
        Assert.Equal("No request arrived within 2 seconds.", (string?)json["error"]);
        Assert.InRange(silentAnsweredAt.TotalSeconds, 1.6, 8);
    }

    [Fact]
    public void FifthSimultaneousConnectionFromOneUser_IsClosedWithoutAReplyAndTheSlotFreesLater()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        // Each idle connection holds its slot only for the server's 2-second request limit, which starts when it is admitted. On a slow machine opening four connections and
        // checking a fifth can take longer than that, the first slots are given back, and the fifth is rightly admitted; such an attempt proves nothing, so it is tried again
        // (with the slots freed first). The limit is asserted only on an attempt that finished inside the window.
        const double windowSeconds = 1.8;
        string? fifthReply = null;
        double elapsed = 0;
        for (int attempt = 0; attempt < 3; attempt++)
        {
            var clock = System.Diagnostics.Stopwatch.StartNew();
            // Every sandbox caller is the same user, so four idle connections use up that user's slots.
            var idle = Enumerable.Range(0, 4).Select(_ => RawConnection.Open(daemon.PipePath)).ToList();
            try
            {
                Thread.Sleep(100);
                using (var fifth = RawConnection.Open(daemon.PipePath))
                {
                    fifth.Write("{\"command\":\"status\"}\n");
                    // The window is measured to the moment the fifth request is out; the read below may rightly wait.
                    elapsed = clock.Elapsed.TotalSeconds;
                    fifthReply = fifth.ReadLine(1.5);
                }
                // The idle ones are answered with the read timeout and their slots are given back.
                foreach (var connection in idle)
                {
                    string? idleReply = connection.ReadLine(8);
                    Assert.True(idleReply?.Contains("badRequest") == true, $"an idle connection should get the 2-second badRequest, but got {(idleReply is null ? "no reply and no close within 8 s" : $"\"{idleReply}\"")} ({clock.Elapsed.TotalSeconds:0.00} s after the first connection)");
                }
            }
            finally
            {
                foreach (var connection in idle) connection.Dispose();
            }
            if (elapsed <= windowSeconds) break;
        }
        Assert.True(elapsed <= windowSeconds, $"no attempt checked the fifth connection while the four were still holding their slots (last took {elapsed:0.00} s)");
        // "" means the server closed the fifth connection without a byte; anything else is a reply it should never have sent, and null means it neither answered nor closed.
        Assert.True(fifthReply == "", $"the fifth connection should be closed without a reply, but got {(fifthReply is null ? "no close within 1.5 s" : $"\"{fifthReply}\"")} after {elapsed:0.00} s");
        Assert.True(Wait.Until(() => { try { return RawConnection.Exchange(daemon.PipePath, "{\"command\":\"status\"}", 3)["ok"]!.GetValue<bool>(); } catch (Exception) { return false; } }, 5));
    }

    // Sends a status line and returns true when an ok reply arrives, retrying while the connection is closed without a reply (a slot still being released).
    private static bool StatusPatiently(string pipePath) => Wait.Until(() =>
    {
        try { return RawConnection.Exchange(pipePath, "{\"command\":\"status\"}", 3)["ok"]!.GetValue<bool>(); }
        catch (Exception error) when (error is Xunit.Sdk.XunitException or IOException or TimeoutException) { return false; }
    }, 3);

    [Fact]
    public void ManySequentialConnectionsOfEveryEndingKind_NeverLeakSlots()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);

        // Each kind of ending must give its slot back; a leak of one slot per kind would lock the user out after a few rounds.
        for (int round = 0; round < 6; round++)
        {
            AssertRefused(RawConnection.Exchange(daemon.PipePath, "{bad json"), "badRequest");
            AssertRefused(RawConnection.Exchange(daemon.PipePath, StatusLineOfLength(70_000)), "badRequest");
            using (var vanished = RawConnection.Open(daemon.PipePath)) vanished.Write("{\"comm");
            using (var silentHangUp = RawConnection.Open(daemon.PipePath)) { }
            Assert.True(StatusPatiently(daemon.PipePath), $"round {round}: status never answered");
        }

        // All four of the user's slots are free again: four connections held open together are all admitted and answered.
        Thread.Sleep(300);
        var held = Enumerable.Range(0, 4).Select(_ => RawConnection.Open(daemon.PipePath)).ToList();
        try
        {
            Thread.Sleep(200);
            foreach (var connection in held) connection.Write("{\"command\":\"status\"}\n");
            foreach (var connection in held) Assert.Contains("\"ok\":true", connection.ReadLine(5) ?? "");
        }
        finally
        {
            foreach (var connection in held) connection.Dispose();
        }
    }
}
