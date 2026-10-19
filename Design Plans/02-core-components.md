# Core Components (SiteBlockCore library)
> Part of the SiteBlock Design Plans
> See also: [01-overview-and-data.md](01-overview-and-data.md), [03-daemon-cli-app.md](03-daemon-cli-app.md)

## Table of Contents
1. [Module Layout](#module-layout)
2. [DomainNormalizer](#1-domainnormalizer-sourcessiteblockcoredomainnormalizerswift)
3. [Punycode](#2-punycode-sourcessiteblockcorepunycodeswift)
4. [DomainExpander](#3-domainexpander-sourcessiteblockcoredomainexpanderswift)
5. [PathRuleParser](#3a-pathruleparser-sourcessiteblockcorepathruleparserswift)
6. [TabRuleMatcher](#3b-tabrulematcher-sourcessiteblockcoretabrulematcherswift)
7. [TabReloadDecider](#3c-tabreloaddecider-sourcessiteblockcoretabreloaddeciderswift)
8. [HostsFileEditor](#4-hostsfileeditor-sourcessiteblockcorehostsfileeditorswift)
9. [PasswordHasher](#5-passwordhasher-sourcessiteblockcorepasswordhasherswift)
10. [Models and Protocol Types](#6-models-and-protocol-types)
11. [Engine](#7-engine-sourcessiteblockcoreengineswift)
12. [StateStore](#8-statestore-sourcessiteblockcorestatestoreswift)
13. [DaemonClient](#9-daemonclient-sourcessiteblockcoredaemonclientswift)
14. [Formatting](#10-formatting-sourcessiteblockcoreformattingswift)
15. [ConnectionLimiter](#11-connectionlimiter-sourcessiteblockcoreconnectionlimiterswift)
16. [UninstallRule](#12-uninstallrule-sourcessiteblockcoreuninstallruleswift)
17. [TemporaryUnblockOptions](#13-temporaryunblockoptions-sourcessiteblockcoretemporaryunblockoptionsswift)
18. [UpdateCheck](#14-updatecheck-sourcessiteblockcoreupdatecheckswift)

---

## Module Layout

`SiteBlockCore` is a Swift library with no dependency on root, launchd or the real file system paths. Every piece of policy logic lives here so it can be unit-tested. The daemon, CLI and app are thin layers on top.

The library has no third-party dependencies. It uses Foundation and, for hashing and random bytes, CommonCrypto, CryptoKit and the Security framework, which ship with macOS.

---

### 1. DomainNormalizer (`Sources/SiteBlockCore/DomainNormalizer.swift`)

**Purpose:** Turns whatever the user typed (a bare name, a full URL, a name with a port or path) into one canonical lowercase base domain, or explains why it cannot be blocked. It runs in nine steps.

**Key Methods:**
- `static func normalize(_ input: String) throws -> String` — returns the base domain, or throws `DomainError`.

**Steps, in order:**
1. Trim surrounding whitespace and newlines. Empty input throws `.empty`.
2. If the input contains `://`, take everything after it. Then cut the string at the first `/`, `?` or `#`.
3. Drop any `user:pass@` prefix (everything up to and including the last `@`).
4. Drop a `:port` suffix. Input that starts with `[` is an IPv6 literal and throws `.ipAddress`.
5. Lowercase. Remove one trailing `.`.
6. Before any encoding, check sizes on the raw Unicode scalars (single code points): more than 63 in one label throws `.labelTooLong`, and then more than 253 in the whole name throws `.tooLong`. A name that starts with `www.` may have 257, because step 8 strips those four characters. Every input scalar becomes at least one output byte, so such a name could never pass the final checks anyway. Checking first matters because Punycode encoding takes time that grows with the square of the label length, and the daemon runs it on the queue every command waits on.
7. Convert each label (the parts between dots) that contains non-ASCII characters to its `xn--` Punycode form, so `bücher.de` becomes `xn--bcher-kva.de`. See § Punycode.
8. Strip one leading `www.` so that `www.reddit.com` and `reddit.com` are stored as the same site. The expander adds `www.` back.
9. Validate:
   - total length 1–253 characters,
   - at least two labels,
   - each label 1–63 characters, only `a–z`, `0–9` and `-`, not starting or ending with `-`,
   - the last label (the top-level domain) is not all digits, which rejects IPv4 addresses such as `1.2.3.4` with `.ipAddress`,
   - the name is not `localhost` and does not end in `.local` or `.localhost` (`.reserved`), because blocking those would break the Mac itself.

**Parsing details:**
- `://` counts as a scheme separator only when it appears before any `/`, `?` or `#`. So `reddit.com/?next=https://other.com` normalizes to `reddit.com`.
- The cut at `/`, `?` or `#` (step 2) happens before the `@` removal (step 3), so an `@` in a path, query or fragment is ignored. `https://www.youtube.com/@MrBeast` normalizes to `youtube.com`, and `reddit.com?e=a@b.com` to `reddit.com`.
- A port that is not all digits (`reddit.com:abc`), an empty label (`a..com`), and any whitespace, control or invisible character (including zero-width characters such as U+200B) throw `.invalidCharacters`.
- Bare `localhost` throws `.reserved`. An empty result after parsing (`https://`, `.`) throws `.empty`.
- Only one leading `www.` is stripped.

**DomainError cases:** `empty`, `ipAddress`, `invalidCharacters`, `labelTooLong`, `tooLong`, `needsDot`, `reserved`. Each has a human sentence via `LocalizedError.errorDescription`, for example "IP addresses can't be blocked through the hosts file. Enter a site name like example.com."

---

### 2. Punycode (`Sources/SiteBlockCore/Punycode.swift`)

**Purpose:** Encodes a single Unicode label to the ASCII form defined by RFC 3492 (the standard that lets international domain names travel through systems that only understand ASCII).

**Key Methods:**
- `static func encode(_ label: String) -> String?` — returns the encoded label without the `xn--` prefix, or `nil` on overflow. Input is the label's Unicode scalars, lowercased by the caller.
- `static func toASCII(label: String) -> String?` — returns the label unchanged when it is pure ASCII, otherwise `"xn--" + encode(label)`.

**Parameters:** base 36, tmin 1, tmax 26, skew 38, damp 700, initial bias 72, initial n 128, delimiter `-`. These are the fixed values from RFC 3492 § 5.

**Behavioral notes:** The implementation does not apply full IDNA2008 mapping (the extra rules that fold look-alike characters). Lowercasing with Swift's `lowercased()` before encoding is enough for the domains a person types into a blocker.

---

### 3. DomainExpander (`Sources/SiteBlockCore/DomainExpander.swift`)

**Purpose:** Turns one normalized base domain into every host name that should go into the hosts file, because the hosts file has no wildcards.

**Key Methods:**
- `static func expand(_ domain: String) -> [String]` — returns a sorted list with no duplicates.
- `static let commonPrefixes: [String]` — `["www", "m", "mobile", "old", "new", "amp", "app", "web"]`.
- `static let relatedDomains: [String: [String]]` — extra names for well-known sites, keyed by base domain.

**Expansion rule:** the result is the base domain, plus `prefix.base` for every common prefix, plus every name in `relatedDomains[base]`, plus `www.` and `m.` in front of each related name that has exactly two labels. Then sort and remove duplicates.

**Related domains table:**
- `reddit.com`: `np.reddit.com`, `i.reddit.com`, `oauth.reddit.com`, `gateway.reddit.com`, `gql.reddit.com`, `sh.reddit.com`, `redd.it`, `i.redd.it`, `v.redd.it`, `preview.redd.it`, `external-preview.redd.it`, `redditstatic.com`, `www.redditstatic.com`, `redditmedia.com`
- `youtube.com`: `music.youtube.com`, `tv.youtube.com`, `studio.youtube.com`, `youtu.be`, `youtube-nocookie.com`, `youtubekids.com`, `youtubei.googleapis.com`, `youtube.googleapis.com`, `i.ytimg.com`, `s.ytimg.com`, `yt3.ggpht.com`
- `x.com` and `twitter.com` (same list for both): `x.com`, `twitter.com`, `mobile.twitter.com`, `mobile.x.com`, `api.x.com`, `api.twitter.com`, `pbs.twimg.com`, `abs.twimg.com`, `video.twimg.com`
- `facebook.com`: `web.facebook.com`, `mbasic.facebook.com`, `touch.facebook.com`, `fb.com`, `fb.me`
- `instagram.com`: `i.instagram.com`, `help.instagram.com`, `instagr.am`
- `tiktok.com`: `vm.tiktok.com`, `vt.tiktok.com`
- `netflix.com`: `help.netflix.com`
- `twitch.tv`: `clips.twitch.tv`, `player.twitch.tv`, `gql.twitch.tv`
- `linkedin.com`: `lnkd.in`

**Behavioral notes:** Shared infrastructure names such as `t.co`, `fbcdn.net` and `googlevideo.com` are left out on purpose. Each serves more than one product (for example `fbcdn.net` also carries Instagram and WhatsApp images), so blocking them would break sites the user did not ask to block.

---

### 3a. PathRuleParser (`Sources/SiteBlockCore/PathRuleParser.swift`)

**Purpose:** Turns typed text such as `youtube.com/shorts` or `https://www.youtube.com/shorts/abc?x=1` into a path rule, or says the text has no path (so it is a whole-site block), or explains why it cannot be used.

**Key Methods:**
- `static func split(_ input: String) -> (host: String, path: String?)` — trims the text, drops a `scheme://`, any `user@` part and a `:port`, cuts at the first `?` or `#`, and returns the host part and the path (everything from the first `/`). The path is `nil` when there is none, or when it is only `/` or empty; that means "whole site".
- `static func parse(_ input: String) throws -> (domain: String, path: String)` — normalizes the host with `DomainNormalizer.normalize` (so `www.` is stripped and every DomainNormalizer error applies), then checks the path: it must exist (else `PathRuleError.noPath`), is at most 256 characters (measured after the trailing `*` and `/` are removed; longer throws `PathRuleError.tooLong`), keeps its case, has trailing `*` characters and then trailing `/` characters removed (`/shorts/` and `/shorts*` both become `/shorts`), and may contain only letters, digits and `- . _ ~ / % ! $ & ' ( ) + , ; = : @` (anything else, including spaces, `*` in the middle, `"`, `<`, `>`, `\`, `^`, `` ` ``, `{`, `|`, `}`, throws `PathRuleError.invalidCharacters`). A path that becomes `/` or empty after this throws `noPath`.
- `static func display(domain:path:) -> String` — `youtube.com/shorts`.

**Browser entries:**
- `static func chromeEntry(domain:path:) -> String` — `youtube.com/shorts` (Chrome's format matches the domain, its subdomains, and any path that starts with the given one).
- `static func firefoxPattern(domain:path:) -> String` — `*://*.youtube.com/shorts*` (a WebExtension match pattern: any scheme, the domain and its subdomains, any path starting with the given one).

---

### 3b. TabRuleMatcher (`Sources/SiteBlockCore/TabRuleMatcher.swift`)

**Purpose:** Decides whether the address shown in a browser tab falls under a path rule. It applies the same matching the browsers apply to their own block lists, so the tab watcher reloads only tabs that the browser will then block. It is a pure function over strings with no browser access.

**Types:**
- `public struct WatchedPathRule: Hashable, Sendable` — one path rule as the daemon reports it in `StatusSnapshot.blockedPaths`.
  - `domain: String` — already normalized: lowercase, Punycode for non-ASCII labels, no leading `www.`.
  - `path: String` — starts with `/`, keeps its case, and has no trailing `/` or `*`.
- `public enum TabRuleMatcher` — holds the two functions below.

**Key Methods:**
- `static func matchingRule(url: String, rules: [WatchedPathRule]) -> WatchedPathRule?` — returns the first rule, in list order, that the address falls under, or `nil` when none does.
- `static func matches(url: String, rule: WatchedPathRule) -> Bool` — tells whether the address falls under that one rule.

**Matching steps, in order:**
1. Parse the text with `URLComponents(string:)`. When it cannot be parsed, there is no match.
2. The scheme, compared without regard to case, must be `http` or `https`. Any other scheme (`chrome:`, `about:`, `file:`, `data:`, `javascript:`) and a missing scheme give no match.
3. Take the host. When it is `nil` or empty, there is no match. When it holds a character that cannot be in a real host name (`/ ? # @ : \ [ ]`, whitespace or a control character), there is no match. `URLComponents.host` turns percent-escapes back into characters, so `https://youtube.com%2Fx.evil.com/shorts` arrives with the host `youtube.com/x.evil.com`; without this check the normalizer would cut it down to `youtube.com` and it would match a site it does not belong to. Otherwise run it through `DomainNormalizer.normalize`, the same normalizer the rules went through, so it is lowercased, converted to Punycode when it has non-ASCII characters, stripped of one trailing `.`, and stripped of a leading `www.`. When normalizing throws, there is no match.
4. The host matches when it equals the rule's `domain` or ends with `"." + domain`. So `m.youtube.com` matches `youtube.com`, and `notyoutube.com` does not.
5. Take `percentEncodedPath`, and use `/` when it is empty. `URLComponents` percent-encodes a raw space or control character in the path, so `https://youtube.com/shorts abc` is compared as `/shorts%20abc` and matches; browsers always report such an address already encoded. The path matches when it starts with the rule's `path` as a plain, case-sensitive string prefix. So `/shorts`, `/shorts/abc` and `/shortsXYZ` all match `/shorts`, and `/Shorts` does not.
6. The port, user info, query and fragment play no part in the decision.

**Behavioral notes:** The steps mirror what Chrome's `youtube.com/shorts` entry and Firefox's `*://*.youtube.com/shorts*` pattern match (see § PathRuleParser, Browser entries). The browsers treat the path as a plain prefix, which is why `/shortsXYZ` matches; the matcher does the same so that it never reloads a tab the browser would leave open. Because the user-info part is not the host, an address such as `https://youtube.com@other.com/shorts` is judged by `other.com`. A subdomain the normalizer refuses (one with an underscore, such as `a_b.youtube.com`, or a label longer than 63 characters) gives no match, so the watcher leaves that tab alone and the browser applies its block list on the next load.


**Rules for the tab watcher:** `public extension StatusSnapshot { var watchedPathRules: [WatchedPathRule] }` turns a status snapshot into the list the tab watcher looks for: every path rule except one whose own temporary unblock is open (`temporaryUnblock?.isOpen == true`), because the browsers' block lists do not hold an open rule. Rules waiting to open or waiting to unblock for good stay in, because they are still blocked. A snapshot from an older daemon with no path rules gives an empty list.
---

### 3c. TabReloadDecider (`Sources/SiteBlockCore/TabReloadDecider.swift`)

**Purpose:** Decides which tabs to reload, and remembers which tab it has already acted on at which address, so a tab that is showing the browser's block page is never reloaded over and over. It is a value type with no browser access; the tab watcher feeds it the tab lists it reads.

**Properties:**
- Memory: for each process ID (`Int32`), a dictionary from tab ID (`String`) to the address the decider last acted on for that tab.

**Key Methods:**
- `public mutating func tabsToReload(processID: Int32, tabs: [(id: String, url: String)], rules: [WatchedPathRule]) -> [String]` — called with the complete tab list of one browser process. The returned tab IDs keep the order of the input. For each tab:
  - When its address matches a rule (through `TabRuleMatcher.matchingRule`) and the remembered address for that tab is different or missing, the tab ID is returned and the address is remembered.
  - When it matches and the remembered address is the same, nothing happens.
  - When it does not match, the memory for that tab is dropped, so going back to the blocked part later reloads the tab again.
  - Memory for tab IDs that are not in the list is dropped.
  - With no rules, the method returns nothing and clears that process's memory.
- `public mutating func forgetProcesses(except running: Set<Int32>)` — drops the memory of every process that is not in the set, which is how memory for exited browsers is released.
- `public mutating func forgetAll()` — drops all memory.
- `public func remembered(processID: Int32) -> [String: String]` — read-only view of one process's memory, for tests.

**Behavioral notes:** A process whose tab list could not be read in a given tick is not passed to `tabsToReload` in that tick, so its memory is kept and a later successful read continues from it. Different processes never share memory, even when two of them use the same tab ID.


**Repeated tab id:** a browser never lists the same tab id twice in one answer, but when a list does, the tab is handled once, by its first appearance: that appearance decides whether the id is returned and which address is remembered, and later appearances are ignored.
---

### 4. HostsFileEditor (`Sources/SiteBlockCore/HostsFileEditor.swift`)

**Purpose:** Takes the current text of a hosts file and the set of host names that must be blocked, and returns the corrected text. It is a pure function over strings, with no file access, so it can be tested on any input.

**Constants:**
- `beginMarker = "# BEGIN SiteBlock — managed by siteblockd; edits inside this block are reverted"`
- `endMarker = "# END SiteBlock"`

A line counts as a BEGIN marker when its trimmed text starts with `# BEGIN SiteBlock`, and as an END marker when its trimmed text equals `# END SiteBlock`.

**Key Methods:**
- `static func render(original: String, blockedHosts: [String]) -> String` — returns the corrected file text.
- `static func managedSection(for blockedHosts: [String]) -> String` — returns the BEGIN line, then for each host in sorted order the two lines `0.0.0.0 <host>` and `:: <host>`, then the END line.
- `static func isCompliant(_ text: String, blockedHosts: [String]) -> Bool` — `true` when `render(original: text, ...) == text`.

**Render steps:**
1. Split the original into lines (accept `\n` and `\r\n`, write `\n`).
2. Remove every managed section. Each END line closes the section that starts at the nearest BEGIN line above it that is not already closed. Only that BEGIN, the END, and the lines between them are removed. Every other BEGIN line (one with no END below it, or an earlier BEGIN that a later BEGIN superseded) is removed as a single line, and so is an END line with no open BEGIN above it. This pairing means a comment the user wrote such as `# BEGIN SiteBlock entries I added myself`, far above the real section, costs only that one comment line and never the user's entries between it and the real section.
3. In every remaining line that is not a comment, look at the host names after the address, reading the line the way the macOS resolver does. The line ends at the first NUL character or `#`. Fields are separated only by ASCII spaces and tabs. A name is compared after lowercasing ASCII letters and removing one trailing `.`. Remove any name that then equals a blocked host. If the line has no names left, drop the line. This stops a hand-added line such as `151.101.1.140 reddit.com` or `151.101.1.140 reddit.com.`, which macOS would otherwise use because it reads the first match. Lines with no blocked name are left exactly as they were.
4. Remove trailing empty lines, then add one `\n` if the text is not empty.
5. If `blockedHosts` is not empty, append one empty line and the managed section, ending with `\n`.

**Input guard:** `render` and `managedSection` trim and lowercase each entry of `blockedHosts`, then drop any entry that is empty or contains a character outside `a–z 0–9 - .`, and any entry that is `localhost`, `broadcasthost`, or ends in `.local` or `.localhost`. Those names are never blocked because step 3 would also delete the stock lines (`127.0.0.1 localhost`, `255.255.255.255 broadcasthost`, `::1 localhost`) the Mac needs. Duplicates are removed. The engine only ever passes normalized names, but blocked hosts are reloaded from `state.json`, so this check is the last gate before text reaches root's hosts file. A hostile entry such as `"evil.com\n0.0.0.0 bank.com"` therefore produces no line at all.

**Line breaks:** `\n`, `\r\n` and a lone `\r` all count as line breaks on input. Output always uses `\n`.

**Comments on rewritten lines:** when step 3 removes a name from a user line, the line's trailing comment (if any) is kept as ` #comment`.

**Behavioral notes:** Running `render` on its own output returns the same text (it is idempotent), which is what lets the daemon compare and only rewrite when something changed. With an empty block list, `render` removes the section and leaves the user's own lines.

---

### 5. PasswordHasher (`Sources/SiteBlockCore/PasswordHasher.swift`)

**Purpose:** Creates and checks `PasswordHash` values.

**Key Methods:**
- `static func make(password: String, iterations: Int = 210_000) throws -> PasswordHash` — fills a 16-byte salt from `SecRandomCopyBytes` (the system's secure random number generator) and derives 32 bytes with `CCKeyDerivationPBKDF` using `kCCPRFHmacAlgSHA256`.
- `static func verify(password: String, against: PasswordHash) -> Bool` — derives the full 32 bytes again with the stored salt and iteration count and compares in constant time. A stored hash that is not exactly 32 bytes never matches (every byte is compared even after a mismatch, so timing does not reveal how many bytes matched). Returns `false` for an unknown algorithm or bad Base64.
- `static func validateNew(_ password: String) throws` — throws `PasswordError.tooShort` when the password has fewer than 6 characters (counted as Swift `Character`s, not bytes). Otherwise it throws `.whitespaceOnly` when every character is whitespace (spaces, tabs or newlines). The length rule runs first, so `"   "` reports `tooShort`.
- A stored `iterations` value below 1 or above `UInt32.max` makes `verify` return `false` instead of crashing.

**Behavioral notes:** Passwords are hashed as their UTF-8 bytes with no Unicode normalization. Leading and trailing spaces are kept as part of the password.

---

### 6. Models and Protocol Types

**Files:** `Sources/SiteBlockCore/Models.swift`, `Sources/SiteBlockCore/Protocol.swift`, `Sources/SiteBlockCore/BuildNumber.swift`

`Models.swift` holds the persisted types from [01-overview-and-data.md](01-overview-and-data.md) § Data Model: `PersistedState`, `BlockedSite`, `Countdown`, `PasswordHash`, `PendingDelayChange`, `TemporaryUnblock`. All are `Codable` and `Equatable` structs.

`Countdown` has:
- `init(seconds: Double)` — sets both `remainingSeconds` and `totalSeconds`.
- `mutating func advance(by elapsed: Double)` — subtracts, clamps at `0`, and ignores negative or non-finite input so a bad clock reading cannot add time or finish a countdown early. A remainder below `1e-9` seconds (one nanosecond) is set to exactly `0`. Without this, rounding error in floating-point subtraction would leave a countdown that ran 18,000 ticks of 0.1 seconds on a 1,800-second wait with a few billionths of a second left, so it would need one extra tick. A remainder of `1e-6` seconds is still running.
- `var isFinished: Bool` — `remainingSeconds <= 0`.
- `var displaySeconds: Int` — `remainingSeconds` rounded up, so a countdown never shows `0` while it is still running.

`TemporaryUnblock` has `startsIn` and `window` (two `Countdown` values) and the computed `isOpen` and `isFinished`, all described in [01-overview-and-data.md](01-overview-and-data.md) § Data Model. `BlockedSite.temporaryUnblock` and `BlockedPath.temporaryUnblock` are optional in the file: a missing key decodes as `nil`, so a `state.json` written without them is not corrupt. A `temporaryUnblock` object that is present but cannot be read (for example it lacks `startsIn` or `window`) is dropped, decoding as `nil`, and the rest of the file loads. A file that fails to load is set aside as corrupt, which could take the block list with it, while dropping the record only means the site or rule stays blocked.

`Protocol.swift` holds `Request`, `Response`, `StatusSnapshot`, `BlockedSiteStatus`, `PendingDelayStatus`, `TemporaryUnblockStatus`, the `Command` enum (raw `String` values matching the command names in [01-overview-and-data.md](01-overview-and-data.md) § Commands) and the `ErrorCode` enum. `Request` carries the optional `startSeconds`. The `Command` enum has `temporaryUnblock` and `temporaryUnblockPath`, and the `ErrorCode` enum has `invalidDuration` and `alreadyPending`. `BlockedSiteStatus` and `BlockedPathStatus` carry an optional `temporaryUnblock` of type `TemporaryUnblockStatus`, which decodes as `nil` when the key is missing. JSON uses the default `JSONEncoder` with `.sortedKeys`, field names exactly as written in the design.

**Version constants:** `Models.swift` declares `siteBlockVersion`, the version string that the daemon, the CLI and the app show, defined as `"1.0."` followed by `siteBlockBuildNumber`. `siteBlockBuildNumber` is an `Int` constant declared in `BuildNumber.swift`. That file is generated by `scripts/write-build-number.sh` and listed in `.gitignore`, so it is not part of the repository and holds the number of commits on the checked-out branch, or `0` when git was not available (see [04-infrastructure.md](04-infrastructure.md) § Version Numbers). The three programs read the constants from this library, so programs built from one checkout always show the same version. The daemon puts `siteBlockVersion` into `StatusSnapshot.version`. The menu bar app compares `siteBlockBuildNumber` with the published build number (see § UpdateCheck).

---

### 7. Engine (`Sources/SiteBlockCore/Engine.swift`)

**Purpose:** The whole policy of SiteBlock in one class: it holds the state, applies commands, advances countdowns, and reports what the hosts file should contain. It does no I/O, so tests drive it directly with fake time.

**Properties:**
- `private(set) var state: PersistedState`
- `let policy: Policy` — the fixed values from [01-overview-and-data.md](01-overview-and-data.md) § Fixed Policy Values, as a struct so sandbox mode and tests can shrink them. Fields: `defaultDelaySeconds`, `minDelaySeconds`, `maxDelaySeconds`, `recoverySeconds`, `lockoutSeconds`, `maxFailedAttempts`, `pbkdf2Iterations`, `maxSites`, `minUninstallSeconds`, `minTemporarySeconds`, `maxTemporarySeconds`, `maxTemporaryStartSeconds`, `saveIntervalSeconds`. `Policy.production` must hold exactly 1800, 60, 604800, 172800, 900, 5, 210000, 500, 172800 (the uninstall minimum), 300, 14400, 604800 (the three temporary unblock limits: shortest window, longest window, longest start wait) and 15 (`saveIntervalSeconds`, how many seconds may pass between saves of the state while any countdown is running; the daemon runtime reads it, the engine does not). `Policy.fastForTests.minUninstallSeconds` is 2. `Policy.fastForTests.minTemporarySeconds` is 1, so integration tests can open and close a window within seconds; its other two temporary unblock values equal the production values. `Policy.fastForTests.saveIntervalSeconds` is 2, so a test sees the periodic save within seconds.
- `var blockedHosts: [String]` — every host of every blocked site, sorted, no duplicates. Sites with a pending unblock are still included, because they stay blocked until the countdown ends, and so are sites whose temporary unblock is waiting. Sites whose temporary unblock is open are left out. A host that another blocked site, one that is not open, also lists stays in.
- `static let privateRelayHosts` — `["mask-h2.icloud.com", "mask.icloud.com"]`.
- `var adultFilterActive: Bool` — always `true`, except once `uninstalling` is `true` (the uninstaller then restores everything).
- `static let dohBypassHosts` — `["doh.xfinity.com", "firefox.dns.nextdns.io", "mozilla.cloudflare-dns.com", "private.canadianshield.cira.ca"]`, the hostnames browsers use for DNS-over-HTTPS by default.
- `var hostsToWrite: [String]` — what the runtime writes into the hosts file: `blockedHosts` plus `privateRelayHosts` and `dohBypassHosts` whenever `adultFilterActive` is true (so, in practice, always), sorted and without duplicates. See [01-overview-and-data.md](01-overview-and-data.md) § How Blocking Works for why.
- `var onUninstall: (() -> Void)?` — called once when the uninstall countdown finishes.
- `var onTemporaryUnblockEvent: ((String) -> Void)?` — called with one sentence each time a temporary unblock is approved, opens, ends, is cancelled while it waits, or is ended early while it is open. The engine builds the sentence, which never names the site or the rule, because the daemon log never holds a domain. The runtime sets it to write the sentence to the log; the sentences are listed in [03-daemon-cli-app.md](03-daemon-cli-app.md) § Daemon Runtime.

**Key Methods:**
- `init(state: PersistedState, policy: Policy)`
- `func handle(_ request: Request, peerUID: uid_t) -> Response` — runs one command and always returns a response; it never throws. Every successful response carries `status`.
- `func tick(elapsed: Double) -> Bool` — advances every countdown by `elapsed` seconds and applies the ones that finished. Returns `true` when the state changed in a way that must be saved now (a countdown finished, or a temporary unblock opened).
- `func snapshot(hostsFileHealthy: Bool) -> StatusSnapshot`

**Password check rule** (shared by every command that takes a password):
1. If `lockout` is running, fail with `lockedOut` and say how many minutes are left. The password is not checked at all.
2. If no password is set, fail with `notSetUp`.
3. If the password is wrong, add 1 to `failedAttempts`. When it reaches `maxFailedAttempts`, start `lockout` and reset `failedAttempts` to 0. Fail with `wrongPassword` and say how many tries are left.
4. If the password is right, reset `failedAttempts` to 0 and continue.

**Who may set up:** `var consoleUID: () -> uid_t?` returns the user ID of the person logged in at the screen. The runtime sets it in production to read the owner of `/dev/console`. It defaults to returning `nil`, and `nil` means any caller may run `setup`, which is what sandbox runs and tests use. When it returns an ID, `setup` succeeds only for `peerUID == 0` or `peerUID` equal to that ID, and fails with `notAllowed` otherwise. The check comes before `alreadySetUp`.

**Site cap:** adding a new site when `policy.maxSites` sites are already blocked fails with `tooManySites`. Re-adding an existing site (to cancel its unblock) is not affected. `Policy.production.maxSites` is 500; `Policy.fastForTests.maxSites` is 20, so tests can reach the cap quickly.

**Path rules:**
- `addPath`: parse the rule text with `PathRuleParser.parse` (`invalidDomain` for host errors, `invalidPath` for path errors and for text with no path). If the whole domain is already in `blocked`, fail `alreadyBlocked` ("youtube.com is already fully blocked"). If the same domain and path exist with a pending unblock or a temporary unblock, clear it (the same way `add` does); if they exist with neither, fail `alreadyBlocked`. Otherwise, like `add`: `notSetUp` without a password, `tooManySites` when `blocked.count + blockedPaths.count` would exceed `maxSites`, then append.
- `unblockPath` and `cancelUnblockPath` follow `unblock` and `cancelUnblock` exactly, keyed by domain and path. `temporaryUnblockPath` follows `temporaryUnblock` (see Temporary unblock commands below).
- Tick: remove path rules whose unblock finished (a change that must be saved). A path rule's temporary unblock follows the temporary unblock tick rule below.
- Adding the whole domain later keeps its path rules (they become redundant while the whole site is blocked, and matter again if the whole site is unblocked).

**Browser block list:** `var browserBlockEntries: (chrome: [String], firefox: [String])` builds both browsers' lists from the sites and path rules that are not open. Chrome: `ChromePolicy.urlBlocklist(for:)` applied to the sites whose temporary unblock is not open (the covering host list) plus `chromeEntry` for every path rule whose own temporary unblock is not open and whose domain is not covered by one of those whole-site blocks, sorted. Firefox: `*://*.<host>/*` for every covering host plus `firefoxPattern` for the same path rules, sorted. A site whose temporary unblock is waiting stays in the lists. A path rule on a site whose whole site is open is included, because with the whole site open that rule is what still blocks that part of it. A path rule whose own temporary unblock is open is left out.

**Argument rule:** a missing required argument fails with `badRequest` before any lockout or password check, so a malformed request never costs a password attempt. `setDelay` also checks the range (`invalidDelay`) before the password.

**Command rules:**
- `add`: normalize (fail `invalidDomain` with the normalizer's sentence). If already blocked with a pending unblock, clear the pending unblock and say "Unblock cancelled; reddit.com stays blocked." This works even when no password is set, because after a finished recovery `add` is the only way to stop an unblock that was already counting down. If already blocked with a temporary unblock, waiting or open, clear it and answer with the same sentence the cancel commands give for that case (see below); this also works without a password. An entry holding both kinds at once (only a hand-edited file can hold that) has both cleared. If already blocked without one, fail `alreadyBlocked`. Only a new site needs a password to exist (`notSetUp`). Otherwise append a `BlockedSite` with its expanded hosts.
- `unblock`: normalize, find the site (fail `notBlocked`), fail `alreadyPending` when the site has a `temporaryUnblock` ("reddit.com has a temporary unblock. Keep it blocked first if you want to unblock it for good."), check the password, then set `pendingUnblock = Countdown(seconds: delaySeconds)`. The `alreadyPending` check comes before the password check, so it never counts a wrong password. If one is already pending, keep the existing countdown (do not restart it) and report its remaining time.
- `setDelay`: validate the range (fail `invalidDelay`), check the password. A value greater than or equal to the current delay applies at once and clears `pendingDelayChange`. A smaller value replaces any existing `pendingDelayChange` with a new one whose countdown starts again at the current delay.
- `changePassword`: check the old password, validate the new one (`weakPassword`), store a new hash.
- `uninstall`: check the password, start `pendingUninstall` at `uninstallWaitSeconds` (the larger of `policy.minUninstallSeconds` and `delaySeconds`) unless one is already running.
- `recoveryStart`: fail `notRoot` unless `peerUID == 0`. Fail `notSetUp` if no password is set. Start `recovery` at `recoverySeconds` unless already running.
- Cancel commands clear their countdown, or fail `nothingPending` when there is none. `cancelUnblock` and `cancelUnblockPath` clear a `pendingUnblock` first. When there is none, they clear a `temporaryUnblock`: a waiting one says "The temporary unblock is cancelled; reddit.com stays blocked." and an open one says "reddit.com is blocked again." They fail `nothingPending` only when neither exists. Neither needs a password. `cancelUninstall` also fails `nothingPending` once the uninstall countdown has finished and `uninstalling` is `true`, because removal has already begun.

**Temporary unblock commands:** `temporaryUnblock` takes `domain`, `password`, `seconds` (the window, how long the site stays open) and an optional `startSeconds` (the start wait, the time before it opens). `temporaryUnblockPath` takes the same fields, with `domain` holding the rule text. Every reply names the site in its normalized form (`https://www.Reddit.com/r/all` is answered as `reddit.com`) and a path rule in its display form (`youtube.com/shorts`), never the text as typed; the same holds for the cancel replies. Both run these checks in this order, which follows the argument rule: a request that is malformed or out of range is refused before any lockout or password check, so it never counts as a wrong password.
1. Fail `badRequest` when `domain`, `password` or `seconds` is missing.
2. Normalize the domain (fail `invalidDomain`), or parse the rule text with `PathRuleParser.parse` (fail `invalidDomain` for host errors and `invalidPath` for path errors).
3. Find the site or rule, or fail `notBlocked`.
4. Fail `alreadyPending` when it has a `pendingUnblock` ("reddit.com is already waiting to unblock. Keep it blocked first if you want a temporary unblock instead.") or a `temporaryUnblock` ("reddit.com already has a temporary unblock.").
5. Fail `invalidDuration` when `seconds` is outside `policy.minTemporarySeconds` to `policy.maxTemporarySeconds`, both included. The sentence names the limit that was broken: "It must stay open for at least 5 minutes." for a window that is too short and "It can't stay open for more than 4 hours." for one that is too long (the numbers come from the policy).
6. The start wait is `startSeconds`, or `delaySeconds` when `startSeconds` is missing. Fail `invalidDuration` when it is less than `delaySeconds` ("It can't open sooner than your unblock delay of 1 hour." for a delay of 1 hour) or more than `policy.maxTemporaryStartSeconds`.
7. Run the password check rule (lockout, no password set, wrong password).
8. Set `temporaryUnblock` on the site or rule to a `TemporaryUnblock` with `startsIn = Countdown(seconds: start wait)` and `window = Countdown(seconds: seconds)`. The message reads like "reddit.com opens in 1 hour, for 30 minutes, then blocks again."

**Lockout wording:** the lockout message gives the remaining time in whole minutes rounded up, so 59.5 seconds left reads "1 minute" and the message never says "0 minutes". Under one minute left it may use seconds instead. The wrong-password message says "1 try left" in the singular.

**Finished-but-uncleared lockout:** a lockout whose countdown reached 0 but which the next tick has not cleared yet does not block a password check. The check clears it and proceeds.

**Hosts health:** `setHostsHealthy(_ healthy: Bool)` records the result of the runtime's last enforcement pass, and every snapshot built by `handle` reports it as `hostsFileHealthy`. It starts as `true`.

**Tick rule:** advance every countdown by `elapsed`. Then in this order: remove sites whose unblock finished; apply a finished delay change; clear a finished lockout; for a finished recovery, set `passwordHash = nil`, `failedAttempts = 0`, `lockout = nil` and clear `recovery`; for a finished uninstall, set `uninstalling = true` and call `onUninstall`.

**Temporary unblock tick rule:** the same `elapsed` also advances the `temporaryUnblock` of every site and path rule. `startsIn` is advanced first. The part of `elapsed` that `startsIn` did not use, because it reached `0` during this tick, is taken off `window`. When `startsIn` was already `0`, all of `elapsed` is taken off `window`. Neither countdown goes below `0`. `tick` returns `true`, so the runtime saves the state now, in two cases: a temporary unblock opened (its `startsIn` reached `0` during this tick), and a temporary unblock finished (its `window` reached `0`). A finished one is removed by setting `temporaryUnblock` to `nil`, and the site or rule stays on the block list. When one long gap, such as the Mac asleep, covers both the opening and the end, the temporary unblock simply finishes in that tick. Each opening and each ending is reported once to `onTemporaryUnblockEvent`; a gap that covers both reports only the ending. A stored temporary unblock that is already finished when a tick runs (which only a hand-edited or older file can hold) is removed on that tick, the tick returns `true`, and the ending is reported.

**Status of a temporary unblock:** `snapshot` fills `temporaryUnblock` on the status of each site and path rule that has one. `opensInSeconds` is `startsIn.displaySeconds` (rounded up) while waiting and `nil` once open. `secondsRemaining` is the full window length while waiting and `window.displaySeconds` (rounded up) while open. `windowSeconds` is the window's `totalSeconds`, and `isOpen` is the stored `isOpen`.

---

### 8. StateStore (`Sources/SiteBlockCore/StateStore.swift`)

**Purpose:** Reads and writes `state.json` and its backup copy safely.

**Key Methods:**
- `init(url: URL, backupURL: URL? = nil)` — the daemon passes `Paths.stateBackup` as the backup.
- `func load() -> PersistedState?` — returns the primary file's state when it decodes. When the primary exists but cannot be decoded, it renames it to `state.json.corrupt-<unix time>`. When the primary is missing or corrupt, it returns the backup's state if that decodes, otherwise `nil`, so the daemon starts fresh instead of crashing in a restart loop.
- `func save(_ state: PersistedState) throws` — encodes with sorted keys and writes the primary and then the backup. Each write goes to a temp file in the same folder with mode `0600` and is then renamed over the target. The rename is atomic (the file is either the old version or the new version, never half-written).
- `func matchesLastSave() -> Bool` — `false` when either file is missing or its bytes differ from what this store last wrote or loaded. A store that has neither saved nor loaded returns `true`. The daemon uses it to undo hand edits.

**Failure and naming details:** `save` throws when either the primary or the backup write fails, so the daemon knows to retry. When a corrupt file is renamed and `state.json.corrupt-<unix time>` already exists (two corrupt loads in the same second), a counter suffix keeps both files, as in `state.json.corrupt-<unix time>-1`. The `version` field is decoded but not checked. A file that is valid JSON but lacks any required field (for example `{}` or `{"version":1}`) does not decode, so it is treated as corrupt. The `temporaryUnblock` key on a site or path rule is not required: a file without it decodes with `nil`, so a missing key never makes the file count as corrupt.

---

### 9. DaemonClient (`Sources/SiteBlockCore/DaemonClient.swift`)

**Purpose:** The client side of the wire protocol, used by both the CLI and the app.

**Key Methods:**
- `init(socketPath: String = "/var/run/siteblock.sock", timeout: TimeInterval = 10)`
- `func send(_ request: Request) throws -> Response` — opens a new `AF_UNIX` stream socket, connects, writes the JSON line, reads until `\n` or end of stream, and decodes. Throws `ClientError.notRunning` when the socket file is missing or the connection is refused, `.timeout` when no reply arrives in time, and `.badResponse` when the reply is not valid JSON.
- `static var defaultSocketPath: String` — reads the `SITEBLOCK_SOCKET` environment variable when set, otherwise `/var/run/siteblock.sock`. Tests and sandbox runs set the variable.

---

### 10. Formatting (`Sources/SiteBlockCore/Formatting.swift`)

**Purpose:** Shared human text for durations, so the CLI and the app say the same thing.

**Key Methods:**
- `static func duration(_ seconds: Int) -> String` — `45 seconds`, `1 minute`, `30 minutes`, `1 hour 5 minutes`, `2 days 3 hours`. It shows at most the two largest non-zero units.
- `static func clock(_ seconds: Int) -> String` — `29:41` under one hour, `1:05:09` under one day, `2d 03:04:05` otherwise.
- `static func compact(_ seconds: Int) -> String` — the short one-line form that `siteblock status` uses: `45s` under a minute. From a minute up it counts whole minutes, rounded up, and writes at most two units: `42m`, `1h`, `1h 30m`, `2d 3h`. When days are present the leftover minutes are dropped. Rounding up happens before the value is split into units, so 3541 seconds reads `1h`, not `60m`. A negative value reads as `0s`.
- `static func parseDuration(_ text: String) -> Int?` — accepts `90`, `90s`, `15m`, `2h`, `1d`, and combinations such as `1h30m`. Plain numbers are seconds. Surrounding whitespace is trimmed and units are case-insensitive (`15M` works). Units may appear in any order, but each at most once. A number without a unit after a unit (`1h30`), signs, decimals and non-ASCII digits return `nil`.

`clock` pads every unit after the first to two digits and leaves the first unpadded: `5:03`, `29:41`, `1:05:09`, `2d 03:04:05`.

---

### 11. ConnectionLimiter (`Sources/SiteBlockCore/ConnectionLimiter.swift`)

**Purpose:** Decides whether the daemon's socket server may take one more connection from a given user, so one account cannot hold every slot.

**Key Methods:**
- `init(perUserLimit: Int = 4, total: Int = 32, rootReserved: Int = 4)`
- `func admit(uid: uid_t) -> Bool` — root (uid 0) is admitted while fewer than `total` connections are open in all. A non-root user is admitted while it holds fewer than `perUserLimit` connections and fewer than `total - rootReserved` connections are open in all, counting root's. The last `rootReserved` slots are therefore always free for root. `UInt32.max`, the ID used when the peer lookup fails, is an ordinary non-root user.
- `func release(uid: uid_t)` — frees one slot for that user; a release for a user with nothing open does nothing, so no count goes below zero.

**Behavioral notes:** Thread-safe with an `NSLock`, because the accept thread admits and the connection threads release.

---

### 12. UninstallRule (`Sources/SiteBlockCore/UninstallRule.swift`)

**Purpose:** The one rule for "has an uninstall really finished", shared by the daemon's startup and the watchdog.

**Key Methods:**
- `PersistedState.hasFinishedUninstall: Bool` (in `Models.swift`) — `true` only when `uninstalling` is `true` and `pendingUninstall` exists and is finished.
- `static func watchdogShouldStandDown(stateFileData: Data?) -> Bool` — decodes the bytes of `state.json` and returns `hasFinishedUninstall`; returns `false` for missing or undecodable data, so damage to the state file keeps the watchdog guarding.

---

### 13. TemporaryUnblockOptions (`Sources/SiteBlockCore/TemporaryUnblockOptions.swift`)

**Purpose:** The fixed choices and wording behind the menu bar app's "For a while" form. They live in the library so they can be tested without a window. Nothing here talks to the daemon, and the daemon applies its own limits again when the request arrives.

**Key Methods:**
- `static let windowChoices: [Int]` — the windows the form offers, in seconds: 900, 1800, 3600, 7200 and 14400 (15 minutes, 30 minutes, and 1, 2 and 4 hours). All of them lie inside the daemon's range of 5 minutes to 4 hours.
- `static func startChoices(delaySeconds: Int) -> [Int]` — the start waits the form offers, shortest first: `delaySeconds` itself (the soonest the daemon allows), then each of 2, 3, 4, 6, 8, 12 and 24 hours, in seconds, that is longer than `delaySeconds`. With a delay of 24 hours or more, only the delay is offered.
- `static func label(forSeconds seconds: Int) -> String` — names a length of time for the pickers and the row. A whole number of hours from 1 to 24 is written in hours ("1 hour", "24 hours"); any other length is written by `Formatting.duration`. It is only called with the positive lengths the form offers and the daemon reports.
- `static func scheduleText(startSeconds: Int, windowSeconds: Int?, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String` — the gray line under the form's pickers: "Opens at 3:42 PM, blocks again at 4:42 PM." once a window is chosen, and "Opens at 3:42 PM." before that. The opening time is `startSeconds` after `now`, and the closing time `windowSeconds` after that.
- `static func clockPhrase(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String` — "at 3:42 PM" on the same day as `now`, "tomorrow at 3:42 PM" on the next day, and the abbreviated weekday and date after that ("Tue, Oct 21 at 3:42 PM"). Days are judged in the calendar's time zone, and times are written in that time zone and the given locale.

---

### 14. UpdateCheck (`Sources/SiteBlockCore/UpdateCheck.swift`)

**Purpose:** Holds the pure logic of the update check: what the published version file must say before the app trusts it, whether a published build is newer than the installed one, and whether a downloaded file matches its checksum. It does no networking and starts no process. The menu bar app's `Updater` ([03-daemon-cli-app.md](03-daemon-cli-app.md) § Updater) downloads the files and asks this type to judge them, so every decision can be tested without a network.

**Types:**
- `public struct UpdateInfo: Codable, Equatable, Sendable` — what the published `version.json` says about the newest build. Its properties:
  - `version: String` — the version text, in the form `1.0.<build>`.
  - `build: Int` — the build number, which is the number of commits the package was built from.
  - `commit: String` — the full hash of the commit the package was built from.
  - `asset: String` — the file name of the package, `SiteBlock.zip`.
  - `sha256: String` — the SHA-256 checksum of `SiteBlock.zip`. SHA-256 turns a file into a 64-character fingerprint, and changing any byte of the file changes the fingerprint completely.
- `public enum UpdateCheck` — holds the two constants and three functions below.

**Constants:**
- `static let versionURL: URL` — `https://github.com/nokal123/SiteBlock/releases/latest/download/version.json`, the address of the version file.
- `static let packageURL: URL` — `https://github.com/nokal123/SiteBlock/releases/latest/download/SiteBlock.zip`, the address of the package.

Both addresses are written into the code. Nothing outside the code can point the app at another server, because `version.json` carries only the package's file name, and the app builds the download address from `packageURL` itself.

**Key Methods:**
- `static func parse(_ data: Data) -> UpdateInfo?` — decodes the JSON and returns the info only when all of these hold: `build` is greater than 0; `version` equals `1.0.` followed by `build`; `asset` equals `SiteBlock.zip`; `sha256` is exactly 64 lowercase hexadecimal characters; and `commit` is exactly 40 lowercase hexadecimal characters. In every other case it returns `nil`, which means "no usable update information". That covers a missing field, a field of the wrong type, text that is not JSON, empty data, and a build of 0 or below. It never crashes. Extra fields in the JSON are ignored.
- `static func isNewer(_ info: UpdateInfo, than installedBuild: Int) -> Bool` — `true` when `info.build` is greater than `installedBuild`, and `false` for an equal or lower build. Programs built outside a git checkout have the build number 0, so for them every published build is newer.
- `static func matchesChecksum(fileAt url: URL, expected: String) -> Bool` — computes the SHA-256 of the file with CryptoKit (Apple's built-in cryptography library) and compares it with `expected`, ignoring letter case.

**Behavioral notes:** The checks in `parse` keep a damaged or hand-edited file from steering the app. `version` has to agree with `build`, so the banner cannot show one version while the app compares another number. `asset` has to be the one fixed name, and `sha256` and `commit` have to have the exact length and character set of a real SHA-256 fingerprint and a real full commit hash. The comparison in `matchesChecksum` ignores letter case, so `expected` may be written in uppercase or lowercase. The app calls `parse` and `isNewer` for every check, and `matchesChecksum` once for each download.
