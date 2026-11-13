import Foundation

/// The covers over a session (#255): "Mac is asleep" and "Mac is locked". A session admitted while
/// the Mac sleeps or is locked has had no picture yet, so it has no surface and the route is still
/// idle. Its cover is owed all the same, with the same ways out as a live session's: Settings,
/// Back to Home (the session kept behind Home, Resume brings the cover back) and Disconnect.
enum SessionCoverPolicy {
    /// Whether the session is what the person is looking at, so a cover belongs over it: the
    /// session's surface is shown, or the session is connected before its first picture and is
    /// neither kept behind Home nor behind the demo.
    static func sessionOnScreen(surfaceShown: Bool, connected: Bool, keptOnHome: Bool, demoShown: Bool) -> Bool {
        surfaceShown || (connected && !keptOnHome && !demoShown)
    }

    /// Back to Home on a cover: a connected session under that cover, not already kept.
    static func homeAvailable(connected: Bool, sessionOnScreen: Bool,
                              presentation: ReceiverSessionPresentation) -> Bool {
        connected && sessionOnScreen && presentation == .session
    }

    /// What `ReceiverSessionPresentation.showHome` counts as a retained surface. Without a cover a
    /// session needs its picture (there is nothing to come back to otherwise); from a cover the
    /// cover itself is what Resume comes back to.
    static func surfaceRetainedForHome(retainsSurface: Bool, hasPicture: Bool, fromCover: Bool) -> Bool {
        retainsSurface && (hasPicture || fromCover)
    }
}
