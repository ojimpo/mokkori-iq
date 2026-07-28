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

    func makeApp() -> XCUIApplication {
        let csv = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UITests
            .deletingLastPathComponent()   // MokkoriIQ
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("data/swim/\(sessionName)")
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_CSV"] = csv.path
        return app
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
        XCTAssertTrue(app.staticTexts["レップ内訳"].exists, "レップ内訳が無い")

        // 本ごとセクション（ガーミン互換メトリクス）
        app.swipeUp(velocity: .fast)
        XCTAssertTrue(app.staticTexts["本ごと（25m）"].waitForExistence(timeout: 10),
                      "本ごとセクションが無い")
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
