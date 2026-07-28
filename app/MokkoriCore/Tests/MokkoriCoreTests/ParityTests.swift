import XCTest
@testable import MokkoriCore

/// analysis/regression_check.py と同一の疑似GT期待値をピン留めするパリティテスト。
/// リポジトリ内 data/swim/ の実セッション CSV を直接読む（#filePath からの相対）。
/// これが green = Python 実装との移植パリティ達成（Phase A の完了条件）。
final class ParityTests: XCTestCase {

    static func dataDir() -> URL {
        // .../app/MokkoriCore/Tests/MokkoriCoreTests/ParityTests.swift → リポジトリルート
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // → MokkoriCoreTests/
            .deletingLastPathComponent()  // → Tests/
            .deletingLastPathComponent()  // → MokkoriCore/
            .deletingLastPathComponent()  // → app/
            .deletingLastPathComponent()  // → リポジトリルート
            .appendingPathComponent("data/swim")
    }

    struct Expectation {
        let turns: Int
        let rests: Int
        let bigs: Int
        let recoveredAt: [Double]   // 復元壁の中点時刻（±5s 許容 = regression_check の TOL_S）
        let distHalves: [Int]
        let distTotal: Int
    }

    func runSession(_ name: String, _ exp: Expectation) throws {
        let url = Self.dataDir().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(name) がありません（data/swim/ 未取得）")
        }
        let sess = try SwimSession.loadCSV(url)
        let d = WallDetector.detectWalls(sess)

        XCTAssertEqual(d.turns.count, exp.turns, "\(name): turns")
        XCTAssertEqual(d.rests.count, exp.rests, "\(name): rests")
        XCTAssertEqual(d.bigs.count, exp.bigs, "\(name): bigs")

        let rec = d.recovered.map(\.mid).sorted()
        XCTAssertEqual(rec.count, exp.recoveredAt.count, "\(name): recovered count")
        for (r, e) in zip(rec, exp.recoveredAt.sorted()) {
            XCTAssertEqual(r, e, accuracy: 5.0, "\(name): recovered at")
        }

        let report = SwimReporter.makeReport(sess, detection: d)
        XCTAssertEqual(report.halves.map { Int($0.distance) }, exp.distHalves,
                       "\(name): half distances")
        XCTAssertEqual(Int(report.distance), exp.distTotal, "\(name): total distance")

        // 全レップで壁カウントとペース推定が一致（min() 不発）していることも
        // Python 側で実証済みの性質としてピン留めする
        XCTAssertTrue(report.reps.allSatisfy { !$0.crossCheck },
                      "\(name): CROSS-CHECK が発火（検出ずれ）")
    }

    func testSession20260621() throws {
        try runSession("swim_20260621_171349.csv", Expectation(
            turns: 35, rests: 13, bigs: 2, recoveredAt: [724],
            distHalves: [500, 675], distTotal: 1175))
    }

    func testSession20260728() throws {
        try runSession("swim_20260728_153415.csv", Expectation(
            turns: 41, rests: 1, bigs: 3, recoveredAt: [533],
            distHalves: [625, 425], distTotal: 1050))
    }
}
