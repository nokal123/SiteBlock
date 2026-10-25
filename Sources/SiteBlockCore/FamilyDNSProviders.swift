import Foundation

/// One family DNS service: a DNS service that refuses to look up adult sites, with the two IPv4 and two IPv6 addresses SiteBlock sets on every managed network service.
public struct FamilyDNSProvider: Codable, Equatable, Sendable {
    /// A short fixed name, such as "cleanbrowsing-family", that the file's `active` line refers to.
    public let id: String
    /// The name people know the service by, such as "CleanBrowsing Family Filter".
    public let name: String
    /// The two IPv4 addresses, in their standard form.
    public let ipv4: [String]
    /// The two IPv6 addresses, in their standard short form.
    public let ipv6: [String]

    /// The four servers in the order SiteBlock writes them: the IPv4 addresses, then the IPv6 ones.
    public var servers: [String] { ipv4 + ipv6 }
}

/// Why the providers file could not be used.
public struct FamilyDNSProvidersError: Error, Equatable, CustomStringConvertible {
    /// One sentence that names the problem.
    public let description: String
}

/// The family DNS services SiteBlock knows, and the one it uses, read from `FamilyDNSProviders.json`. That file is built into this library (and into the Windows
/// build from the same file), so switching to another service means changing its `active` line and releasing an update; nothing on the installed computer can change it,
/// which keeps the promise that no setting turns the adult content filter off.
public struct FamilyDNSProviders: Codable, Equatable, Sendable {
    /// The `id` of the provider in use.
    public let active: String
    /// Every known provider. The DNS enforcer treats any of their server lists as family servers, so a service still on the previous provider after a switch is recognised.
    public let providers: [FamilyDNSProvider]

    /// The list built into this copy of SiteBlock, or nil when the built-in file cannot be read or breaks a rule of `parse` (the tests make sure it never ships that way).
    public static let builtIn: FamilyDNSProviders? = try? parse(Data(PackageResources.FamilyDNSProviders_json))

    /// The provider in use. `parse` has checked that `active` names one of the providers, so this always finds it.
    public var activeProvider: FamilyDNSProvider { providers.first { $0.id == active }! }

    /// True when the servers are exactly one provider's four servers in SiteBlock's order, which means SiteBlock set them.
    public func isFamilyList(_ servers: [String]) -> Bool {
        providers.contains { $0.servers == servers }
    }

    /// Reads the providers file and checks its rules: ids are not empty and not repeated, `active` names a provider, and every provider has exactly two IPv4 and two
    /// IPv6 addresses, each valid and written in its standard short form (the form the operating system reads back, so a write can be compared with what is read).
    /// Throws `FamilyDNSProvidersError` naming the first rule that is broken, or the JSON error when the text is not the expected JSON.
    public static func parse(_ data: Data) throws -> FamilyDNSProviders {
        let list = try JSONDecoder().decode(FamilyDNSProviders.self, from: data)
        var seen = Set<String>()
        for provider in list.providers {
            if provider.id.isEmpty { throw FamilyDNSProvidersError(description: "a provider has no id") }
            if !seen.insert(provider.id).inserted { throw FamilyDNSProvidersError(description: "the provider id \(provider.id) appears twice") }
            if provider.ipv4.count != 2 || provider.ipv6.count != 2 { throw FamilyDNSProvidersError(description: "\(provider.id) must have two IPv4 and two IPv6 addresses") }
            for address in provider.ipv4 where standardForm(address, family: AF_INET) != address {
                throw FamilyDNSProvidersError(description: "\(provider.id) has an IPv4 address that is not valid or not in standard form: \(address)")
            }
            for address in provider.ipv6 where standardForm(address, family: AF_INET6) != address {
                throw FamilyDNSProvidersError(description: "\(provider.id) has an IPv6 address that is not valid or not in standard short form: \(address)")
            }
        }
        if !seen.contains(list.active) { throw FamilyDNSProvidersError(description: "the active provider \(list.active) is not in the list") }
        return list
    }

    /// The address rewritten in the standard form the system prints (for IPv6, lowercase with the longest run of zeros shortened to "::"), or nil when it is not a valid address of that family.
    private static func standardForm(_ address: String, family: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 16)
        guard inet_pton(family, address, &buffer) == 1 else { return nil }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(family, buffer, &text, socklen_t(text.count)) != nil else { return nil }
        return String(cString: text)
    }
}
