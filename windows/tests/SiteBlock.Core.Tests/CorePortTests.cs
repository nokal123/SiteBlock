using System.Text;
using SiteBlock.Core;

namespace SiteBlock.Core.Tests;

// The highest-value rules of the Swift core, checked in the C# port with the Mac suite's expected values (06-windows.md § Testing item 1).
// Expected values come from 02-core-components.md § PasswordHasher, § DomainNormalizer, § HostsFileEditor and § TabRuleMatcher, 01-overview-and-data.md § Fixed Policy Values
// (minimum password length), and the known-answer vectors in Tests/SiteBlockCoreTests/PasswordHasherTests.swift, which were computed outside SiteBlock.
public sealed class PasswordHasherPortTests
{
    // (password, salt in Base64, iterations, derived key in Base64): the vectors the Swift suite checks its own hasher against. The first is the published
    // PBKDF2-HMAC-SHA256 answer for "password"/"salt"/1; the rest were computed with CommonCrypto outside SiteBlock.
    public static TheoryData<string, string, int, string> KnownAnswers => new()
    {
        { "password", "c2FsdA==", 1, "Eg+2z/z4syxD5yJSVsT4N6hlSMkszDVICAWYfLcL4Xs=" },
        { "password", "c2FsdA==", 4096, "xeR41ZKIyEGqUw22hFxMjZYok6ABzk4RpJY4c6qYE0o=" },
        { "pässwörd✓", "AAECAwQFBgcICQoLDA0ODw==", 1000, "loUSDTN87zbVJjmpX40Mrxyb0C5l9E+OnEyZHUCeup8=" },
        { "  padded  ", "EBESExQVFhcYGRobHB0eHw==", 1000, "FGbeZX0YD+IVbwySH26CjDLTzcj4sbtH2ZOKogvaGrk=" },
        { "abc\u0000defg", "MDEyMzQ1Njc4OWFiY2RlZg==", 1000, "axzncnEcLV6F66QGZMbXOX+tGzxNcHqXbVReF1B55O8=" },
    };

    [Theory]
    [MemberData(nameof(KnownAnswers))]
    public void Verify_HashMadeOutsideCSharp_AcceptsItsPasswordAndRejectsAnother(string password, string salt, int iterations, string hash)
    {
        var stored = new PasswordHash("pbkdf2-sha256", iterations, salt, hash);

        Assert.True(PasswordHasher.Verify(password, stored));
        Assert.False(PasswordHasher.Verify(password + "x", stored));
        Assert.False(PasswordHasher.Verify(password, stored with { Iterations = iterations + 1 }));
    }

    [Fact]
    public void Verify_ProductionStrengthHashInTheSwiftStateFileShape_DecodesAndVerifies()
    {
        // A passwordHash object as the Swift daemon writes it into state.json (sorted keys). The derived key was computed with Python's hashlib.pbkdf2_hmac
        // ('sha256', b'Qz7-lantern-Pw', bytes(range(16)), 210000), independent of both SiteBlock versions.
        const string state = """{ "blocked" : [ ], "delaySeconds" : 1800, "failedAttempts" : 0, "passwordHash" : { "algorithm" : "pbkdf2-sha256", "hash" : "px6BuO9K3lK3wCnxRQB4kbZCu8yGY1QBi8kkOPNWbRM=", "iterations" : 210000, "salt" : "AAECAwQFBgcICQoLDA0ODw==" }, "uninstalling" : false, "version" : 1 }""";

        var stored = JsonCoding.Decode<PersistedState>(state).PasswordHash!;

        Assert.True(PasswordHasher.Verify("Qz7-lantern-Pw", stored));
        Assert.False(PasswordHasher.Verify("Qz7-lantern-pw", stored));
        Assert.False(PasswordHasher.Verify("Qz7-lantern-Pw ", stored));
    }

