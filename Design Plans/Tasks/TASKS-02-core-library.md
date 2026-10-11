# Tasks: Package Scaffold and SiteBlockCore
> **Corresponds to:** [02-core-components.md](../02-core-components.md), [04-infrastructure.md](../04-infrastructure.md) § Package.swift

**Scope:** Create the Swift package and every file in `Sources/SiteBlockCore`. No executables beyond empty stubs, no tests (tests are written separately by the QA agent).

**Prerequisites:** macOS 14+, Swift 6.2 Command Line Tools. Project root is `~/Desktop/Work/Projects/SiteBlock`.

**Code conventions for every file:**
- Every type, method and function gets a short `///` comment above it saying what it does in plain English, not restating the signature. Comment non-obvious decisions inside methods too (why a branch order matters, why something fails safe).
- Single-line calls where possible.
- No third-party dependencies.

---

## Step 1: Package scaffold

**File:** `Package.swift`, plus empty-ish `main.swift` stubs in `Sources/siteblockd`, `Sources/siteblock`, `Sources/SiteBlockApp`, and one placeholder test file in each test target so the package builds.
**Reference:** [04-infrastructure.md](../04-infrastructure.md) § Package.swift, § Repository Layout
**Purpose:** A package that builds all four targets.

**Sub-steps:**
- 1a. `// swift-tools-version:5.10`, `platforms: [.macOS(.v14)]`, `swiftLanguageVersions: [.v5]`.
- 1b. Library target `SiteBlockCore` with `linkerSettings: [.linkedFramework("Security")]`.
- 1c. Executable targets `siteblockd`, `siteblock`, `SiteBlockApp`, each depending on `SiteBlockCore`.
- 1d. Test targets `SiteBlockCoreTests` (depends on `SiteBlockCore`) and `IntegrationTests` (depends on `SiteBlockCore`).
- 1e. `.gitignore` with `.build/`, `build/`, `.swiftpm/`, `*.xcodeproj`, `.DS_Store`.
- 1f. `scripts/test.sh` exactly as in [04-infrastructure.md](../04-infrastructure.md) § Package.swift (detect Xcode with `xcode-select -p`; when the path contains `CommandLineTools`, add the `-F`/rpath flags). `chmod +x`.

**Acceptance Criteria:**
- [ ] `swift build` succeeds.
- [ ] `scripts/test.sh` runs (with the placeholder tests passing).

---

## Step 2: Domain handling

**Files:** `Sources/SiteBlockCore/Punycode.swift`, `DomainNormalizer.swift`, `DomainExpander.swift`
**Reference:** [02-core-components.md](../02-core-components.md) § DomainNormalizer, § Punycode, § DomainExpander

**Sub-steps:**
- 2a. `enum Punycode` with `encode(_:)` and `toASCII(label:)` implementing RFC 3492 encoding (bias adaptation, generalized variable-length integers). Use `UInt32` arithmetic with overflow checks; return `nil` on overflow.
- 2b. `enum DomainError: Error, LocalizedError, Equatable` with the cases listed in the design and a sentence for each.
- 2c. `enum DomainNormalizer` with `static func normalize(_:) throws -> String`, following the eight steps in order. Steps 2–4 must work on strings without a scheme (`reddit.com/r/x?y#z`) and with one (`https://user:pw@Reddit.com:443/r`).
- 2d. `enum DomainExpander` with `commonPrefixes`, `relatedDomains` (exact table from the design; `x.com` and `twitter.com` share one list) and `expand(_:)`.

**Acceptance Criteria:**
- [ ] `normalize("https://WWW.Reddit.com:443/r/all?x=1#top") == "reddit.com"`
- [ ] `normalize("bücher.de") == "xn--bcher-kva.de"`
- [ ] `normalize("1.2.3.4")` throws `.ipAddress`; `normalize("localhost")` throws `.reserved`.
- [ ] `expand("example.org")` has exactly 9 entries.

---

## Step 3: Hosts file editor

**File:** `Sources/SiteBlockCore/HostsFileEditor.swift`
**Reference:** [02-core-components.md](../02-core-components.md) § HostsFileEditor

**Sub-steps:**
- 3a. `enum HostsFileEditor` with the two marker constants, `render`, `managedSection`, `isCompliant`.
- 3b. Implement the five render steps in order. Use a `Set<String>` of lowercased blocked hosts for step 3. For a non-comment line, split off any `#` comment first, split the rest on spaces/tabs, keep field 0 (the address), filter the names, and rebuild the line as `address + " " + names.joined(" ")` plus the original comment (if any, as ` #comment`). Leave lines untouched when no name was removed, so the user's formatting survives.
- 3c. Make sure `render(render(x, h), h) == render(x, h)` for every input.

**Acceptance Criteria:**
- [ ] Rendering the stock macOS hosts file with `["a.com"]` returns the stock file, an empty line, BEGIN, `0.0.0.0 a.com`, `:: a.com`, END.
- [ ] Rendering that output with `[]` returns the stock file.

---

## Step 4: Password hashing

