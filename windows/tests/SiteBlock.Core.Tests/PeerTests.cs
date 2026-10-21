using SiteBlock.Core;

namespace SiteBlock.Core.Tests;

// The admin rules that replace the Mac's "uid 0" checks. Expected values come from 06-windows.md § SiteBlock.Core (Who is calling, Messages),
// 01-overview-and-data.md § Commands (setup, recoveryStart) and 02-core-components.md § Engine (Who may set up, recoveryStart order) and § ConnectionLimiter.
public sealed class PeerTests
{
    private const string Owner = "S-1-5-21-1111111111-2222222222-3333333333-1001";
    private const string OtherUser = "S-1-5-21-1111111111-2222222222-3333333333-1002";
    private const string Password = "correct-horse";
    private const string WindowsRecoverySentence = "Password recovery can only be started by an administrator. Open Terminal or PowerShell with \"Run as administrator\" and run siteblock recover.";

    private static readonly Peer OwnerPeer = new(Owner, false);
    private static readonly Peer OtherPeer = new(OtherUser, false);
    private static readonly Peer Admin = new("S-1-5-18", true);

    // An engine with the production numbers and a cheap hash cost, optionally with a console user rule and a password already set.
    private static Engine NewEngine(string? consoleUser = null, bool withPassword = false)
    {
        var engine = new Engine(PersistedState.Fresh(1800), Policy.Production with { Pbkdf2Iterations = 1000 });
        if (withPassword) Assert.True(engine.Handle(new Request(Command.Setup, Password: Password), Admin).Ok);
        if (consoleUser is not null) engine.ConsoleUser = () => consoleUser;
        return engine;
    }

    private static Response Setup(Engine engine, Peer peer) => engine.Handle(new Request(Command.Setup, Password: Password), peer);

    [Fact]
    public void RecoveryStart_FromANonAdmin_IsNotRootWithTheWindowsSentenceAndStartsNothing()
    {
        var engine = NewEngine(withPassword: true);

        var response = engine.Handle(new Request(Command.RecoveryStart), OwnerPeer);

        Assert.Equal(ErrorCode.NotRoot, response.ErrorCode);
        Assert.Equal(WindowsRecoverySentence, response.Error);
        Assert.Null(engine.State.Recovery);
    }

    [Fact]
    public void RecoveryStart_FromANonAdminWithNoPassword_IsStillNotRootBecauseThatCheckComesFirst()
    {
        var response = NewEngine().Handle(new Request(Command.RecoveryStart), Peer.Unknown);

        Assert.Equal(ErrorCode.NotRoot, response.ErrorCode);
        Assert.Equal(WindowsRecoverySentence, response.Error);
    }

    [Fact]
    public void RecoveryStart_FromAnAdmin_StartsThe48HourRecovery()
    {
        var engine = NewEngine(withPassword: true);

        var response = engine.Handle(new Request(Command.RecoveryStart), Admin);

        Assert.True(response.Ok, response.Error);
        Assert.Equal(172_800, engine.State.Recovery!.RemainingSeconds);
        Assert.Equal(172_800L, response.Status!.RecoverySecondsRemaining);
    }

    [Fact]
    public void RecoveryStart_FromAnAdminWithNoPassword_IsNotSetUp()
    {
        Assert.Equal(ErrorCode.NotSetUp, NewEngine().Handle(new Request(Command.RecoveryStart), Admin).ErrorCode);
    }

    [Fact]
    public void PeerUnknown_IsANonAdminCaller()
    {
        Assert.False(Peer.Unknown.IsAdmin);
        Assert.Equal("unknown", Peer.Unknown.UserId);
    }

