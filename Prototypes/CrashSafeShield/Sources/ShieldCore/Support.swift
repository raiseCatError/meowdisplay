import AppKit
import Foundation

/// Timestamped log lines (wall-clock epoch ms first, so runs can be lined up with the tracer).
public final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?
    private let tag: String

    public init(path: String?, tag: String) {
        self.tag = tag
        if let path {
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path)
            handle?.seekToEndOfFile()
        } else {
            handle = nil
        }
    }

    public func callAsFunction(_ text: String) {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let line = "\(ms) [\(tag) \(getpid())] \(text)\n"
        lock.lock(); defer { lock.unlock() }
        if let handle { handle.write(line.data(using: .utf8)!) } else { FileHandle.standardError.write(line.data(using: .utf8)!) }
    }
}

/// A full-screen cover like the app's: black, above everything, left out of every capture, and
/// letting clicks through to the windows below (remote input still reaches them).
@MainActor
public enum CoverWindows {
    public static var shieldingLevel: NSWindow.Level { NSWindow.Level(rawValue: Int(CGShieldingWindowLevel())) }

    public static func make(label: String) -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = shieldingLevel
        w.backgroundColor = .black
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.sharingType = .none
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let text = NSTextField(labelWithString: label)
        text.textColor = NSColor(white: 0.55, alpha: 1)
        text.font = .systemFont(ofSize: 15, weight: .medium)
        text.sizeToFit()
        let content = NSView()
        content.addSubview(text)
        text.frame.origin = NSPoint(x: 40, y: 40)
        w.contentView = content
        return w
    }

    /// One cover per screen, sized now (screens are re-read on every show).
    public static func show(_ pool: inout [NSWindow], label: String) {
        let screens = NSScreen.screens
        while pool.count < screens.count { pool.append(make(label: label)) }
        for (i, w) in pool.enumerated() {
            if i < screens.count {
                w.setFrame(screens[i].frame, display: true)
                w.orderFrontRegardless()
            } else {
                w.orderOut(nil)
            }
        }
    }

    public static func hide(_ pool: [NSWindow]) { pool.forEach { $0.orderOut(nil) } }
}

/// Exits the process after `seconds` no matter what the main thread is doing (prototype safety).
public func armHardDeadline(_ seconds: Double, log: LineLog) {
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
        log("hard deadline \(seconds) s reached: exiting")
        exit(0)
    }
}

public func argumentValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

public func argumentFlag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }
