using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using SiteBlock.Integration.Tests.Support;

namespace SiteBlock.Integration.Tests.Daemon;

// A client that trickles its request in. Expected values come from 03-daemon-cli-app.md § SocketServer step 5 ("A client that sends no complete line within 2 seconds receives
// badRequest with "No request arrived within 2 seconds." and is disconnected") and 06-windows.md § PipeServer step 4 (one line read with a 2-second limit). The limit is on
// the whole line, so a sender that keeps sending a byte now and then cannot hold the connection open past it.
public sealed class SlowSenderTests
{
    [Fact]
    public async Task ValidRequestSentOneByteAtATimeOverMoreThanTwoSeconds_GetsBadRequestAboutTwoSecondsAfterConnecting()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        byte[] line = Encoding.UTF8.GetBytes("{\"command\":\"status\"}\n");
        // 21 bytes, 150 ms apart: the full line would take about 3.1 seconds, so a server that waited for it (or reset its wait on each byte) would answer the status request.
        Assert.True(line.Length * 0.15 > 3.0);

        using var slow = RawConnection.Open(daemon.PipePath);
        var sinceConnect = Stopwatch.StartNew();
        using var stop = new CancellationTokenSource();
        var sender = Task.Run(() =>
        {
            foreach (byte b in line)
            {
                if (stop.IsCancellationRequested) return;
                // Once the server has answered and closed, a write may fail; that ends the sending and is not what this test checks.
                try { slow.Write([b]); } catch (Exception) { return; }
                Thread.Sleep(150);
            }
        });
        string? reply = slow.ReadLine(6);
        TimeSpan elapsed = sinceConnect.Elapsed;
        stop.Cancel();
        await sender.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.False(string.IsNullOrEmpty(reply), "the slow sender got no reply");
        var json = (JsonObject)JsonNode.Parse(reply!)!;
        Assert.False((bool)json["ok"]!, reply);
        Assert.Equal("badRequest", (string?)json["errorCode"]);
        Assert.Equal("No request arrived within 2 seconds.", (string?)json["error"]);
        // The reply's wording and error code above already prove the server cut the request off at its 2-second limit: a server that waited for the whole
        // 3.1-second line, or reset its wait on each byte, would answer the status request instead. So the time only has to show the cut came after the
        // limit and not unreasonably late. The upper bound is 8 seconds, as in WireProtocolTests' idle-connection test, because on GitHub's shared Windows
        // machine, with other test classes hashing passwords in parallel, this test's own thread pool can add seconds before it sees the reply; a 3-second
        // bound failed there with 3.95 s and 4.99 s while the reply was the correct one.
        Assert.InRange(elapsed.TotalSeconds, 1.8, 8.0);
        // Control: the daemon still answers a normal client.
        Assert.True(daemon.SendPatiently(new SiteBlock.Core.Request(SiteBlock.Core.Command.Status)).Ok);
    }
}