    [Fact]
    public void Make_DefaultsToTheProductionFormatAndVerifiesOnlyItsOwnPassword()
    {
        var hash = PasswordHasher.Make("hunter22");

        Assert.Equal("pbkdf2-sha256", hash.Algorithm);
        Assert.Equal(210_000, hash.Iterations);
        Assert.Equal(16, Convert.FromBase64String(hash.Salt).Length);
        Assert.Equal(32, Convert.FromBase64String(hash.Hash).Length);
        Assert.True(PasswordHasher.Verify("hunter22", hash));
        Assert.False(PasswordHasher.Verify("Hunter22", hash));
        Assert.NotEqual(hash.Salt, PasswordHasher.Make("hunter22", 1).Salt);
    }

    [Theory]
    [InlineData("12345", PasswordError.TooShort)]
    [InlineData("   ", PasswordError.TooShort)]
    [InlineData("abcd\U0001F600", PasswordError.TooShort)]
    [InlineData("abcdé", PasswordError.TooShort)]
    [InlineData("      ", PasswordError.WhitespaceOnly)]
    [InlineData("\t \n   ", PasswordError.WhitespaceOnly)]
    public void ValidateNew_TooShortOrOnlyWhitespace_IsRefusedWithTheRightReason(string password, PasswordError expected)
    {
        // Length counts characters as a person sees them: an emoji or a letter with its accent mark is one character.
        var error = Assert.Throws<PasswordException>(() => PasswordHasher.ValidateNew(password));
        Assert.Equal(expected, error.Error);
    }

    [Theory]
    [InlineData("123456")]
    [InlineData(" pass ")]
    [InlineData("\U0001F600\U0001F600\U0001F600\U0001F600\U0001F600\U0001F600")]
    public void ValidateNew_SixCharacters_IsAccepted(string password)
    {
        PasswordHasher.ValidateNew(password);
    }
}

public sealed class DomainNormalizerPortTests
{
    [Theory]
    [InlineData("https://www.Reddit.com/r/all", "reddit.com")]
    [InlineData("reddit.com:8080", "reddit.com")]
    [InlineData("http://user:pass@reddit.com:443/x?y#z", "reddit.com")]
    [InlineData("  WWW.YouTube.COM.  ", "youtube.com")]
    [InlineData("www.www.example.com", "www.example.com")]
    [InlineData("bücher.de", "xn--bcher-kva.de")]
    [InlineData("reddit.com/?next=https://other.com", "reddit.com")]
    [InlineData("https://www.youtube.com/@MrBeast", "youtube.com")]
    [InlineData("reddit.com?e=a@b.com", "reddit.com")]
    public void Normalize_TypedText_GivesTheBaseDomain(string input, string expected)
    {
        Assert.Equal(expected, DomainNormalizer.Normalize(input));
    }

    public static TheoryData<string, DomainError> Rejections => new()
    {
        { "", DomainError.Empty },
        { "   \n", DomainError.Empty },
        { "https://", DomainError.Empty },
        { "1.2.3.4", DomainError.IpAddress },
        { "[::1]:80", DomainError.IpAddress },
        { "localhost", DomainError.Reserved },
        { "printer.local", DomainError.Reserved },
        { "reddit", DomainError.NeedsDot },
        { "a..com", DomainError.InvalidCharacters },
        { "red dit.com", DomainError.InvalidCharacters },
        { "red​dit.com", DomainError.InvalidCharacters },
        { "reddit.com:abc", DomainError.InvalidCharacters },
        { new string('a', 64) + ".com", DomainError.LabelTooLong },
        { string.Join('.', Enumerable.Repeat(new string('a', 63), 4)) + ".com", DomainError.TooLong },
    };

    [Theory]
    [MemberData(nameof(Rejections))]
    public void Normalize_TextThatIsNotABlockableSite_ThrowsTheDesignError(string input, DomainError expected)
    {
        var error = Assert.Throws<DomainException>(() => DomainNormalizer.Normalize(input));
        Assert.Equal(expected, error.Error);
    }
}

public sealed class HostsFileEditorPortTests
{
    private const string Begin = "# BEGIN SiteBlock — managed by siteblockd; edits inside this block are reverted";
    private const string End = "# END SiteBlock";
    private const string UserFile = "# Copyright (c) 1993-2009 Microsoft Corp.\n#\n127.0.0.1 localhost\n::1 localhost\n10.1.2.3 intranet.example.org\n";

