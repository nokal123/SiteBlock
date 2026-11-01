import Foundation

/// Builds the page the tab watcher sends a tab to when the tab is on a blocked site or a blocked part of a site. The page travels inside its own address as a `data:` address, so it needs no file on disk and no server, and both Chrome and Safari open it when it is set as a tab's address. A `data:` address never matches a rule, so a tab showing this page is left alone.
public enum BlockedPage {
    /// The page's title, which is also what the browser shows on the tab.
    public static let title = "Blocked by SiteBlock"

    /// The characters left as they are in the address. Everything else, including `%`, `#` (which would start a fragment and cut the page short) and every non-ASCII character, is percent-encoded. `CharacterSet.alphanumerics` is not used because it also holds non-ASCII letters.
    private static let unescaped = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// The `data:` address of the page that says `ruleText` (for example `x.com` or `youtube.com/shorts`) is blocked.
    public static func address(ruleText: String) -> String {
        // Every character outside the plain ASCII set above has a percent-encoded form, so the encoding cannot fail; the fallback only satisfies the type.
        let encoded = html(ruleText: ruleText).addingPercentEncoding(withAllowedCharacters: unescaped) ?? ""
        return "data:text/html;charset=utf-8," + encoded
    }

    /// The page's HTML. The rule text is escaped, so a rule holding `<`, `&` or a quote is shown as text and can never add markup or script. The colors follow the system's light or dark appearance.
    public static func html(ruleText: String) -> String {
        let site = escaped(ruleText)
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>\(title)</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#f5f5f7;color:#1d1d1f}main{max-width:32em;padding:24px;text-align:center}h1{font-size:24px;margin:0 0 12px;overflow-wrap:anywhere}p{margin:0;color:#6e6e73}@media (prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}p{color:#a1a1a6}}</style>
        </head><body><main><h1>\(site) is blocked</h1><p>SiteBlock blocked this page. To open it again, use the SiteBlock menu bar app.</p></main></body></html>
        """
    }

    /// Replaces the five characters that have a meaning in HTML with their entity forms. It works on Unicode scalars, because a Swift Character can glue a combining mark onto a `<` and hide it from a Character comparison.
    private static func escaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
