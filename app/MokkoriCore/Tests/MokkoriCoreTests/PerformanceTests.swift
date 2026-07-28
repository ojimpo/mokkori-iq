import XCTest
@testable import MokkoriCore

/// 取込〜解析の所要時間を段階ごとに出す計測用。iPhone はここより数倍遅いので、
/// Mac で数秒かかる処理は実機で「取込のたびに十数秒待つ」ことになる。
/// `swift test --filter PerformanceTests` で実行（数値は環境依存なので assert しない）。
final class PerformanceTests: XCTestCase {

    func testStageTimings() throws {
        let url = ParityTests.dataDir().appendingPathComponent("swim_20260728_153415.csv")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("data/swim/ 未取得")
        }

        func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let t0 = Date()
            let r = try body()
            print(String(format: "  %-22s %6.2f s", (label as NSString).utf8String!,
                         Date().timeIntervalSince(t0)))
            return r
        }

        print("=== stage timings (\(url.lastPathComponent)) ===")
        let text = try time("read file") { try String(contentsOf: url, encoding: .utf8) }
        let sess = try time("parse CSV") { try SwimSession.parseCSV(text) }
        let rec = try time("encode int16") { try RawRecording.encode(csvText: text) }
        _ = time("decode int16") { rec.decode() }
        let gz = time("verticality") { WallDetector.verticality(sess) }
        _ = gz
        let d = time("detectWalls") { WallDetector.detectWalls(sess) }
        let report = time("makeReport") { SwimReporter.makeReport(sess, detection: d) }
        _ = time("intervals") { WallIntervalTable.rows(for: d) }
        print("  samples=\(sess.count) walls=\(d.turns.count) lengths=\(report.lengths.count)")
    }
}