    // The managed section for these names, written out from the design: BEGIN, then for each name in sorted order its 0.0.0.0 and :: lines, then END.
    private static string Section(params string[] sortedHosts) => Begin + "\n" + string.Concat(sortedHosts.Select(host => $"0.0.0.0 {host}\n:: {host}\n")) + End + "\n";

    [Fact]
    public void Render_KeepsEveryUserLineAndAppendsOneBlankLineAndTheSortedSection()
    {
        string result = HostsFileEditor.Render(UserFile, ["www.reddit.com", "reddit.com"]);

        Assert.Equal(UserFile + "\n" + Section("reddit.com", "www.reddit.com"), result);
        Assert.Equal(result, HostsFileEditor.Render(result, ["www.reddit.com", "reddit.com"]));
    }

    [Fact]
    public void Render_UserLinePointingABlockedNameElsewhere_LosesThatNameAndKeepsTheRest()
    {
        string original = UserFile + "151.101.1.140 reddit.com\n1.2.3.4 REDDIT.com. other.com # keep\n";

        string result = HostsFileEditor.Render(original, ["reddit.com"]);

        Assert.Equal(UserFile + "1.2.3.4 other.com # keep\n" + "\n" + Section("reddit.com"), result);
    }

    [Fact]
    public void Render_EmptyBlockList_RemovesTheSectionAndLeavesTheUserLinesExactly()
    {
        string withSection = UserFile + "\n" + Section("reddit.com");

        Assert.Equal(UserFile, HostsFileEditor.Render(withSection, []));
    }

    [Fact]
    public void Render_HostileEntry_ProducesNoLineAndNeverRemovesLocalhost()
    {
        string result = HostsFileEditor.Render(UserFile, ["evil.com\n0.0.0.0 bank.com", "localhost", "reddit.com"]);

        Assert.Equal(UserFile + "\n" + Section("reddit.com"), result);
    }
}

public sealed class TabRuleMatcherPortTests
{
    private static readonly WatchedPathRule Shorts = new("youtube.com", "/shorts");

    [Theory]
    [InlineData("https://youtube.com/shorts")]
    [InlineData("https://www.youtube.com/shorts/x")]
    [InlineData("https://youtube.com/shorts?x=1")]
    [InlineData("https://youtube.com/shorts#top")]
    [InlineData("HTTP://M.YouTube.com./shorts/abc")]
    [InlineData("https://youtube.com:8443/shorts")]
    // The browsers treat the rule's path as a plain prefix, so "/shortsx" is under "/shorts" too (02-core-components.md § TabRuleMatcher step 5).
    [InlineData("https://youtube.com/shortsx")]
    public void Matches_AddressUnderTheRule_IsTrue(string url)
    {
        Assert.True(TabRuleMatcher.Matches(url, Shorts), url);
    }

    [Theory]
    [InlineData("https://youtube.com/Shorts")]
    [InlineData("https://youtube.com/short")]
    [InlineData("https://youtube.com/?next=/shorts")]
    [InlineData("https://youtube.com/watch/shorts")]
    [InlineData("https://notyoutube.com/shorts")]
    [InlineData("https://youtube.com%2Fx.evil.com/shorts")]
    [InlineData("https://youtube.com@other.com/shorts")]
    [InlineData("chrome://youtube.com/shorts")]
    [InlineData("youtube.com/shorts")]
    [InlineData("")]
    public void Matches_AddressNotUnderTheRule_IsFalse(string url)
    {
        Assert.False(TabRuleMatcher.Matches(url, Shorts), url);
    }

    [Fact]
    public void MatchingRule_ReturnsTheFirstMatchingRuleInListOrder()
    {
        var general = new WatchedPathRule("youtube.com", "/s");
        var other = new WatchedPathRule("reddit.com", "/r/all");

        Assert.Equal(general, TabRuleMatcher.MatchingRule("https://youtube.com/shorts/1", [other, general, Shorts]));
        Assert.Equal(Shorts, TabRuleMatcher.MatchingRule("https://youtube.com/shorts/1", [other, Shorts, general]));
        Assert.Null(TabRuleMatcher.MatchingRule("https://youtube.com/watch", [other, Shorts]));
    }
}
