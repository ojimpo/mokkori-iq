import XCTest

/// 画面を実際に触って回すテスト。
///
/// 解析ロジックは MokkoriCore のテストで固めてあるが、**画面が出るか・遷移するか・
/// 壁を編集すると数値が変わるか**はこれまで人手でしか確かめられなかった。
/// 実機に載せる前にここで落ちるようにしておく。
///
/// セッションは `UITEST_SEED_CSV` に実データ CSV のパスを渡して取り込ませる
/// （アプリ側の種まきフックは環境変数があるときだけ動く）。
final class ScreenFlowTests: XCTestCase {

    let sessionName = "swim_20260728_153415.csv"
    /// 表示は fmtMeters を通すので桁区切りが入る（画面ごとにブレないことも兼ねて検証）
    let distance = "1,050 m"
    let distanceAfterRemovingOneWall = "1,025 m"

    func makeApp(session: String? = nil) -> XCUIApplication {
        let csv = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UITests
            .deletingLastPathComponent()   // MokkoriIQ
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("data/swim/\(session ?? sessionName)")
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CSV"] = csv.path
        return app
    }

    /// ラベルが出るまで下へ送る。レポート画面はペースグラフが入って縦に長くなり、
    /// 下のセクションは画面に入るまで生成されない（List の遅延生成）。
    @discardableResult
    func scrollTo(_ app: XCUIApplication, _ label: String, limit: Int = 8) -> Bool {
        for _ in 0..<limit {
            if app.staticTexts[label].exists { return true }
            app.swipeUp(velocity: .slow)
        }
        return app.staticTexts[label].exists
    }

    /// 目視確認用のスクリーンショット。`UITEST_SCREENSHOT_DIR` を渡したときだけ書く
    /// （グラフのように「数値では通っても見た目が破綻しうる」ものを人が見るため）。
    func dump(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        guard let dir = ProcessInfo.processInfo.environment["UITEST_SCREENSHOT_DIR"]
        else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? app.screenshot().pngRepresentation.write(to: url)
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func testReportAndWallReviewFlow() {
        let app = makeApp()
        app.launch()

        // 一覧: 取込が終わると行が出る（解析込みなので少し待つ）
        let row = app.staticTexts[sessionName]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "セッション行が出ない（取込か解析で失敗）")
        XCTAssertTrue(app.staticTexts[distance].exists, "一覧に距離が出ていない")

        row.tap()

        // レポート: 距離・ペース・ストローク系が出ること
        XCTAssertTrue(app.staticTexts[distance].waitForExistence(timeout: 20),
                      "レポートに距離が出ない")
        XCTAssertTrue(app.staticTexts["ストローク"].exists, "ストローク行が無い")
        XCTAssertTrue(app.staticTexts["SWOLF"].exists, "SWOLF 行が無い")
        XCTAssertTrue(scrollTo(app, "レップ内訳"), "レップ内訳が無い")

        // 本ごとセクション（ガーミン互換メトリクス）
        XCTAssertTrue(scrollTo(app, "本ごと（25m）"), "本ごとセクションが無い")
    }

    /// ペースグラフ（docs/pace_chart_design.md）。数値は MokkoriCore のテストで
    /// 固めてあるので、ここでは**画面に出て説明文が付いていること**を見る。
    func testPaceChartAppears() {
        let app = makeApp()
        app.launch()

        let row = app.staticTexts[sessionName]
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        row.tap()

        XCTAssertTrue(app.staticTexts[distance].waitForExistence(timeout: 20))
        XCTAssertTrue(scrollTo(app, "ペースの推移"), "ペースの推移セクションが無い")
        dump(app, "pace_chart")

        // 傾向は必ず一行で言い切る（グラフを読めなくても分かるように）
        let trend = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '/100m' AND (label CONTAINS '垂れ' OR label CONTAINS 'ビルドアップ' OR label CONTAINS 'ほぼ一定')"))
        XCTAssertGreaterThan(trend.count, 0, "傾向の要約が出ていない")
        XCTAssertTrue(app.staticTexts["バーをタップすると、その本の詳細が出ます"].exists,
                      "タップの案内が無い")

        // バーをタップすると、その本の詳細（本タイム/ストローク/SWOLF）が出る
        let chart = app.otherElements["paceChart"]
        XCTAssertTrue(chart.exists, "グラフ本体が見つからない")
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
        let detail = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '本目（半' AND label CONTAINS 'SWOLF'"))
        XCTAssertTrue(detail.firstMatch.waitForExistence(timeout: 5),
                      "バーをタップしても本の詳細が出ない")
        dump(app, "pace_chart_selected")
    }

