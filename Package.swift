// swift-tools-version:5.10
import PackageDescription

// SiteBlock: a shared policy library plus three programs (daemon, CLI, menu bar app) built on top of it.
let package = Package(
    name: "SiteBlock",
    platforms: [.macOS(.v14)],
    targets: [
        // All policy logic lives here so it can be unit-tested without root access.
        // FamilyDNSProviders.json (the family DNS services and the active one) is built into the library as bytes, so the installed programs need no file beside them.
        .target(name: "SiteBlockCore", resources: [.embedInCode("FamilyDNSProviders.json")], linkerSettings: [.linkedFramework("Security")]),
        // siteblockd links SystemConfiguration so the adult content filter can read and set the Mac's DNS servers in-process.
        .executableTarget(name: "siteblockd", dependencies: ["SiteBlockCore"], linkerSettings: [.linkedFramework("SystemConfiguration")]),
        .executableTarget(name: "siteblock", dependencies: ["SiteBlockCore"]),
        .executableTarget(name: "SiteBlockApp", dependencies: ["SiteBlockCore"]),
        .testTarget(name: "SiteBlockCoreTests", dependencies: ["SiteBlockCore"]),
        .testTarget(name: "IntegrationTests", dependencies: ["SiteBlockCore"]),
    ],
    // Swift 5 language mode so the strict Swift 6 concurrency checks do not block the C socket code.
    swiftLanguageVersions: [.v5]
)
