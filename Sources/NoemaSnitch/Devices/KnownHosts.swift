import Foundation

/// Names for well-known hosts, used when a request carries no app in its
/// User-Agent (iOS system services usually don't). These are guesses by address.
enum KnownHosts {
    /// (host suffix, localization key). First match wins, so specific entries come first.
    private static let table: [(String, String)] = [
        ("gs-loc.apple.com", "known.location"),
        ("ls.apple.com", "known.location"),
        ("push.apple.com", "known.push"),
        ("captive.apple.com", "known.captive"),
        ("inappcheck.itunes.apple.com", "known.appstore"),
        ("itunes.apple.com", "known.appstore"),
        ("apps.apple.com", "known.appstore"),
        ("mzstatic.com", "known.appstore"),
        ("mesu.apple.com", "known.updates"),
        ("swcdn.apple.com", "known.updates"),
        ("updates.cdn-apple.com", "known.updates"),
        ("gdmf.apple.com", "known.updates"),
        ("smoot.apple.com", "known.siri"),
        ("siri.apple.com", "known.siri"),
        ("icloud.com", "known.icloud"),
        ("icloud-content.com", "known.icloud"),
        ("apple-cloudkit.com", "known.icloud"),
        ("ess.apple.com", "known.appleid"),
        ("idmsa.apple.com", "known.appleid"),
        ("appleid.apple.com", "known.appleid"),
        ("weather.apple.com", "known.weather"),
        ("weatherkit.apple.com", "known.weather"),
        ("cdn-apple.com", "known.applecdn"),
        ("aaplimg.com", "known.applecdn"),
        ("apple.com", "known.apple"),
        ("app-measurement.com", "known.firebase"),
        ("firebaseinstallations.googleapis.com", "known.firebase"),
        ("firebaselogging.googleapis.com", "known.firebase"),
        ("crashlytics.com", "known.crashlytics"),
        ("appsflyer.com", "known.appsflyer"),
        ("appsflyersdk.com", "known.appsflyer"),
        ("adjust.com", "known.adjust"),
        ("doubleclick.net", "known.googleads"),
        ("googlesyndication.com", "known.googleads"),
        ("googleadservices.com", "known.googleads"),
        ("graph.facebook.com", "known.facebook"),
        ("sentry.io", "known.sentry"),
        ("amplitude.com", "known.amplitude"),
        ("mixpanel.com", "known.mixpanel"),
    ]

    static func label(for host: String) -> String? {
        let host = host.lowercased()
        for (suffix, key) in table where host == suffix || host.hasSuffix("." + suffix) {
            return String(localized: String.LocalizationValue(key))
        }
        return nil
    }
}

extension DeviceFlow {
    /// What to show in the "App" column: the app from the User-Agent, else a guess by host.
    var displayApp: (name: String, isGuess: Bool)? {
        if let app { return (app, false) }
        if let label = KnownHosts.label(for: host) { return (label, true) }
        return nil
    }

    /// Grouping key for the "by app" view.
    var appGroup: String {
        displayApp?.name ?? String(localized: "devices.unknownApp")
    }
}
