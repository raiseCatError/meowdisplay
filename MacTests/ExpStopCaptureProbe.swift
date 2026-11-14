import XCTest
@preconcurrency import ScreenCaptureKit

/// Experiment only (never merged): how long ScreenCaptureKit's stopCapture takes on a stream
/// that never started, alone and three at a time. A call still running after 20 s counts as hung.
final class ExpStopCaptureProbe: XCTestCase {
    private static func timedStop(limit: Double = 20) async -> Double? {
        let s = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        let start = ProcessInfo.processInfo.systemUptime
        return await withTaskGroup(of: Double?.self) { group in
            group.addTask { try? await s.stopCapture(); return ProcessInfo.processInfo.systemUptime - start }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(limit * 1e9)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func report(_ name: String, _ results: [Double?]) {
        let done = results.compactMap { $0 }.sorted()
        let hung = results.count - done.count
        let p = { (q: Double) in done.isEmpty ? -1 : done[min(done.count - 1, Int(Double(done.count) * q))] }
        print("PROBE \(name): calls=\(results.count) hung=\(hung) p50=\(p(0.5)) p90=\(p(0.9)) p99=\(p(0.99)) max=\(done.last ?? -1)")
    }

    func testSequential() async {
        var results: [Double?] = []
        for _ in 0..<60 { results.append(await Self.timedStop()) }
        report("sequential", results)
    }

    func testThreeAtATime() async {
        var results: [Double?] = []
        for _ in 0..<20 {
            let batch = await withTaskGroup(of: Double?.self) { group in
                for _ in 0..<3 { group.addTask { await ExpStopCaptureProbe.timedStop() } }
                var out: [Double?] = []
                for await r in group { out.append(r) }
                return out
            }
            results += batch
        }
        report("three-at-a-time", results)
    }
}