**File:** `Sources/SiteBlockCore/PasswordHasher.swift`
**Reference:** [02-core-components.md](../02-core-components.md) § PasswordHasher

**Sub-steps:**
- 4a. `enum PasswordError: Error, LocalizedError` with `tooShort(minimum: Int)`, `whitespaceOnly`, `randomFailed`.
- 4b. `make`, `verify`, `validateNew` as designed. Use `CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), ...)` with `CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)`. Constant-time compare by OR-ing XORs of every byte.

**Acceptance Criteria:**
- [ ] `verify("hunter22", make("hunter22"))` is true and `verify("hunter23", ...)` is false.

---

## Step 5: Models, protocol, formatting, paths

**Files:** `Models.swift`, `Protocol.swift`, `Formatting.swift`, `Paths.swift`
**Reference:** [01-overview-and-data.md](../01-overview-and-data.md) § Data Model, § Wire Protocol; [02-core-components.md](../02-core-components.md) § Models and Protocol Types, § Formatting; [04-infrastructure.md](../04-infrastructure.md) § Installed Paths

**Sub-steps:**
- 5a. All model structs `Codable, Equatable, Sendable`. `PersistedState.fresh(delaySeconds:)` factory. `Countdown` with `init(seconds:)`, `advance(by:)`, `isFinished`, `displaySeconds`.
- 5b. `enum Command: String, Codable` and `enum ErrorCode: String, Codable` with exactly the names in the design. `Request` (`command` is the `Command` enum), `Response` with static helpers `success(status:message:)` and `failure(_ code:, _ message:)`, `StatusSnapshot`, `BlockedSiteStatus`, `PendingDelayStatus`.
- 5c. `enum JSONCoding` with a shared encoder (`.sortedKeys`) and decoder.
- 5d. `enum Formatting` with `duration`, `clock`, `parseDuration`.
- 5e. `struct Paths` with every path listed in the design as a `String` property, `static let production`, `static func sandbox(root:)`, and `let isSandbox: Bool`. Include `appBundle`, `cliPath`, `backupDaemon`, `daemonProgram`, `stateFile`, `stateDir`, `socket`, `hosts`, `logDir`, `daemonPlist`, `watchdogPlist`, `appAgentPlist`.
- 5f. `let siteBlockVersion = "1.0.0"`.

**Acceptance Criteria:**
- [ ] `Formatting.duration(3900) == "1 hour 5 minutes"`, `Formatting.clock(1781) == "29:41"`, `parseDuration("1h30m") == 5400`, `parseDuration("abc") == nil`.

---

## Step 6: Engine

**File:** `Sources/SiteBlockCore/Engine.swift`
**Reference:** [02-core-components.md](../02-core-components.md) § Engine

**Sub-steps:**
- 6a. `struct Policy: Sendable` with the fields from the design, `static let production` (1800, 60, 604800, 172800, 900, 5, 210000) and `static let fastForTests` (default delay 2, min delay 1, max 604800, recovery 3, lockout 2, attempts 5, iterations 1000).
- 6b. `final class Engine` with `state`, `policy`, `blockedHosts`, `onUninstall`, `handle(_:peerUID:)`, `tick(elapsed:)`, `snapshot(hostsFileHealthy:)`. Keep a private `lastHostsHealthy` that the runtime sets via `setHostsHealthy(_:)` so `handle` can include it in status.
- 6c. One private `checkPassword(_:) -> Response?` implementing the four-step rule; returns a failure response, or nil when the password is right.
- 6d. One private method per command; `handle` switches on the command and validates required arguments (missing → `badRequest`).
- 6e. Messages: use `Formatting.duration` in confirmation sentences, e.g. "reddit.com will unblock in 30 minutes. You can cancel any time before then."
- 6f. `tick` ignores `elapsed` that is negative, NaN or infinite (returns false, changes nothing).

**Acceptance Criteria:**
- [ ] Builds; the QA agent's tests drive it.

---

## Step 7: StateStore and DaemonClient

**Files:** `StateStore.swift`, `DaemonClient.swift`
**Reference:** [02-core-components.md](../02-core-components.md) § StateStore, § DaemonClient

**Sub-steps:**
- 7a. `StateStore` as designed. Use `FileManager` and `rename(2)` via `Foundation.rename` for the atomic replace; set permissions with `chmod` on the temp file before the rename.
- 7b. `DaemonClient` with POSIX socket calls (`socket`, `connect` with `sockaddr_un`, `write` loop, `read` loop). Set `SO_RCVTIMEO`/`SO_SNDTIMEO` from `timeout` and `SO_NOSIGPIPE`. Map `ENOENT`/`ECONNREFUSED` to `.notRunning`, `EAGAIN`/`EWOULDBLOCK` to `.timeout`. Reject a socket path of 104+ bytes with `.notRunning` and a clear message.
- 7c. `ClientError: LocalizedError` with sentences, e.g. "The SiteBlock service isn't running."

**Acceptance Criteria:**
- [ ] `swift build` succeeds with no warnings in `SiteBlockCore`.
