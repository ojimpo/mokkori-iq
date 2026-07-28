import XCTest
@testable import MokkoriCore

/// int16 バイナリ保存のラウンドトリップ検証:
/// CSV → encode(int16) → binaryData → decode → CSV 直読みと完全同値、
/// したがって検出結果もビット単位で一致すること（永続化の大前提）。
final class RoundTripTests: XCTestCase {

    func testBinaryRoundTripMatchesCSV() throws {
        let url = ParityTests.dataDir().appendingPathComponent("swim_20260728_153415.csv")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("data/swim/ 未取得")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let fromCSV = try SwimSession.parseCSV(text)

        let rec = try RawRecording.encode(csvText: text)
        XCTAssertEqual(rec.count, fromCSV.count)
        XCTAssertEqual(rec.odr, 52.0)

        // シリアライズ往復
        let rec2 = RawRecording(binaryData: rec.binaryData(), odr: rec.odr)
        XCTAssertEqual(rec2.samples, rec.samples)

        let fromBin = rec2.decode()
        XCTAssertEqual(fromBin.fs, fromCSV.fs)
        XCTAssertEqual(fromBin.t, fromCSV.t)
        XCTAssertEqual(fromBin.ax, fromCSV.ax)
        XCTAssertEqual(fromBin.ay, fromCSV.ay)
        XCTAssertEqual(fromBin.az, fromCSV.az)
        XCTAssertEqual(fromBin.gx, fromCSV.gx)
        XCTAssertEqual(fromBin.gy, fromCSV.gy)
        XCTAssertEqual(fromBin.gz, fromCSV.gz)
    }

    /// 高速パーサに置き換えても、想定外の CSV を黙って読まないこと。
    /// 列数だけ合う別物を通すと、意味のない解析結果が「セッション」として保存される。
    func testRejectsForeignCSV() {
        let foreign = """
        time,lat,lon,ele,hr,cad,pow,temp
        0,35.6,139.7,10,120,80,200,25
        1,35.6,139.7,11,121,81,201,25
        """
        XCTAssertThrowsError(try SwimSession.parseCSV(foreign), "別形式の CSV が通ってしまう")
        XCTAssertThrowsError(try RawRecording.encode(csvText: foreign))

        XCTAssertThrowsError(try SwimSession.parseCSV("")) { e in
            guard case SwimSession.LoadError.badHeader = e else {
                return XCTFail("空データは badHeader: \(e)")
            }
        }

        // ヘッダは正しいが行が壊れている場合
        let broken = "idx,t,ax,ay,az,gx,gy,gz\n0,0.0,0.1,0.2,0.3\n"
        XCTAssertThrowsError(try SwimSession.parseCSV(broken))
    }

    func testOverlayAddRemove() throws {
        let url = ParityTests.dataDir().appendingPathComponent("swim_20260728_153415.csv")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("data/swim/ 未取得")
        }
        let sess = try SwimSession.loadCSV(url)
        let d = WallDetector.detectWalls(sess)
        let baseTurns = d.turns.count

        // 1本削除 + 1本追加 → カウントが追随し、再計算で距離が変わる
        let victim = d.turns[3]
        var ov = WallOverlay()
        ov.removed.append(victim.start)
        ov.added.append(victim.mid + 200.0)
        let edited = ov.apply(to: d)
        XCTAssertEqual(edited.turns.count, baseTurns)
        XCTAssertFalse(edited.turns.contains(victim))

        // 空オーバーレイは無変化
        let noop = WallOverlay().apply(to: d)
        XCTAssertEqual(noop.turns, d.turns)
        let r0 = SwimReporter.makeReport(sess, detection: d)
        let r1 = SwimReporter.makeReport(sess, detection: noop)
        XCTAssertEqual(r0.distance, r1.distance)
    }

    func testWallIntervalRows() throws {
        let url = ParityTests.dataDir().appendingPathComponent("swim_20260728_153415.csv")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("data/swim/ 未取得")
        }
        let sess = try SwimSession.loadCSV(url)
        let d = WallDetector.detectWalls(sess)
        let rows = WallIntervalTable.rows(for: d)

        // 行数 = (turns + rests) + ブロック終端行（壁のあるブロック数）
        let blocksWithWalls = Set(rows.map(\.blockIndex)).count
        XCTAssertEqual(rows.count, d.turns.count + d.rests.count + blocksWithWalls)
        // リカバリ壁の行がちゃんど印付けされる
        XCTAssertEqual(rows.filter(\.isRecovered).count, d.recovered.count)
        // 7/28 は全レップ一致セッションなので、壁行に missedSuspect は残っていないはず
        let wallRows = rows.filter { $0.kind != .blockEnd }
        XCTAssertTrue(wallRows.allSatisfy { $0.flag != .missedSuspect },
                      "リカバリ後に見逃し疑いが残っている")
    }
}
