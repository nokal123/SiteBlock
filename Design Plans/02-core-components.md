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

---

## Module Layout

`SiteBlockCore` is a Swift library with no dependency on root, launchd or the real file system paths. Every piece of policy logic lives here so it can be unit-tested. The daemon, CLI and app are thin layers on top.

The library has no third-party dependencies. It uses Foundation and, for hashing and random bytes, CommonCrypto and the Security framework, which ship with macOS.

---

### 1. DomainNormalizer (`Sources/SiteBlockCore/DomainNormalizer.swift`)

**Purpose:** Turns whatever the user typed (a bare name, a full URL, a name with a port or path) into one canonical lowercase base domain, or explains why it cannot be blocked.

**Key Methods:**
- `static func normalize(_ input: String) throws -> String` — returns the base domain, or throws `DomainError`.

**Steps, in order:**
1. Trim surrounding whitespace and newlines. Empty input throws `.empty`.
2. If the input contains `://`, take everything after it. Then cut the string at the first `/`, `?` or `#`.
3. Drop any `user:pass@` prefix (everything up to and including the last `@`).
4. Drop a `:port` suffix. Input that starts with `[` is an IPv6 literal and throws `.ipAddress`.
5. Lowercase. Remove one trailing `.`.
6. Convert each label (the parts between dots) that contains non-ASCII characters to its `xn--` Punycode form, so `bücher.de` becomes `xn--bcher-kva.de`. See § Punycode.
7. Strip one leading `www.` so that `www.reddit.com` and `reddit.com` are stored as the same site. The expander adds `www.` back.
8. Validate:
   - total length 1–253 characters,
   - at least two labels,
   - each label 1–63 characters, only `a–z`, `0–9` and `-`, not starting or ending with `-`,
   - the last label (the top-level domain) is not all digits, which rejects IPv4 addresses such as `1.2.3.4` with `.ipAddress`,
   - the name is not `localhost` and does not end in `.local` or `.localhost` (`.reserved`), because blocking those would break the Mac itself.

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

### 4. HostsFileEditor (`Sources/SiteBlockCore/HostsFileEditor.swift`)

**Purpose:** Takes the current text of a hosts file and the set of host names that must be blocked, and returns the corrected text. It is a pure function over strings, with no file access, so it can be tested on any input.

**Constants:**
- `beginMarker = "# BEGIN SiteBlock — managed by siteblockd; edits inside this block are reverted"`
- `endMarker = "# END SiteBlock"`

A line counts as a marker when its trimmed text starts with `# BEGIN SiteBlock` or equals `# END SiteBlock`. This tolerates trailing spaces and a hand-edited comment after the BEGIN text.

**Key Methods:**
- `static func render(original: String, blockedHosts: [String]) -> String` — returns the corrected file text.
- `static func managedSection(for blockedHosts: [String]) -> String` — returns the BEGIN line, then for each host in sorted order the two lines `0.0.0.0 <host>` and `:: <host>`, then the END line.
- `static func isCompliant(_ text: String, blockedHosts: [String]) -> Bool` — `true` when `render(original: text, ...) == text`.

**Render steps:**
1. Split the original into lines (accept `\n` and `\r\n`, write `\n`).
2. Remove every managed section. A section starts at a BEGIN line and ends at the next END line. A BEGIN line with no END after it removes only the BEGIN line itself, because deleting to the end of the file could destroy the user's own entries. A stray END line with no BEGIN is removed.
3. In every remaining line that is not a comment, look at the host names after the address (fields are separated by spaces or tabs, and anything after `#` is a comment). Remove any name that equals, ignoring case, a blocked host. If the line has no names left, drop the line. This stops a hand-added line such as `151.101.1.140 reddit.com`, which macOS would otherwise use because it reads the first match.
4. Remove trailing empty lines, then add one `\n` if the text is not empty.
5. If `blockedHosts` is not empty, append one empty line and the managed section, ending with `\n`.

**Behavioral notes:** Running `render` on its own output returns the same text (it is idempotent), which is what lets the daemon compare and only rewrite when something changed. With an empty block list, `render` removes the section and leaves the user's own lines.

---

### 5. PasswordHasher (`Sources/SiteBlockCore/PasswordHasher.swift`)

**Purpose:** Creates and checks `PasswordHash` values.

