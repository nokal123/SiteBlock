using System.Text;

namespace SiteBlock.Core;

/// <summary>
/// Builds the page the tab watcher sends a tab to when the tab is on a blocked site or a blocked part of a site. The page travels inside its own address as a <c>data:</c> address, so it needs no file on disk and no server,
/// and Chrome, Edge and Brave open it when it is typed into the address bar. A <c>data:</c> address never matches a rule, so a tab showing this page is left alone. It follows the Mac's BlockedPage, with the last sentence naming the tray icon.
/// </summary>
public static class BlockedPage
{
    /// <summary>The page's title, which is also what the browser shows on the tab.</summary>
    public const string Title = "Blocked by SiteBlock";

    /// <summary>
    /// The <c>data:</c> address of the page that says <paramref name="ruleText"/> (for example <c>x.com</c> or <c>youtube.com/shorts</c>) is blocked. <c>Uri.EscapeDataString</c> percent-encodes the UTF-8 bytes of
    /// everything except ASCII letters, digits and <c>-._~</c>, including <c>%</c>, <c>#</c> (which would start a fragment and cut the page short) and every non-ASCII character.
    /// </summary>
    public static string Address(string ruleText) => "data:text/html;charset=utf-8," + Uri.EscapeDataString(Html(ruleText));

    /// <summary>The page's HTML. The rule text is escaped, so a rule holding <c>&lt;</c>, <c>&amp;</c> or a quote is shown as text and can never add markup or script. The colors follow the system's light or dark appearance.</summary>
    public static string Html(string ruleText)
    {
        string site = Escaped(ruleText);
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light dark\"><title>" + Title + "</title>\n"
            + "<style>body{font:16px 'Segoe UI Variable','Segoe UI',system-ui,sans-serif;margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#f5f5f7;color:#1d1d1f}main{max-width:32em;padding:24px;text-align:center}h1{font-size:24px;margin:0 0 12px;overflow-wrap:anywhere}p{margin:0;color:#6e6e73}@media (prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}p{color:#a1a1a6}}</style>\n"
            + "</head><body><main><h1>" + site + " is blocked</h1><p>SiteBlock blocked this page. To open it again, use the SiteBlock icon in the system tray.</p></main></body></html>";
    }

    /// <summary>Replaces the five characters that have a meaning in HTML with their entity forms, one character at a time.</summary>
    private static string Escaped(string text)
    {
        var result = new StringBuilder();
        foreach (char c in text)
        {
            result.Append(c switch
            {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\'' => "&#39;",
                _ => c.ToString(),
            });
        }
        return result.ToString();
    }
}
