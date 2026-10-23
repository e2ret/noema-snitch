import Foundation
import Security

/// Stable identity of a program from its code signature, so a rule keeps working
/// after the app updates and moves to a new path (Claude Code, browsers, …).
public enum CodeIdentity {
    private static let lock = NSLock()
    private static var cache: [String: (modified: Date?, identity: String?)] = [:]

    /// "TEAMID:bundle.id" for developer-signed code, "apple:id" for Apple's own binaries,
    /// nil for unsigned, ad-hoc or invalidly signed code (those fall back to the path).
    public static func of(_ path: String) -> String? {
        guard !path.isEmpty, path != "*" else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        lock.lock()
        if let hit = cache[path], hit.modified == modified {
            lock.unlock()
            return hit.identity
        }
        lock.unlock()

        let identity = compute(path)
        lock.lock()
        cache[path] = (modified, identity)
        lock.unlock()
        return identity
    }

    private static func compute(_ path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        // The signature must be intact, otherwise anyone could claim an identifier.
        let checkFlags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        guard SecStaticCodeCheckValidity(code, checkFlags, nil) == errSecSuccess else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let identifier = dict[kSecCodeInfoIdentifier as String] as? String else { return nil }

        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return "\(team):\(identifier)"
        }
        // Apple platform binaries have no team ID; accept them only when anchored to Apple.
        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
           let requirement,
           SecStaticCodeCheckValidity(code, checkFlags, requirement) == errSecSuccess {
            return "apple:\(identifier)"
        }
        return nil  // ad-hoc: no verifiable identity
    }
}