    [Fact]
    public void NoReplySentence_EverMentionsSudo()
    {
        var engine = NewEngine(withPassword: true);
        engine.Handle(new Request(Command.Add, Domain: "reddit.com"), OwnerPeer);
        var requests = new[]
        {
            new Request(Command.RecoveryStart), new Request(Command.RecoveryCancel), new Request(Command.Unblock, Domain: "reddit.com", Password: "wrong-one"),
            new Request(Command.Uninstall, Password: Password), new Request(Command.CancelUninstall), new Request(Command.CancelUninstall), new Request(Command.SetDelay, Seconds: 5, Password: Password),
            new Request(Command.Setup, Password: Password), new Request(Command.ChangePassword, Password: Password, NewPassword: "x"), new Request(Command.CancelDelayChange),
        };

        foreach (var request in requests)
        {
            var response = engine.Handle(request, OwnerPeer);
            Assert.DoesNotContain("sudo", (response.Error ?? "") + (response.Message ?? ""), StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    public void Setup_WithNoConsoleUserRule_IsAllowedForAnyCaller()
    {
        Assert.True(Setup(NewEngine(), Peer.Unknown).Ok);
        Assert.True(Setup(NewEngine(), OtherPeer).Ok);
    }

    [Fact]
    public void Setup_FromTheConsoleUser_IsAllowed()
    {
        var engine = NewEngine(consoleUser: Owner);

        Assert.True(Setup(engine, OwnerPeer).Ok);
        Assert.NotNull(engine.State.PasswordHash);
    }

    [Fact]
    public void Setup_FromTheConsoleUsersSidInOtherLetterCase_IsAllowed()
    {
        Assert.True(Setup(NewEngine(consoleUser: Owner), new Peer(Owner.ToLowerInvariant(), false)).Ok);
        Assert.True(Setup(NewEngine(consoleUser: Owner.ToLowerInvariant()), OwnerPeer).Ok);
    }

    [Fact]
    public void Setup_FromAnotherNonAdminUser_IsNotAllowedAndSetsNothing()
    {
        var engine = NewEngine(consoleUser: Owner);

        var response = Setup(engine, OtherPeer);

        Assert.Equal(ErrorCode.NotAllowed, response.ErrorCode);
        Assert.Null(engine.State.PasswordHash);
        Assert.Equal(ErrorCode.NotAllowed, Setup(engine, Peer.Unknown).ErrorCode);
    }

    [Fact]
    public void Setup_FromAnAdminWhoIsNotTheConsoleUser_IsAllowed()
    {
        Assert.True(Setup(NewEngine(consoleUser: Owner), Admin).Ok);
        Assert.True(Setup(NewEngine(consoleUser: Owner), new Peer(OtherUser, true)).Ok);
    }

    [Fact]
    public void Setup_FromADisallowedCallerAfterAPasswordExists_IsNotAllowedBeforeAlreadySetUp()
    {
        var engine = NewEngine(consoleUser: Owner, withPassword: true);

        Assert.Equal(ErrorCode.NotAllowed, Setup(engine, OtherPeer).ErrorCode);
        Assert.Equal(ErrorCode.AlreadySetUp, Setup(engine, OwnerPeer).ErrorCode);
    }

    [Fact]
    public void Setup_SimilarButDifferentSid_IsNotAllowed()
    {
        var engine = NewEngine(consoleUser: Owner);

        Assert.Equal(ErrorCode.NotAllowed, Setup(engine, new Peer(Owner + "0", false)).ErrorCode);
        Assert.Equal(ErrorCode.NotAllowed, Setup(engine, new Peer(Owner[..^1], false)).ErrorCode);
        Assert.Equal(ErrorCode.NotAllowed, Setup(engine, new Peer(" " + Owner, false)).ErrorCode);
    }

    [Fact]
    public void ConnectionLimiter_FifthConnectionFromOneUser_IsRefusedWhileOthersAreAdmitted()
    {
        var limiter = new ConnectionLimiter();

        for (int i = 0; i < 4; i++) Assert.True(limiter.Admit(OwnerPeer));

        Assert.False(limiter.Admit(OwnerPeer));
        Assert.True(limiter.Admit(OtherPeer));
    }

    [Fact]
    public void ConnectionLimiter_ReleaseFreesOneSlotOfThatUserOnly()
    {
        var limiter = new ConnectionLimiter();
        for (int i = 0; i < 4; i++) limiter.Admit(OwnerPeer);

        // A release for a user with nothing open must not free the owner's slots.
        limiter.Release(OtherPeer);
        Assert.False(limiter.Admit(OwnerPeer));
        limiter.Release(OwnerPeer);

        Assert.True(limiter.Admit(OwnerPeer));
        Assert.False(limiter.Admit(OwnerPeer));
    }

    [Fact]
    public void ConnectionLimiter_NonAdminsShareTwentyEightSlotsAndTheLastFourAreForAdmins()
    {
        var limiter = new ConnectionLimiter();
        for (int user = 0; user < 7; user++)
        {
            for (int i = 0; i < 4; i++) Assert.True(limiter.Admit(new Peer($"S-1-5-21-9-{user}", false)));
        }

        Assert.False(limiter.Admit(new Peer("S-1-5-21-9-99", false)));
        for (int i = 0; i < 4; i++) Assert.True(limiter.Admit(Admin));
        Assert.False(limiter.Admit(Admin));
    }

    [Fact]
    public void ConnectionLimiter_AdminConnectionsCountTowardTheNonAdminThreshold()
    {
        var limiter = new ConnectionLimiter();
        for (int i = 0; i < 8; i++) Assert.True(limiter.Admit(Admin));
        for (int user = 0; user < 5; user++)
        {
            for (int i = 0; i < 4; i++) Assert.True(limiter.Admit(new Peer($"S-1-5-21-8-{user}", false)));
        }

        // 8 admin + 20 non-admin = 28 open: no further non-admin connection, but admins may take the rest.
        Assert.False(limiter.Admit(new Peer("S-1-5-21-8-99", false)));
        for (int i = 0; i < 4; i++) Assert.True(limiter.Admit(Admin));
        Assert.False(limiter.Admit(Admin));
    }

    [Fact]
    public void ConnectionLimiter_AdminHasNoPerUserLimit()
    {
        var limiter = new ConnectionLimiter();

        for (int i = 0; i < 32; i++) Assert.True(limiter.Admit(Admin), $"admin connection {i + 1} refused");
        Assert.False(limiter.Admit(Admin));
    }

    [Fact]
    public void ConnectionLimiter_UnknownCallersShareOneOrdinaryUsersFourSlots()
    {
        var limiter = new ConnectionLimiter();

        for (int i = 0; i < 4; i++) Assert.True(limiter.Admit(Peer.Unknown));

        Assert.False(limiter.Admit(Peer.Unknown));
        Assert.True(limiter.Admit(Admin));
    }

    [Fact]
    public void ConnectionLimiter_AdminReleaseFreesAnAdminSlot()
    {
        var limiter = new ConnectionLimiter();
        for (int i = 0; i < 32; i++) limiter.Admit(Admin);
        Assert.False(limiter.Admit(Admin));

        limiter.Release(Admin);

        Assert.True(limiter.Admit(Admin));
    }

    [Fact]
    public async Task ConnectionLimiter_ManyThreadsAdmittingAndReleasing_NeverLeakOrOvercount()
    {
        var limiter = new ConnectionLimiter();
        var workers = Enumerable.Range(0, 16).Select(worker => Task.Run(() =>
        {
            var peer = new Peer($"S-1-5-21-7-{worker % 4}", false);
            for (int i = 0; i < 2000; i++)
            {
                if (limiter.Admit(peer)) limiter.Release(peer);
            }
        }));
        await Task.WhenAll(workers);

        // Everything was given back, so every user again has exactly four slots.
        for (int user = 0; user < 4; user++)
        {
            var peer = new Peer($"S-1-5-21-7-{user}", false);
            for (int i = 0; i < 4; i++) Assert.True(limiter.Admit(peer));
            Assert.False(limiter.Admit(peer));
        }
    }
}
