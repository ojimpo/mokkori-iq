import XCTest
@testable import MokkoriCore

/// ペースグラフのデータモデル（軸の切り方・異常値・傾向線）を実データでピン留めする。
/// 描画そのものは UI テスト側で見るが、**何ラップが強調されるか**はここで固定しておく
/// （閾値を緩めるとラベルだらけになって「一目で分かる」が壊れるため）。
final class PaceChartTests: XCTestCase {

    struct Expectation {
        let rows: Int
        let emphasized: Int      // 強調されるラップ（異常値 or 疑い）
        let boundaries: Int      // インターバル境界
        let blockBoundaries: Int // うちセット境界（大休憩）
        let bestSeconds: Double
        let trendDelta: Double   // セッションを通したペース変化（s /100m）
    }

    @discardableResult
    func runChart(_ name: String, _ exp: Expectation) throws -> PaceChart {
        let url = ParityTests.dataDir().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(name) がありません（data/swim/ 未取得）")
        }
        let sess = try SwimSession.loadCSV(url)
        let d = WallDetector.detectWalls(sess)
        let report = SwimReporter.makeReport(sess, detection: d)
        let chart = PaceChart.make(report: report, detection: d)

        // 軸・傾向の実値は目視調整の手がかりとして残す
        print(String(format: "[%@] ラップ=%d 強調=%d 軸=%.1f〜%.1f 平均=%.1f 傾向=%+.1f ベスト=%.2f 境界=%d(セット%d)",
                     name, chart.rows.count, chart.rows.filter(\.isEmphasized).count,
                     chart.axisLo, chart.axisHi, chart.averagePace100,
                     chart.trendDelta, chart.best?.duration ?? 0,
                     chart.boundaries.count, chart.boundaries.filter(\.isBlock).count))

        XCTAssertEqual(chart.rows.count, exp.rows, "\(name): ラップ数")
        XCTAssertEqual(chart.rows.filter(\.isEmphasized).count, exp.emphasized,
                       "\(name): 強調されるラップ")
        XCTAssertEqual(chart.boundaries.count, exp.boundaries, "\(name): インターバル境界")
        XCTAssertEqual(chart.boundaries.filter(\.isBlock).count, exp.blockBoundaries,
                       "\(name): セット境界")
        XCTAssertEqual(chart.best?.duration ?? 0, exp.bestSeconds, accuracy: 0.05,
                       "\(name): ベスト1ラップ")
        XCTAssertEqual(chart.trendDelta, exp.trendDelta, accuracy: 0.1,
                       "\(name): 傾向")

        // 距離軸は本数ぶんちょうど（バーが軸をはみ出さない）
        XCTAssertEqual(chart.totalMeters, Double(exp.rows) * chart.poolLength)
        XCTAssertEqual(chart.rows.last?.distanceEnd, chart.totalMeters)

        // 横軸は全バーと平均線を含み、かつ最低でも平均±10s/100m を確保する
        XCTAssertLessThanOrEqual(chart.axisLo, chart.rows.map(\.pace100).min()!)
        XCTAssertGreaterThanOrEqual(chart.axisHi, chart.rows.map(\.pace100).max()!)
        XCTAssertLessThanOrEqual(chart.axisLo,
                                 chart.averagePace100 - PaceChart.axisMinHalfWidth)
        XCTAssertGreaterThanOrEqual(chart.axisHi,
                                    chart.averagePace100 + PaceChart.axisMinHalfWidth)

        // 強調されるラップは全体のごく一部（＝ラベルが埋まらない）
        XCTAssertLessThan(Double(chart.rows.filter(\.isEmphasized).count),
                          Double(exp.rows) * 0.2,
                          "\(name): 強調が多すぎてラベルが埋まる")
        return chart
    }

    /// 実データ2セッションはどちらも強調ゼロ。最遅のラップでもセット中央値の 1.17 倍で、
    /// 判定値 1.25 倍に届かない（＝この泳者のペースはそれだけ揃っている）。
    /// 強調は「検出がずれた／本当に崩れた」ときだけ出る非常口という位置づけで、
    /// 実際に色が付く経路は下の合成データテストで担保する。
    func testChart20260621() throws {
        let chart = try runChart("swim_20260621_171349.csv",
                                 Expectation(rows: 47, emphasized: 0, boundaries: 11,
                                             blockBoundaries: 1, bestSeconds: 26.06,
                                             trendDelta: 5.9))
        // 距離は min() 不発なのでレポートと一致（注記を出す必要が無い）
        XCTAssertNil(chart.distanceMismatch)
    }

    func testChart20260728() throws {
        let chart = try runChart("swim_20260728_153415.csv",
                                 Expectation(rows: 42, emphasized: 0, boundaries: 1,
                                             blockBoundaries: 1, bestSeconds: 25.58,
                                             trendDelta: 13.2))
        XCTAssertNil(chart.distanceMismatch)
    }

    // MARK: - 合成データ（実データでは通らない経路）

    private func fakeReport(durations: [Double], pool: Double = 25.0) -> SwimReport {
        var laps = [SwimReport.Lap]()
        var t = 0.0
        for (i, d) in durations.enumerated() {
            laps.append(SwimReport.Lap(setNumber: 1, interval: 1, number: i + 1,
                                       span: Span(t, t + d), strokes: 14))
            t += d
        }
        let total = durations.reduce(0, +)
        let interval = SwimReport.Interval(setNumber: 1, number: 1, span: Span(0, t), swimTime: total,
                                 wallCount: durations.count, paceCount: durations.count,
                                 laps: durations.count)
        let dist = Double(durations.count) * pool
        return SwimReport(typicalLapTime: 30, poolLength: pool, intervals: [interval],
                          sets: [SwimReport.SetSummary(index: 1, distance: dist,
                                                   movingTime: total,
                                                   pace100: total / dist * 100)],
                          laps: laps, distance: dist, movingTime: total,
                          elapsed: total)
    }

    private var emptyDetection: WallDetection {
        WallDetection(gz: [], turns: [], rests: [], bigs: [], taps: [], triples: [],
                      recovered: [], blockStarts: [], blockEnds: [])
    }

    /// 中央値から ±25% 外れたラップだけが強調される（隣接の普通のラップは巻き込まない）。
    func testOutlierEmphasis() {
        // 中央値 30s → 遅い異常値 38s(1.27倍) / 速い異常値 22s(0.73倍)、
        // 37s(1.23倍) と 23s(0.77倍) は境界の内側なので強調しない
        let report = fakeReport(durations: [30, 30, 38, 30, 22, 30, 37, 23, 30, 30])
        let chart = PaceChart.make(report: report, detection: emptyDetection)
        XCTAssertEqual(chart.rows.filter(\.isOutlier).map(\.id), [2, 4])
        XCTAssertEqual(chart.best?.id, 4)
    }

    /// 全部同じペースでも軸が潰れない（平均 ± 10s/100m を必ず含む）。
    func testUniformSessionAxisDoesNotOverZoom() {
        let chart = PaceChart.make(report: fakeReport(durations: Array(repeating: 30, count: 8)),
                                   detection: emptyDetection)
        XCTAssertEqual(chart.rows.filter(\.isEmphasized).count, 0)
        XCTAssertGreaterThanOrEqual(chart.axisHi - chart.axisLo, 20.0)
        XCTAssertTrue(chart.isTrendFlat)
    }

    /// 単調に遅くなるセッションは「垂れ」として正の傾向が出る。
    func testTrendDetectsFade() {
        let chart = PaceChart.make(
            report: fakeReport(durations: (0..<10).map { 28.0 + Double($0) * 0.5 }),
            detection: emptyDetection)
        XCTAssertFalse(chart.isTrendFlat)
        XCTAssertGreaterThan(chart.trendDelta, 0)
        // 1ラップあたり +0.5s = 100m 換算 +2s。10ラップの中点間（225m）で +18s だが、
        // 傾向線はグラフの上端(0m)から下端(250m)まで引くので +20s になる。
        XCTAssertEqual(chart.trendDelta, 20.0, accuracy: 0.5)
    }

    /// min() が効いて距離が食い違ったセッションでは注記用の差が出る。
    func testDistanceMismatchIsReported() {
        var report = fakeReport(durations: Array(repeating: 30, count: 8))
        report = SwimReport(typicalLapTime: report.typicalLapTime,
                            poolLength: report.poolLength, intervals: report.intervals,
                            sets: report.sets, laps: report.laps,
                            distance: 175, movingTime: report.movingTime,
                            elapsed: report.elapsed)
        let chart = PaceChart.make(report: report, detection: emptyDetection)
        XCTAssertEqual(chart.totalMeters, 200)
        XCTAssertEqual(chart.distanceMismatch ?? 0, -25, accuracy: 0.001)
    }
}
