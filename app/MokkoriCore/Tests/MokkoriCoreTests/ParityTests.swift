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
        let distSets: [Int]
        let distTotal: Int
        // ラップごとメトリクス（regression_check と同じピン留め値）
        let lapCount: Int        // ラップ数（全ラップで strokes>0 = 計測可能）
        let strokesTotal: Int
        let splMedian: Double
        let swolfAvgRounded: Int
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
        XCTAssertEqual(report.sets.map { Int($0.distance) }, exp.distSets,
                       "\(name): set distances")
        XCTAssertEqual(Int(report.distance), exp.distTotal, "\(name): total distance")

        // セット番号は泳ぎのあるブロックだけを 1 から連番で数える。検出ブロックの
        // 通し番号をそのまま出すと、入水前やシャワーのブロックが番号を食って
        // 7/28 が「セット2 / セット3」から始まってしまう（2026-07-28 に修正）。
        XCTAssertEqual(report.sets.map(\.index), Array(1...exp.distSets.count),
                       "\(name): セット番号が 1 からの連番でない")
        XCTAssertEqual(Set(report.laps.map(\.setNumber)),
                       Set(1...exp.distSets.count), "\(name): ラップのセット番号")

        // 全インターバルで壁カウントとペース推定が一致（min() 不発）していることも
        // Python 側で実証済みの性質としてピン留めする
        XCTAssertTrue(report.intervals.allSatisfy { !$0.crossCheck },
                      "\(name): CROSS-CHECK が発火（検出ずれ）")

        // 本ごとメトリクス（ストローク数/SWOLF）も Python と同一値
        XCTAssertEqual(report.laps.count, exp.lapCount, "\(name): laps")
        XCTAssertEqual(report.strokedLaps.count, exp.lapCount,
                       "\(name): 計測不能ラップ（strokes=0）が出ている")
        XCTAssertEqual(report.strokesTotal, exp.strokesTotal, "\(name): strokes total")
        XCTAssertEqual(report.strokesPerLapMedian, exp.splMedian,
                       "\(name): strokes/lap median")
        XCTAssertEqual(Int((report.swolfAverage ?? 0).rounded()),
                       exp.swolfAvgRounded, "\(name): swolf avg")
    }

    func testSession20260621() throws {
        try runSession("swim_20260621_171349.csv", Expectation(
            turns: 35, rests: 13, bigs: 2, recoveredAt: [724],
            distSets: [500, 675], distTotal: 1175,
            lapCount: 47, strokesTotal: 647, splMedian: 14, swolfAvgRounded: 44))
    }

    func testSession20260728() throws {
        try runSession("swim_20260728_153415.csv", Expectation(
            turns: 41, rests: 1, bigs: 3, recoveredAt: [533],
            distSets: [625, 425], distTotal: 1050,
            lapCount: 42, strokesTotal: 576, splMedian: 14, swolfAvgRounded: 44))
    }
}
