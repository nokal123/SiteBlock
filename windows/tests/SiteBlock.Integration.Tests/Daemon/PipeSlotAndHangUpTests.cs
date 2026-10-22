using System.Diagnostics;
using SiteBlock.Integration.Tests.Support;

namespace SiteBlock.Integration.Tests.Daemon;

// When a connection's slot is given back, and what happens while the server waits for a client to hang up after its reply. Every sandbox caller is the same user
// (06-windows.md § PipeServer, identity in sandbox mode), so the per-user limit of 4 connections applies to every connection a test opens.
// Expected values come from 06-windows.md § PipeServer step 4: the slot is given back just before the reply is written, so a client that has read its reply and opens
// its next connection at once never finds the finished one still counted; the wait of up to 2 seconds for the client to hang up holds no slot; each account may have at
// most 4 such waits at once, and a further connection of that account is closed right after its reply; and the 2-second request limit counts from the moment the
// connection was accepted. 02-core-components.md § ConnectionLimiter gives the limit of 4 per user.
public sealed class PipeSlotAndHangUpTests
{
    private const string StatusLine = "{\"command\":\"status\"}\n";

    // Sends a status line on an open connection and returns true when an ok reply comes back.
    private static bool AnswersStatus(RawConnection connection)
    {
        connection.Write(StatusLine);
        return connection.ReadLine(5)?.Contains("\"ok\":true", StringComparison.Ordinal) == true;
    }

