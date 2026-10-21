using SiteBlock.Core;

namespace SiteBlock.Core.Tests;

// The lockout bookkeeping of the password check and the fixed policy numbers.
// Expected values come from 02-core-components.md § Engine (Password check rule, Finished-but-uncleared lockout, Tick rule, the Policy field list) and
// 01-overview-and-data.md § Fixed Policy Values.
public sealed class EngineLockoutAndPolicyTests
{
    private const string Password = "correct-horse";
    private const string Wrong = "wrong-horse";
    private static readonly Peer User = new("S-1-5-21-1-2-3-1001", false);

    // The production numbers with cheap hashing, a password set and reddit.com blocked.
    private static Engine NewEngine()
    {
        var engine = new Engine(PersistedState.Fresh(1800), Policy.Production with { Pbkdf2Iterations = 1000 });
        Assert.True(engine.Handle(new Request(Command.Setup, Password: Password), User).Ok);
        Assert.True(engine.Handle(new Request(Command.Add, Domain: "reddit.com"), User).Ok);
        return engine;
    }

    // An engine that starts from a copy of another engine's state with the lockout replaced, as a restart from a saved file would.
    private static Engine WithLockout(Countdown? lockout, long failedAttempts = 0)
    {
        var state = NewEngine().State;
        state.Lockout = lockout;
        state.FailedAttempts = failedAttempts;
        return new Engine(state, Policy.Production with { Pbkdf2Iterations = 1000 });
    }

    private static Response Unblock(Engine engine, string password) => engine.Handle(new Request(Command.Unblock, Domain: "reddit.com", Password: password), User);

    [Fact]
    public void FifthWrongPassword_StartsTheLockoutAndResetsTheWrongTryCountToZero()
    {
        var engine = NewEngine();
        for (int i = 1; i <= 4; i++)
        {
            Assert.Equal(ErrorCode.WrongPassword, Unblock(engine, Wrong).ErrorCode);
            Assert.Equal(i, engine.State.FailedAttempts);
        }

        Assert.Equal(ErrorCode.WrongPassword, Unblock(engine, Wrong).ErrorCode);

        Assert.NotNull(engine.State.Lockout);
        Assert.Equal(900, engine.State.Lockout!.TotalSeconds);
        Assert.Equal(0, engine.State.FailedAttempts);
    }

    [Fact]
    public void AfterTheLockoutEnds_OneWrongPasswordDoesNotLockAgainAndFourTriesAreLeft()
    {
        var engine = NewEngine();
        for (int i = 0; i < 5; i++) Unblock(engine, Wrong);
        Assert.Equal(ErrorCode.LockedOut, Unblock(engine, Password).ErrorCode);

        engine.Tick(900);
        Assert.Null(engine.State.Lockout);

        var response = Unblock(engine, Wrong);
        Assert.Equal(ErrorCode.WrongPassword, response.ErrorCode);
        Assert.Contains("4 tries left", response.Error);
        Assert.Null(engine.State.Lockout);
        Assert.Equal(1, engine.State.FailedAttempts);
        // Control: the right password is now accepted and clears the count.
        Assert.True(Unblock(engine, Password).Ok);
        Assert.Equal(0, engine.State.FailedAttempts);
    }

    [Fact]
    public void LockoutWhoseCountdownFinishedButWasNotClearedByATick_DoesNotRefuseTheRightPassword()
    {
        var engine = WithLockout(new Countdown(0, 900));

        var response = Unblock(engine, Password);

        Assert.True(response.Ok, $"{response.ErrorCode}: {response.Error}");
        Assert.Null(engine.State.Lockout);
    }

    [Fact]
    public void LockoutWhoseCountdownFinishedButWasNotClearedByATick_GivesWrongPasswordNotLockedOutForAWrongOne()
    {
        var engine = WithLockout(new Countdown(0, 900));

        var response = Unblock(engine, Wrong);

        Assert.Equal(ErrorCode.WrongPassword, response.ErrorCode);
        Assert.Equal(1, engine.State.FailedAttempts);
    }

    [Fact]
    public void LockoutWithHalfASecondLeft_StillRefusesTheRightPasswordAndNeverSaysZero()
    {
        // Control for the two tests above: a lockout that is still running, however little is left, refuses without checking the password.
        var engine = WithLockout(new Countdown(0.5, 900));

        var response = Unblock(engine, Password);

        Assert.Equal(ErrorCode.LockedOut, response.ErrorCode);
        // This first asserted "1 minute" only, which was wrong: 02 § Engine (Lockout wording) also allows seconds when under one minute is left.
        // Either way the time is rounded up, so half a second reads as 1 of the unit and never as 0.
        Assert.True(response.Error!.Contains("1 minute", StringComparison.Ordinal) || response.Error.Contains("1 second", StringComparison.Ordinal), response.Error);
        Assert.DoesNotContain("0 minutes", response.Error);
        Assert.DoesNotContain("0 seconds", response.Error);
        Assert.Null(engine.State.PendingUnblockFor("reddit.com"));
    }

    [Fact]
    public void PolicyProduction_HoldsExactlyTheDesignValues()
    {
        var policy = Policy.Production;

        Assert.Equal(1800, policy.DefaultDelaySeconds);
        Assert.Equal(60, policy.MinDelaySeconds);
        Assert.Equal(604_800, policy.MaxDelaySeconds);
        Assert.Equal(172_800, policy.RecoverySeconds);
        Assert.Equal(900, policy.LockoutSeconds);
        Assert.Equal(5, policy.MaxFailedAttempts);
        Assert.Equal(210_000, policy.Pbkdf2Iterations);
        Assert.Equal(500, policy.MaxSites);
        Assert.Equal(172_800, policy.MinUninstallSeconds);
        Assert.Equal(300, policy.MinTemporarySeconds);
        Assert.Equal(14_400, policy.MaxTemporarySeconds);
        Assert.Equal(604_800, policy.MaxTemporaryStartSeconds);
        Assert.Equal(15, policy.SaveIntervalSeconds);
    }

    [Fact]
    public void PolicyFastForTests_HoldsTheValuesTheDesignFixesForIt()
    {
        var policy = Policy.FastForTests;

        Assert.Equal(2, policy.MinUninstallSeconds);
        Assert.Equal(1, policy.MinTemporarySeconds);
        Assert.Equal(14_400, policy.MaxTemporarySeconds);
        Assert.Equal(604_800, policy.MaxTemporaryStartSeconds);
        Assert.Equal(2, policy.SaveIntervalSeconds);
        Assert.Equal(20, policy.MaxSites);
    }
}

// Reads one site's pending unblock out of a state, for the lockout tests.
internal static class LockoutStateReading
{
    public static Countdown? PendingUnblockFor(this PersistedState state, string domain) => state.Blocked.Single(site => site.Domain == domain).PendingUnblock;
}
