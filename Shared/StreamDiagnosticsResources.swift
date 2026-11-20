// Streaming diagnostics (#123): low-rate resource sampling and signposts.
//
// Public APIs only: getrusage, task_info(TASK_VM_INFO), ProcessInfo. Sampled
// once per diagnostics window (5 s), never per frame. Battery state needs
// UIKit, so the iOS diagnostics page supplies it while it is open.

import Foundation
import os

enum DiagnosticsThermalState: String, Codable, Sendable {
    case nominal, fair, serious, critical, unknown

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}

enum DiagnosticsBatteryState: String, Codable, Sendable {
    case unplugged, charging, full, unknown
}

struct StreamDiagnosticsResourceSample: Codable, Equatable, Sendable {
    /// Process CPU time over wall time since the previous sample, as a
    /// percentage of one core. nil on the first sample.
    var processCPUPercent: Double?
    var memoryFootprintMB: Double?
    var thermalState: DiagnosticsThermalState
    var lowPowerMode: Bool
    var batteryState: DiagnosticsBatteryState?
    var sampleIntervalSeconds: Double?
}

final class StreamDiagnosticsResourceSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastCPUSeconds: Double?
    private var lastWallSeconds: Double?

    /// Set by the iOS diagnostics page (main actor) while it is open.
    private static let batteryLock = NSLock()
    nonisolated(unsafe) private static var battery: DiagnosticsBatteryState?
    static func setBatteryState(_ state: DiagnosticsBatteryState?) {
        batteryLock.lock(); battery = state; batteryLock.unlock()
    }
    private static func currentBattery() -> DiagnosticsBatteryState? {
        batteryLock.lock(); defer { batteryLock.unlock() }
        return battery
    }

    func sample() -> StreamDiagnosticsResourceSample {
        let cpu = Self.processCPUSeconds()
        let wall = StreamDiagnosticsClock.nowSeconds()
        lock.lock()
        var percent: Double?
        var interval: Double?
        if let cpu, let lastCPU = lastCPUSeconds, let lastWall = lastWallSeconds, wall > lastWall {
            interval = wall - lastWall
            percent = (cpu - lastCPU) / (wall - lastWall) * 100
        }
        lastCPUSeconds = cpu
        lastWallSeconds = wall
        lock.unlock()
        return StreamDiagnosticsResourceSample(
            processCPUPercent: percent,
            memoryFootprintMB: Self.memoryFootprintBytes().map { Double($0) / 1_048_576 },
            thermalState: DiagnosticsThermalState(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            batteryState: Self.currentBattery(),
            sampleIntervalSeconds: interval)
    }

    static func processCPUSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    static func memoryFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

// MARK: - Signposts

/// An interval begun on one thread and ended on another (encode, send).
struct DiagnosticsSignpostToken: @unchecked Sendable {
    fileprivate let state: OSSignpostIntervalState?
    static let none = DiagnosticsSignpostToken(state: nil)
}

/// `OSSignposter` intervals for the main stages, behind the same switch as
/// the recorder: when diagnostics are off nothing is emitted. View them in
/// Instruments (os_signpost, subsystem below, category StreamDiagnostics).
enum StreamDiagnosticsSignposts {
    static let signposter = OSSignposter(subsystem: "com.raisecaterror.meowdisplay", category: "StreamDiagnostics")

    static func begin(_ name: StaticString, enabled: Bool) -> DiagnosticsSignpostToken {
        guard enabled else { return .none }
        let id = signposter.makeSignpostID()
        return DiagnosticsSignpostToken(state: signposter.beginInterval(name, id: id))
    }

    static func end(_ name: StaticString, _ token: DiagnosticsSignpostToken) {
        guard let state = token.state else { return }
        signposter.endInterval(name, state)
    }

    static func event(_ name: StaticString, enabled: Bool) {
        guard enabled else { return }
        signposter.emitEvent(name)
    }
}