    [Fact]
    public void ClientKeepsItsAnsweredConnectionOpen_FourNewConnectionsOpenedAtOnceAreAllAdmitted()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        for (int round = 0; round < 5; round++)
        {
            using var first = RawConnection.Open(daemon.PipePath);
            Assert.True(AnswersStatus(first), $"round {round}: the first connection was not answered");
            // The first connection is still open (its client has not hung up), so a slot that was given back only on the hang-up would still be counted here.
            var four = Enumerable.Range(0, 4).Select(_ => RawConnection.Open(daemon.PipePath)).ToList();
            try
            {
                // All four are open together before any is used, so all four must hold a slot at once.
                foreach (var connection in four) connection.Write(StatusLine);
                for (int i = 0; i < four.Count; i++)
                {
                    string? reply = four[i].ReadLine(5);
                    Assert.True(reply?.Contains("\"ok\":true", StringComparison.Ordinal) == true, $"round {round}: connection {i + 1} of the four was not admitted (reply: {(reply is null ? "none within 5 s" : $"\"{reply}\"")})");
                }
            }
            finally
            {
                foreach (var connection in four) connection.Dispose();
            }
            // Let this round's hang-up waits end before the next round, so each round starts from the same place.
            Thread.Sleep(300);
        }
    }

    [Fact]
    public void ClientHangsUpRightAfterReadingItsReply_FourConnectionsOpenedImmediatelyAreAllAdmitted()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        for (int round = 0; round < 10; round++)
        {
            using (var first = RawConnection.Open(daemon.PipePath)) Assert.True(AnswersStatus(first), $"round {round}: the first connection was not answered");
            var four = Enumerable.Range(0, 4).Select(_ => RawConnection.Open(daemon.PipePath)).ToList();
            try
            {
                foreach (var connection in four) connection.Write(StatusLine);
                for (int i = 0; i < four.Count; i++) Assert.True(four[i].ReadLine(5)?.Contains("\"ok\":true", StringComparison.Ordinal) == true, $"round {round}: connection {i + 1} of the four was not admitted");
            }
            finally
            {
                foreach (var connection in four) connection.Dispose();
            }
        }
    }

    [Fact]
    public void FiveClientsReadTheirRepliesAndNeverHangUp_AllFiveGetRepliesAndOnlyTheFifthIsClosedAtOnce()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        // The five replies must all arrive while the first waits are still running (they last up to 2 seconds from each reply); an attempt slower than that proves nothing
        // about the cap, so it is tried again after the waits have ended.
        const double windowSeconds = 1.2;
        for (int attempt = 0; ; attempt++)
        {
            var lingering = new List<RawConnection>();
            try
            {
                var clock = Stopwatch.StartNew();
                // Four clients read their reply and then just stay connected; each holds one of the account's four hang-up waits but no slot.
                for (int i = 0; i < 4; i++)
                {
                    var connection = RawConnection.Open(daemon.PipePath);
                    lingering.Add(connection);
                    Assert.True(AnswersStatus(connection), $"lingering client {i + 1} was not answered");
                }
                using var fifth = RawConnection.Open(daemon.PipePath);
                // The fifth still gets its reply: the cap only skips the wait, and the slot it used was free.
                Assert.True(AnswersStatus(fifth), "the fifth client did not get its reply");
                double repliedAt = clock.Elapsed.TotalSeconds;
                // ...and then the server closes it right away instead of waiting for it to hang up.
                var closeClock = Stopwatch.StartNew();
                string? afterReply = fifth.ReadLine(1.5);
                double closedAfter = closeClock.Elapsed.TotalSeconds;
                // Control: the first client's wait is still running, so its connection is still open at this moment.
                string? firstStillOpen = lingering[0].ReadLine(0.05);
                if (repliedAt + closedAfter > windowSeconds && attempt < 3)
                {
                    foreach (var connection in lingering) connection.Dispose();
                    lingering.Clear();
                    Thread.Sleep(2500);
                    continue;
                }
                Assert.True(repliedAt + closedAfter <= windowSeconds, $"no attempt finished inside the first waits (last: replies done at {repliedAt:0.00} s, fifth closed {closedAfter:0.00} s later)");
                Assert.True(afterReply == "", $"the fifth connection should be closed right after its reply, but {(afterReply is null ? "it was still open 1.5 s later" : $"more text arrived: \"{afterReply}\"")}");
                Assert.True(firstStillOpen is null, $"the first client's connection should still be in its hang-up wait, but the read returned \"{firstStillOpen}\"");

                // The four waits end on their own within the 2-second limit (well within 8 s on a loaded machine), each closing its connection.
                foreach (var connection in lingering) Assert.Equal("", connection.ReadLine(8));
                break;
            }
            finally
            {
                foreach (var connection in lingering) connection.Dispose();
            }
        }

        // Once the waits have ended the count is back to zero: a new client that lingers gets a wait again (it is not closed at once).
        using var later = RawConnection.Open(daemon.PipePath);
        Assert.True(AnswersStatus(later), "a later client was not answered");
        Assert.Null(later.ReadLine(0.5));
    }

    [Fact]
    public void CompleteRequestSentOnePointSixSecondsAfterConnecting_IsStillAnswered()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        using var connection = RawConnection.Open(daemon.PipePath);

        // The 2-second limit counts from when the connection was accepted, so a whole line that arrives before then is read and answered.
        Thread.Sleep(1600);
        connection.Write(StatusLine);

        string? reply = connection.ReadLine(5);
        Assert.True(reply?.Contains("\"ok\":true", StringComparison.Ordinal) == true, $"a request inside the 2-second limit should be answered, but got {(reply is null ? "nothing" : $"\"{reply}\"")}");
    }

    [Fact]
    public void CompleteRequestSentAfterTheTwoSecondLimit_GetsTheTimeoutRefusalInstead()
    {
        using var daemon = SandboxDaemon.Start(tickSeconds: 60);
        using var connection = RawConnection.Open(daemon.PipePath);

        Thread.Sleep(2600);
        connection.Write(StatusLine);

        string? reply = connection.ReadLine(5);
        Assert.False(string.IsNullOrEmpty(reply), "the late request got no reply at all");
        var json = (System.Text.Json.Nodes.JsonObject)System.Text.Json.Nodes.JsonNode.Parse(reply!)!;
        Assert.False((bool)json["ok"]!);
        Assert.Equal("badRequest", (string?)json["errorCode"]);
        Assert.Equal("No request arrived within 2 seconds.", (string?)json["error"]);
    }
}