    /// もう一方のセッションと、ダークモードの見た目も残す（目視確認用）。
    func testPaceChartSnapshots() throws {
        guard ProcessInfo.processInfo.environment["UITEST_SCREENSHOT_DIR"] != nil else {
            throw XCTSkip("UITEST_SCREENSHOT_DIR 未指定（目視確認のときだけ走らせる）")
        }
        let tag = ProcessInfo.processInfo.environment["UITEST_SCREENSHOT_TAG"] ?? "shot"
        for csv in [sessionName, "swim_20260621_171349.csv"] {
            let app = makeApp(session: csv)
            app.launch()
            let row = app.staticTexts[csv]
            XCTAssertTrue(row.waitForExistence(timeout: 60))
            row.tap()
            XCTAssertTrue(app.staticTexts["泳ぎ時間"].waitForExistence(timeout: 20))
            let short = csv.replacingOccurrences(of: "swim_", with: "")
                .replacingOccurrences(of: ".csv", with: "")
            scrollTo(app, "ペースの推移")
            dump(app, "\(tag)_\(short)_top")
            // グラフの末尾とキャプション（傾向の一行）まで送る
            let caption = app.staticTexts["バーをタップすると、その本の詳細が出ます"]
            for _ in 0..<8 where !caption.isHittable { app.swipeUp(velocity: .slow) }
            dump(app, "\(tag)_\(short)_bottom")
            app.terminate()
        }
    }

    func testWallEditRecomputesDistance() {
        let app = makeApp()
        app.launch()

        let row = app.staticTexts[sessionName]
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        row.tap()

        app.buttons["壁インターバルを確認・修正"].firstMatch.tap()

        // 確認画面: ブロックごとの行が出る
        XCTAssertTrue(app.staticTexts[distance].waitForExistence(timeout: 20),
                      "確認画面に距離が出ない")
        // ブロック番号は検出ブロックの通し番号。入水前などの壁ゼロのブロックは
        // 行が無いので、先頭が「ブロック 1」とは限らない（7/28 は 2 から始まる）
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'ブロック '")).count > 0,
            "ブロック見出しが無い")

        let turnCells = app.cells.containing(.staticText, identifier: nil)
        XCTAssertGreaterThan(turnCells.count, 5, "壁インターバルの行が少なすぎる")

        // 壁を1つ消すと距離が即座に 25m 減る（＝再計算が効いている）
        let firstTurn = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'ターン壁'")).firstMatch
        XCTAssertTrue(firstTurn.waitForExistence(timeout: 10), "ターン壁の行が無い")
        firstTurn.swipeLeft()
        app.buttons["壁を削除"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts[distanceAfterRemovingOneWall]
                        .waitForExistence(timeout: 20),
                      "壁を消しても距離が再計算されない")

        // 修正を破棄すると元に戻る
        app.buttons["修正を破棄"].tap()
        app.buttons["破棄する"].tap()
        XCTAssertTrue(app.staticTexts[distance].waitForExistence(timeout: 20),
                      "修正を破棄しても元に戻らない")
    }

    func testStravaUploadScreenShowsPreview() {
        let app = makeApp()
        app.launch()

        let row = app.staticTexts[sessionName]
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        row.tap()
        app.buttons["Strava へアップ"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["時刻アンカー"].waitForExistence(timeout: 20),
                      "時刻アンカー欄が出ない")
        XCTAssertTrue(app.staticTexts["投稿内容"].exists, "投稿プレビューが出ない")
        // 未設定なら投稿できないこと（誤爆防止）
        XCTAssertFalse(app.buttons["Strava へアップ"].firstMatch.isEnabled,
                       "ゲートウェイ未設定でも投稿できてしまう")
    }
}