**Key Methods:**
- `static func make(password: String, iterations: Int = 210_000) throws -> PasswordHash` — fills a 16-byte salt from `SecRandomCopyBytes` (the system's secure random number generator) and derives 32 bytes with `CCKeyDerivationPBKDF` using `kCCPRFHmacAlgSHA256`.
- `static func verify(password: String, against: PasswordHash) -> Bool` — derives the full 32 bytes again with the stored salt and iteration count and compares in constant time. A stored hash that is not exactly 32 bytes never matches (every byte is compared even after a mismatch, so timing does not reveal how many bytes matched). Returns `false` for an unknown algorithm or bad Base64.
- `static func validateNew(_ password: String) throws` — throws `PasswordError.tooShort` when the password has fewer than 6 characters, and `.whitespaceOnly` when it is only spaces.

**Behavioral notes:** Passwords are hashed as their UTF-8 bytes with no Unicode normalization. Leading and trailing spaces are kept as part of the password.

---

### 6. Models and Protocol Types

**Files:** `Sources/SiteBlockCore/Models.swift`, `Sources/SiteBlockCore/Protocol.swift`

`Models.swift` holds the persisted types from [01-overview-and-data.md](01-overview-and-data.md) § Data Model: `PersistedState`, `BlockedSite`, `Countdown`, `PasswordHash`, `PendingDelayChange`. All are `Codable` and `Equatable` structs.

`Countdown` has:
- `init(seconds: Double)` — sets both `remainingSeconds` and `totalSeconds`.
- `mutating func advance(by elapsed: Double)` — subtracts, clamps at `0`, and ignores negative or non-finite input so a bad clock reading cannot add time or finish a countdown early.
- `var isFinished: Bool` — `remainingSeconds <= 0`.
- `var displaySeconds: Int` — `remainingSeconds` rounded up, so a countdown never shows `0` while it is still running.

`Protocol.swift` holds `Request`, `Response`, `StatusSnapshot`, `BlockedSiteStatus`, `PendingDelayStatus`, the `Command` enum (raw `String` values matching the command names in [01-overview-and-data.md](01-overview-and-data.md) § Commands) and the `ErrorCode` enum. JSON uses the default `JSONEncoder` with `.sortedKeys`, field names exactly as written in the design.

---

### 7. Engine (`Sources/SiteBlockCore/Engine.swift`)

**Purpose:** The whole policy of SiteBlock in one class: it holds the state, applies commands, advances countdowns, and reports what the hosts file should contain. It does no I/O, so tests drive it directly with fake time.

**Properties:**
- `private(set) var state: PersistedState`
- `let policy: Policy` — the fixed values from [01-overview-and-data.md](01-overview-and-data.md) § Fixed Policy Values, as a struct so sandbox mode and tests can shrink them. Fields: `defaultDelaySeconds`, `minDelaySeconds`, `maxDelaySeconds`, `recoverySeconds`, `lockoutSeconds`, `maxFailedAttempts`, `pbkdf2Iterations`.
- `var blockedHosts: [String]` — every host of every blocked site, sorted, no duplicates. Sites with a pending unblock are still included, because they stay blocked until the countdown ends.
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

**Command rules:**
- `add`: normalize (fail `invalidDomain` with the normalizer's sentence). If already blocked with a pending unblock, clear the pending unblock and say "Unblock cancelled; reddit.com stays blocked." If already blocked without one, fail `alreadyBlocked`. Otherwise append a `BlockedSite` with its expanded hosts.
- `unblock`: normalize, find the site (fail `notBlocked`), check the password, then set `pendingUnblock = Countdown(seconds: delaySeconds)`. If one is already pending, keep the existing countdown (do not restart it) and report its remaining time.
- `setDelay`: validate the range (fail `invalidDelay`), check the password. A value greater than or equal to the current delay applies at once and clears `pendingDelayChange`. A smaller value sets `pendingDelayChange` with a countdown equal to the current delay.
- `changePassword`: check the old password, validate the new one (`weakPassword`), store a new hash.
- `uninstall`: check the password, start `pendingUninstall` at `delaySeconds` unless one is already running.
- `recoveryStart`: fail `notRoot` unless `peerUID == 0`. Fail `notSetUp` if no password is set. Start `recovery` at `recoverySeconds` unless already running.
- Cancel commands clear their countdown, or fail `nothingPending` when there is none.

**Tick rule:** advance every countdown by `elapsed`. Then in this order: remove sites whose unblock finished; apply a finished delay change; clear a finished lockout; for a finished recovery, set `passwordHash = nil`, `failedAttempts = 0`, `lockout = nil` and clear `recovery`; for a finished uninstall, set `uninstalling = true` and call `onUninstall`.

---

### 8. StateStore (`Sources/SiteBlockCore/StateStore.swift`)

**Purpose:** Reads and writes `state.json` and its backup copy safely.

**Key Methods:**
- `init(url: URL, backupURL: URL? = nil)` — the daemon passes `Paths.stateBackup` as the backup.
- `func load() -> PersistedState?` — returns the primary file's state when it decodes. When the primary exists but cannot be decoded, it renames it to `state.json.corrupt-<unix time>`. When the primary is missing or corrupt, it returns the backup's state if that decodes, otherwise `nil`, so the daemon starts fresh instead of crashing in a restart loop.
- `func save(_ state: PersistedState) throws` — encodes with sorted keys and writes the primary and then the backup. Each write goes to a temp file in the same folder with mode `0600` and is then renamed over the target. The rename is atomic (the file is either the old version or the new version, never half-written).
- `func matchesLastSave() -> Bool` — `false` when either file is missing or its bytes differ from what this store last wrote. The daemon uses it to undo hand edits.

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
- `static func parseDuration(_ text: String) -> Int?` — accepts `90`, `90s`, `15m`, `2h`, `1d`, and combinations such as `1h30m`. Plain numbers are seconds. Returns `nil` for anything else.
