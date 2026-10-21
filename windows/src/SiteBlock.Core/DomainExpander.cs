namespace SiteBlock.Core;

/// <summary>Turns one base domain into every host name that must go into the hosts file, because the hosts file has no wildcards.</summary>
public static class DomainExpander
{
    /// <summary>Prefixes tried in front of every blocked domain.</summary>
    public static readonly IReadOnlyList<string> CommonPrefixes = ["www", "m", "mobile", "old", "new", "amp", "app", "web"];

    // Twitter and X are the same service under two names, so both domains share this one list.
    private static readonly string[] TwitterNames =
    [
        "x.com", "twitter.com", "mobile.twitter.com", "mobile.x.com", "api.x.com", "api.twitter.com",
        "pbs.twimg.com", "abs.twimg.com", "video.twimg.com",
    ];

    /// <summary>Extra names for well-known sites, keyed by base domain. Shared infrastructure such as t.co, fbcdn.net and googlevideo.com is left out on purpose, because each serves more than one product.</summary>
    public static readonly IReadOnlyDictionary<string, IReadOnlyList<string>> RelatedDomains = new Dictionary<string, IReadOnlyList<string>>(StringComparer.Ordinal)
    {
        ["reddit.com"] =
        [
            "np.reddit.com", "i.reddit.com", "oauth.reddit.com", "gateway.reddit.com", "gql.reddit.com", "sh.reddit.com",
            "redd.it", "i.redd.it", "v.redd.it", "preview.redd.it", "external-preview.redd.it",
            "redditstatic.com", "www.redditstatic.com", "redditmedia.com",
        ],
        // ytimg.com and youtube.googleapis.com serve only YouTube (thumbnails, page files, its API), so blocking them breaks nothing else.
        ["youtube.com"] =
        [
            "music.youtube.com", "tv.youtube.com", "studio.youtube.com", "youtu.be", "youtube-nocookie.com", "youtubekids.com",
            "youtubei.googleapis.com", "youtube.googleapis.com", "i.ytimg.com", "s.ytimg.com", "yt3.ggpht.com",
        ],
        ["x.com"] = TwitterNames,
        ["twitter.com"] = TwitterNames,
        ["facebook.com"] = ["web.facebook.com", "mbasic.facebook.com", "touch.facebook.com", "fb.com", "fb.me"],
        ["instagram.com"] = ["i.instagram.com", "help.instagram.com", "instagr.am"],
        ["tiktok.com"] = ["vm.tiktok.com", "vt.tiktok.com"],
        ["netflix.com"] = ["help.netflix.com"],
        ["twitch.tv"] = ["clips.twitch.tv", "player.twitch.tv", "gql.twitch.tv"],
        ["linkedin.com"] = ["lnkd.in"],
    };

    /// <summary>Returns the sorted, duplicate-free list of host names to block for a normalized base domain: the domain, the common prefixes, the related names, and www./m. forms of related two-label names.</summary>
    public static List<string> Expand(string domain)
    {
        ArgumentNullException.ThrowIfNull(domain);
        string baseName = SwiftText.Lowercased(domain);
        var hosts = new HashSet<string>(StringComparer.Ordinal) { baseName };
        foreach (string prefix in CommonPrefixes) hosts.Add($"{prefix}.{baseName}");
        if (RelatedDomains.TryGetValue(baseName, out var related))
        {
            foreach (string name in related)
            {
                hosts.Add(name);
                // A related name with exactly two labels (like redd.it) is a site of its own, so its www. and m. forms need blocking too.
                if (name.Split('.').Length == 2)
                {
                    hosts.Add($"www.{name}");
                    hosts.Add($"m.{name}");
                }
            }
        }
        var sorted = hosts.ToList();
        sorted.Sort(StringComparer.Ordinal);
        return sorted;
    }
}
