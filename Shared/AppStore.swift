// Compiled into every app target. MeowDisplay's App Store identity and where
// an out-of-date receiver is sent to update, centralized so the iOS app's
// update screen AND the Mac's `updateRequired` message use the same link.
//
// There is deliberately no listing yet: the ID this file used to carry was
// upstream OpenDisplay's, and no MeowDisplay build may send anyone to another
// app's listing. Until `iOSAppID` is set, every update link resolves to the
// project page instead.

import Foundation

enum AppStore {
    /// MeowDisplay's own iOS App Store listing ID (the digits after `id` in
    /// `apps.apple.com/app/id…`), or nil while it has none. The one place to
    /// configure: set it once App Store Connect assigns the app its Apple ID,
    /// and every URL below follows.
    static let iOSAppID: String? = nil

    /// The project page: how to get and update every MeowDisplay app, and
    /// where an update link points while there is no App Store listing.
    static let projectURL = URL(string: "https://github.com/raiseCatError/MeowDisplay")!

    /// Opens the App Store app directly on the listing (with an Update
    /// button). Nil while there is no listing.
    static var updateURL: URL? { listingURL(appID: iOSAppID, scheme: "itms-apps") }
    /// Web fallback for anywhere the itms-apps scheme can't be handled. Nil
    /// while there is no listing.
    static var webURL: URL? { listingURL(appID: iOSAppID, scheme: "https") }

    /// Where an out-of-date iOS receiver is sent: the listing when there is
    /// one, otherwise the project page. Never nil, so the Mac always puts a
    /// `store` in `updateRequired` — an older receiver that finds none falls
    /// back to the upstream listing it was built with.
    static var receiverUpdateURL: URL { updateDestination(appID: iOSAppID) }

    /// The link to open for one offered from elsewhere: the Mac's
    /// `updateRequired.store`, or the version manifest's `storeURL`. An App
    /// Store link is kept only when it is this app's own listing (an older
    /// MeowDisplay Mac sends upstream's), any other link only when it is
    /// `https`. Anything else, or nothing, becomes `receiverUpdateURL`.
    static func resolveReceiverUpdateURL(_ offered: String?) -> URL {
        resolveReceiverUpdateURL(offered, appID: iOSAppID)
    }

    /// Whether `url` leads into the App Store at all, by scheme or by host.
    static func isAppStoreLink(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        return scheme.hasPrefix("itms")
            || ["apps.apple.com", "itunes.apple.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: - Pure forms (the listing ID is a parameter, so both states are testable)

    static func listingURL(appID: String?, scheme: String) -> URL? {
        guard let appID, isListingID(appID) else { return nil }
        return URL(string: "\(scheme)://apps.apple.com/app/id\(appID)")
    }

    static func updateDestination(appID: String?) -> URL {
        listingURL(appID: appID, scheme: "itms-apps") ?? projectURL
    }

    static func resolveReceiverUpdateURL(_ offered: String?, appID: String?) -> URL {
        let fallback = updateDestination(appID: appID)
        guard let offered, let url = URL(string: offered) else { return fallback }
        if isAppStoreLink(url) {
            guard let appID, isListingID(appID), listingID(in: url) == appID else { return fallback }
            return url
        }
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return fallback }
        return url
    }

    /// The listing ID in an App Store link (`…/id123…`), or nil.
    static func listingID(in url: URL) -> String? {
        url.pathComponents
            .first { $0.hasPrefix("id") && isListingID(String($0.dropFirst(2))) }
            .map { String($0.dropFirst(2)) }
    }

    private static func isListingID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
