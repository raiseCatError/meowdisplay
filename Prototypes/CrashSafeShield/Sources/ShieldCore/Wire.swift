import Foundation

/// Messages from the main app to the keeper, one JSON object per line. There is deliberately no
/// message that removes the cover: only this Mac's own input plus the login password does that,
/// inside the keeper.
public enum WireMessage: Equatable {
    case cover(session: String)
    case sessionEnded(session: String)
    /// Sent just before a normal Quit, with the nonce the keeper gave in its hello.
    case cleanQuit(nonce: String)
    /// Test builds only: block the keeper's main thread to exercise the watchdog.
    case testHang(seconds: Double)
    /// Anything else, including any attempt to "uncover". Logged and ignored.
    case rejected(String)

    public static func parse(_ line: String) -> WireMessage {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = object["cmd"] as? String else { return .rejected(String(line.prefix(80))) }
        switch cmd {
        case "cover":
            guard let s = object["session"] as? String, !s.isEmpty else { return .rejected(cmd) }
            return .cover(session: s)
        case "sessionEnded":
            guard let s = object["session"] as? String, !s.isEmpty else { return .rejected(cmd) }
            return .sessionEnded(session: s)
        case "cleanQuit":
            guard let n = object["nonce"] as? String else { return .rejected(cmd) }
            return .cleanQuit(nonce: n)
        case "testHang":
            return .testHang(seconds: object["seconds"] as? Double ?? 5)
        default:
            return .rejected(cmd)
        }
    }

    public var line: String {
        let object: [String: Any]
        switch self {
        case .cover(let s): object = ["cmd": "cover", "session": s]
        case .sessionEnded(let s): object = ["cmd": "sessionEnded", "session": s]
        case .cleanQuit(let n): object = ["cmd": "cleanQuit", "nonce": n]
        case .testHang(let s): object = ["cmd": "testHang", "seconds": s]
        case .rejected(let c): object = ["cmd": c]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }
}

/// The keeper's first line to the app: `{"hello":"keeper","nonce":"…"}`.
public struct KeeperHello: Equatable {
    public let nonce: String
    public init(nonce: String) { self.nonce = nonce }
    public var line: String { "{\"hello\":\"keeper\",\"nonce\":\"\(nonce)\"}\n" }
    public static func parse(_ line: String) -> KeeperHello? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["hello"] as? String == "keeper", let n = object["nonce"] as? String else { return nil }
        return KeeperHello(nonce: n)
    }
}
