// Compiled into every app target. MeowDisplay's external project and support
// links, in one place so every About screen and update fallback agree.

import Foundation

enum ProjectLinks {
    /// The source repository and project page: how to get, update and
    /// report issues for every MeowDisplay app.
    static let gitHub = URL(string: "https://github.com/raiseCatError/meowdisplay")!

    /// The Ko-fi page (e.g. "https://ko-fi.com/<name>"), or nil while there
    /// is none. The one place to configure: set it once the page exists, and
    /// every "Support MeowDisplay" action appears. Until then those actions
    /// are hidden — never a placeholder that leads nowhere.
    static let koFiPage: String? = nil

    /// The support link to show, or nil to show none.
    static var support: URL? { supportURL(from: koFiPage) }

    /// Only a real `https://ko-fi.com/<page>` link is ever offered — matched
    /// on the raw text, since newer Foundation percent-encodes what
    /// `URL(string:)` would otherwise reject.
    static func supportURL(from page: String?) -> URL? {
        guard let page,
              page.range(of: #"^https://(www\.)?ko-fi\.com/[A-Za-z0-9_-]+/?$"#,
                         options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return URL(string: page)
    }
}
