using SiteBlock.Core;

namespace SiteBlock.Core.Tests;

// The order of the temporary unblock checks, and that a refused request never costs a password try.
// Expected values come from 02-core-components.md § Engine (Temporary unblock commands, steps 1 to 8, and the password check rule) and 01-overview-and-data.md § Fixed Policy Values.
public sealed class EngineTemporaryUnblockOrderTests
{
    private const string Password = "correct-horse";
    private const string Wrong = "wrong-horse";
    private static readonly Peer User = new("S-1-5-21-1-2-3-1001", false);

    // An engine with the production numbers (cheap hashing), an unblock delay of one hour, a password, and reddit.com blocked.
    private static Engine NewEngine(long delaySeconds = 3600)
    {
        var engine = new Engine(PersistedState.Fresh(delaySeconds), Policy.Production with { Pbkdf2Iterations = 1000 });
        Assert.True(engine.Handle(new Request(Command.Setup, Password: Password), User).Ok);
        Assert.True(engine.Handle(new Request(Command.Add, Domain: "reddit.com"), User).Ok);
        return engine;
    }

    private static Response Temporary(Engine engine, string? domain = "reddit.com", string? password = Password, long? seconds = 1800, long? start = null) =>
        engine.Handle(new Request(Command.TemporaryUnblock, Domain: domain, Password: password, Seconds: seconds, StartSeconds: start), User);

    // Five wrong passwords on unblock, which starts the lockout.
    private static void LockOut(Engine engine)
    {
        for (int i = 0; i < 5; i++) engine.Handle(new Request(Command.Unblock, Domain: "reddit.com", Password: Wrong), User);
        Assert.NotNull(engine.State.Lockout);
    }

    [Fact]
    public void MissingDomainPasswordOrWindow_IsBadRequestAndCostsNoTry()
    {
        var engine = NewEngine();

        Assert.Equal(ErrorCode.BadRequest, Temporary(engine, domain: null, password: Wrong).ErrorCode);
        Assert.Equal(ErrorCode.BadRequest, Temporary(engine, password: null).ErrorCode);
        Assert.Equal(ErrorCode.BadRequest, Temporary(engine, password: Wrong, seconds: null).ErrorCode);
        Assert.Equal(0, engine.State.FailedAttempts);
    }

    [Fact]
    public void EveryCheckBeforeThePassword_WinsOverAWrongPasswordAndCostsNoTry()
    {
        var engine = NewEngine();

        Assert.Equal(ErrorCode.InvalidDomain, Temporary(engine, domain: "not a site", password: Wrong).ErrorCode);
        Assert.Equal(ErrorCode.NotBlocked, Temporary(engine, domain: "example.org", password: Wrong).ErrorCode);
        Assert.Equal(ErrorCode.InvalidDuration, Temporary(engine, password: Wrong, seconds: 299).ErrorCode);
        Assert.Equal(ErrorCode.InvalidDuration, Temporary(engine, password: Wrong, seconds: 14_401).ErrorCode);
        Assert.Equal(ErrorCode.InvalidDuration, Temporary(engine, password: Wrong, start: 3599).ErrorCode);
        Assert.Equal(ErrorCode.InvalidDuration, Temporary(engine, password: Wrong, start: 604_801).ErrorCode);
        Assert.Equal(0, engine.State.FailedAttempts);
        Assert.Null(engine.State.Lockout);
    }

    [Fact]
    public void DurationSentences_NameTheBrokenLimit()
    {
        var engine = NewEngine();

        Assert.Contains("It must stay open for at least 5 minutes.", Temporary(engine, seconds: 299).Error);
        Assert.Contains("It can't stay open for more than 4 hours.", Temporary(engine, seconds: 14_401).Error);
        Assert.Contains("It can't open sooner than your unblock delay of 1 hour.", Temporary(engine, start: 3599).Error);
    }

    [Fact]
    public void WindowAndStartWaitBoundaries_AreAccepted()
    {
        Assert.True(Temporary(NewEngine(), seconds: 300).Ok);
        Assert.True(Temporary(NewEngine(), seconds: 14_400).Ok);
        Assert.True(Temporary(NewEngine(), start: 3600).Ok);
        Assert.True(Temporary(NewEngine(), start: 604_800).Ok);
    }

    [Fact]
    public void WindowCheck_ComesBeforeTheStartWaitCheck()
    {
        // Both are out of range: the window is step 5 and the start wait step 6, so the window's sentence wins.
        var response = Temporary(NewEngine(), seconds: 10, start: 1);

        Assert.Contains("at least 5 minutes", response.Error);
        Assert.DoesNotContain("unblock delay", response.Error);
    }

    [Fact]
    public void NotBlocked_ComesBeforeTheDurationChecks()
    {
        Assert.Equal(ErrorCode.NotBlocked, Temporary(NewEngine(), domain: "example.org", seconds: 1).ErrorCode);
    }

