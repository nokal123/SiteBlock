# Core Components (SiteBlockCore library)
> Part of the SiteBlock Design Plans
> See also: [01-overview-and-data.md](01-overview-and-data.md), [03-daemon-cli-app.md](03-daemon-cli-app.md)

## Table of Contents
1. [Module Layout](#module-layout)
2. [DomainNormalizer](#1-domainnormalizer-sourcessiteblockcoredomainnormalizerswift)
3. [Punycode](#2-punycode-sourcessiteblockcorepunycodeswift)
4. [DomainExpander](#3-domainexpander-sourcessiteblockcoredomainexpanderswift)
5. [HostsFileEditor](#4-hostsfileeditor-sourcessiteblockcorehostsfileeditorswift)
6. [PasswordHasher](#5-passwordhasher-sourcessiteblockcorepasswordhasherswift)
7. [Models and Protocol Types](#6-models-and-protocol-types)
8. [Engine](#7-engine-sourcessiteblockcoreengineswift)
9. [StateStore](#8-statestore-sourcessiteblockcorestatestoreswift)
10. [DaemonClient](#9-daemonclient-sourcessiteblockcoredaemonclientswift)
11. [Formatting](#10-formatting-sourcessiteblockcoreformattingswift)
12. [ConnectionLimiter](#11-connectionlimiter-sourcessiteblockcoreconnectionlimiterswift)
13. [UninstallRule](#12-uninstallrule-sourcessiteblockcoreuninstallruleswift)

---

## Module Layout

`SiteBlockCore` is a Swift library with no dependency on root, launchd or the real file system paths. Every piece of policy logic lives here so it can be unit-tested. The daemon, CLI and app are thin layers on top.

The library has no third-party dependencies. It uses Foundation and, for hashing and random bytes, CommonCrypto and the Security framework, which ship with macOS.

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

**Files:** `Sources/SiteBlockCore/Models.swift`, `Sources/SiteBlockCore/Protocol.swift`

`Models.swift` holds the persisted types from [01-overview-and-data.md](01-overview-and-data.md) § Data Model: `PersistedState`, `BlockedSite`, `Countdown`, `PasswordHash`, `PendingDelayChange`. All are `Codable` and `Equatable` structs.

`Countdown` has:
- `init(seconds: Double)` — sets both `remainingSeconds` and `totalSeconds`.
- `mutating func advance(by elapsed: Double)` — subtracts, clamps at `0`, and ignores negative or non-finite input so a bad clock reading cannot add time or finish a countdown early. A remainder below `1e-9` seconds (one nanosecond) is set to exactly `0`. Without this, rounding error in floating-point subtraction would leave a countdown that ran 18,000 ticks of 0.1 seconds on a 1,800-second wait with a few billionths of a second left, so it would need one extra tick. A remainder of `1e-6` seconds is still running.
- `var isFinished: Bool` — `remainingSeconds <= 0`.
- `var displaySeconds: Int` — `remainingSeconds` rounded up, so a countdown never shows `0` while it is still running.

`Protocol.swift` holds `Request`, `Response`, `StatusSnapshot`, `BlockedSiteStatus`, `PendingDelayStatus`, the `Command` enum (raw `String` values matching the command names in [01-overview-and-data.md](01-overview-and-data.md) § Commands) and the `ErrorCode` enum. JSON uses the default `JSONEncoder` with `.sortedKeys`, field names exactly as written in the design.

---

### 7. Engine (`Sources/SiteBlockCore/Engine.swift`)

**Purpose:** The whole policy of SiteBlock in one class: it holds the state, applies commands, advances countdowns, and reports what the hosts file should contain. It does no I/O, so tests drive it directly with fake time.

**Properties:**
- `private(set) var state: PersistedState`
- `let policy: Policy` — the fixed values from [01-overview-and-data.md](01-overview-and-data.md) § Fixed Policy Values, as a struct so sandbox mode and tests can shrink them. Fields: `defaultDelaySeconds`, `minDelaySeconds`, `maxDelaySeconds`, `recoverySeconds`, `lockoutSeconds`, `maxFailedAttempts`, `pbkdf2Iterations`, `maxSites`, `minUninstallSeconds`. `Policy.production` must hold exactly 1800, 60, 604800, 172800, 900, 5, 210000, 500 and 172800 (the uninstall minimum). `Policy.fastForTests.minUninstallSeconds` is 2.
- `var blockedHosts: [String]` — every host of every blocked site, sorted, no duplicates. Sites with a pending unblock are still included, because they stay blocked until the countdown ends.
- `static let privateRelayHosts` — `["mask-h2.icloud.com", "mask.icloud.com"]`.
- `var adultFilterActive: Bool` — always `true`, except once `uninstalling` is `true` (the uninstaller then restores everything).
- `static let dohBypassHosts` — `["doh.xfinity.com", "firefox.dns.nextdns.io", "mozilla.cloudflare-dns.com", "private.canadianshield.cira.ca"]`, the hostnames browsers use for DNS-over-HTTPS by default.
- `var hostsToWrite: [String]` — what the runtime writes into the hosts file: `blockedHosts` plus `privateRelayHosts` and `dohBypassHosts` whenever `adultFilterActive` is true (so, in practice, always), sorted and without duplicates. See [01-overview-and-data.md](01-overview-and-data.md) § How Blocking Works for why.
- `var onUninstall: (() -> Void)?` — called once when the uninstall countdown finishes.

**Key Methods:**
- `init(state: PersistedState, policy: Policy)`
- `func handle(_ request: Request, peerUID: uid_t) -> Response` — runs one command and always returns a response; it never throws. Every successful response carries `status`.
- `func tick(elapsed: Double) -> Bool` — advances every countdown by `elapsed` seconds and applies the ones that finished. Returns `true` when the state changed in a way that must be saved now (a countdown finished).
- `func snapshot(hostsFileHealthy: Bool) -> StatusSnapshot`

**Password check rule** (shared by every command that takes a password):
1. If `lockout` is running, fail with `lockedOut` and say how many minutes are left. The password is not checked at all.
2. If no password is set, fail with `notSetUp`.
3. If the password is wrong, add 1 to `failedAttempts`. When it reaches `maxFailedAttempts`, start `lockout` and reset `failedAttempts` to 0. Fail with `wrongPassword` and say how many tries are left.
4. If the password is right, reset `failedAttempts` to 0 and continue.

**Who may set up:** `var consoleUID: () -> uid_t?` returns the user ID of the person logged in at the screen. The runtime sets it in production to read the owner of `/dev/console`. It defaults to returning `nil`, and `nil` means any caller may run `setup`, which is what sandbox runs and tests use. When it returns an ID, `setup` succeeds only for `peerUID == 0` or `peerUID` equal to that ID, and fails with `notAllowed` otherwise. The check comes before `alreadySetUp`.

**Site cap:** adding a new site when `policy.maxSites` sites are already blocked fails with `tooManySites`. Re-adding an existing site (to cancel its unblock) is not affected. `Policy.production.maxSites` is 500; `Policy.fastForTests.maxSites` is 20, so tests can reach the cap quickly.

**Path rules:**
- `addPath`: parse the rule text with `PathRuleParser.parse` (`invalidDomain` for host errors, `invalidPath` for path errors and for text with no path). If the whole domain is already in `blocked`, fail `alreadyBlocked` ("youtube.com is already fully blocked"). If the same domain and path exist with a pending unblock, clear the unblock; if they exist without one, fail `alreadyBlocked`. Otherwise, like `add`: `notSetUp` without a password, `tooManySites` when `blocked.count + blockedPaths.count` would exceed `maxSites`, then append.
- `unblockPath` and `cancelUnblockPath` follow `unblock` and `cancelUnblock` exactly, keyed by domain and path.
- Tick: remove path rules whose unblock finished (a change that must be saved).
- Adding the whole domain later keeps its path rules (they become redundant while the whole site is blocked, and matter again if the whole site is unblocked).

**Browser block list:** `var browserBlockEntries: (chrome: [String], firefox: [String])` builds both browsers' lists. Chrome: `ChromePolicy.urlBlocklist(for: blocked)` (the covering host list) plus `chromeEntry` for every path rule whose domain is not covered by a whole-site block, sorted. Firefox: `*://*.<host>/*` for every covering host plus `firefoxPattern` for the same path rules, sorted.

**Argument rule:** a missing required argument fails with `badRequest` before any lockout or password check, so a malformed request never costs a password attempt. `setDelay` also checks the range (`invalidDelay`) before the password.

**Command rules:**
- `add`: normalize (fail `invalidDomain` with the normalizer's sentence). If already blocked with a pending unblock, clear the pending unblock and say "Unblock cancelled; reddit.com stays blocked." This works even when no password is set, because after a finished recovery `add` is the only way to stop an unblock that was already counting down. If already blocked without one, fail `alreadyBlocked`. Only a new site needs a password to exist (`notSetUp`). Otherwise append a `BlockedSite` with its expanded hosts.
- `unblock`: normalize, find the site (fail `notBlocked`), check the password, then set `pendingUnblock = Countdown(seconds: delaySeconds)`. If one is already pending, keep the existing countdown (do not restart it) and report its remaining time.
- `setDelay`: validate the range (fail `invalidDelay`), check the password. A value greater than or equal to the current delay applies at once and clears `pendingDelayChange`. A smaller value replaces any existing `pendingDelayChange` with a new one whose countdown starts again at the current delay.
- `changePassword`: check the old password, validate the new one (`weakPassword`), store a new hash.
- `uninstall`: check the password, start `pendingUninstall` at `uninstallWaitSeconds` (the larger of `policy.minUninstallSeconds` and `delaySeconds`) unless one is already running.
- `recoveryStart`: fail `notRoot` unless `peerUID == 0`. Fail `notSetUp` if no password is set. Start `recovery` at `recoverySeconds` unless already running.
- Cancel commands clear their countdown, or fail `nothingPending` when there is none. `cancelUninstall` also fails `nothingPending` once the uninstall countdown has finished and `uninstalling` is `true`, because removal has already begun.

**Lockout wording:** the lockout message gives the remaining time in whole minutes rounded up, so 59.5 seconds left reads "1 minute" and the message never says "0 minutes". Under one minute left it may use seconds instead. The wrong-password message says "1 try left" in the singular.

**Finished-but-uncleared lockout:** a lockout whose countdown reached 0 but which the next tick has not cleared yet does not block a password check. The check clears it and proceeds.

**Hosts health:** `setHostsHealthy(_ healthy: Bool)` records the result of the runtime's last enforcement pass, and every snapshot built by `handle` reports it as `hostsFileHealthy`. It starts as `true`.

**Tick rule:** advance every countdown by `elapsed`. Then in this order: remove sites whose unblock finished; apply a finished delay change; clear a finished lockout; for a finished recovery, set `passwordHash = nil`, `failedAttempts = 0`, `lockout = nil` and clear `recovery`; for a finished uninstall, set `uninstalling = true` and call `onUninstall`.

---

### 8. StateStore (`Sources/SiteBlockCore/StateStore.swift`)

**Purpose:** Reads and writes `state.json` and its backup copy safely.

**Key Methods:**
- `init(url: URL, backupURL: URL? = nil)` — the daemon passes `Paths.stateBackup` as the backup.
- `func load() -> PersistedState?` — returns the primary file's state when it decodes. When the primary exists but cannot be decoded, it renames it to `state.json.corrupt-<unix time>`. When the primary is missing or corrupt, it returns the backup's state if that decodes, otherwise `nil`, so the daemon starts fresh instead of crashing in a restart loop.
- `func save(_ state: PersistedState) throws` — encodes with sorted keys and writes the primary and then the backup. Each write goes to a temp file in the same folder with mode `0600` and is then renamed over the target. The rename is atomic (the file is either the old version or the new version, never half-written).
- `func matchesLastSave() -> Bool` — `false` when either file is missing or its bytes differ from what this store last wrote or loaded. A store that has neither saved nor loaded returns `true`. The daemon uses it to undo hand edits.

**Failure and naming details:** `save` throws when either the primary or the backup write fails, so the daemon knows to retry. When a corrupt file is renamed and `state.json.corrupt-<unix time>` already exists (two corrupt loads in the same second), a counter suffix keeps both files, as in `state.json.corrupt-<unix time>-1`. The `version` field is decoded but not checked. A file that is valid JSON but lacks any required field (for example `{}` or `{"version":1}`) does not decode, so it is treated as corrupt.

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