    [Fact]
    public void PendingUnblock_IsAlreadyPendingBeforeTheDurationChecksAndThePassword()
    {
        var engine = NewEngine();
        Assert.True(engine.Handle(new Request(Command.Unblock, Domain: "reddit.com", Password: Password), User).Ok);

        var response = Temporary(engine, password: Wrong, seconds: 1);

        Assert.Equal(ErrorCode.AlreadyPending, response.ErrorCode);
        Assert.Equal("reddit.com is already waiting to unblock. Keep it blocked first if you want a temporary unblock instead.", response.Error);
        Assert.Equal(0, engine.State.FailedAttempts);
    }

    [Fact]
    public void SecondTemporaryUnblock_IsAlreadyPendingWithItsSentence()
    {
        var engine = NewEngine();
        Assert.True(Temporary(engine).Ok);

        var response = Temporary(engine, password: Wrong);

        Assert.Equal(ErrorCode.AlreadyPending, response.ErrorCode);
        Assert.Equal("reddit.com already has a temporary unblock.", response.Error);
        Assert.Equal(0, engine.State.FailedAttempts);
    }

    [Fact]
    public void DuringALockout_AnInvalidRequestGetsItsOwnErrorAndAValidOneIsLockedOut()
    {
        var engine = NewEngine();
        LockOut(engine);

        Assert.Equal(ErrorCode.InvalidDuration, Temporary(engine, seconds: 1).ErrorCode);
        Assert.Equal(ErrorCode.NotBlocked, Temporary(engine, domain: "example.org").ErrorCode);
        Assert.Equal(ErrorCode.LockedOut, Temporary(engine).ErrorCode);
        Assert.Null(engine.State.Blocked.Single().TemporaryUnblock);
    }

    [Fact]
    public void ValidRequestWithAWrongPassword_CountsOneTryAndFiveLockOut()
    {
        var engine = NewEngine();

        var first = Temporary(engine, password: Wrong);
        Assert.Equal(ErrorCode.WrongPassword, first.ErrorCode);
        Assert.Equal(1, engine.State.FailedAttempts);
        for (int i = 0; i < 4; i++) Temporary(engine, password: Wrong);

        Assert.NotNull(engine.State.Lockout);
        Assert.Equal(ErrorCode.LockedOut, Temporary(engine).ErrorCode);
    }

    [Fact]
    public void ValidRequestWithNoPasswordSet_IsNotSetUp()
    {
        var state = PersistedState.Fresh(3600);
        state.Blocked.Add(new BlockedSite("reddit.com", ["reddit.com", "www.reddit.com"]));
        var engine = new Engine(state, Policy.Production with { Pbkdf2Iterations = 1000 });

        Assert.Equal(ErrorCode.NotSetUp, Temporary(engine).ErrorCode);
    }

    [Fact]
    public void Success_UsesTheDelayWhenNoStartWaitIsGivenAndNamesTheNormalizedSite()
    {
        var engine = NewEngine();

        var response = Temporary(engine, domain: "https://www.Reddit.com/r/all");

        Assert.True(response.Ok, response.Error);
        Assert.Equal("reddit.com opens in 1 hour, for 30 minutes, then blocks again.", response.Message);
        var temporary = response.Status!.Blocked.Single().TemporaryUnblock!;
        Assert.Equal(3600L, temporary.OpensInSeconds);
        Assert.Equal(1800L, temporary.SecondsRemaining);
        Assert.Equal(1800L, temporary.WindowSeconds);
        Assert.False(temporary.IsOpen);
        var stored = engine.State.Blocked.Single().TemporaryUnblock!;
        Assert.Equal(3600, stored.StartsIn.RemainingSeconds);
        Assert.Equal(1800, stored.Window.TotalSeconds);
        Assert.Equal(0, engine.State.FailedAttempts);
    }

    [Fact]
    public void Tick_SplitsElapsedBetweenTheStartWaitAndTheWindow()
    {
        var engine = NewEngine();
        Assert.True(Temporary(engine, seconds: 1800, start: 3600).Ok);

        Assert.False(engine.Tick(3599.5));
        // Half a second opens it and the other 1.5 s come off the window.
        Assert.True(engine.Tick(2));
        var open = engine.State.Blocked.Single().TemporaryUnblock!;
        Assert.True(open.IsOpen);
        Assert.Equal(1798.5, open.Window.RemainingSeconds, 6);
        Assert.DoesNotContain("reddit.com", engine.BlockedHosts);
        Assert.False(engine.Tick(1000));
        Assert.True(engine.Tick(798.5));
        Assert.Null(engine.State.Blocked.Single().TemporaryUnblock);
        Assert.Contains("reddit.com", engine.BlockedHosts);
    }
}
