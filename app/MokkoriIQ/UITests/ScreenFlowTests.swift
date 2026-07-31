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
    /// レポート画面は Apple フィットネス流に「値」と「単位」を分けて描くので、
    /// 単位なしの数値で照合する（一覧・確認画面は fmtMeters のまま）
    let distanceValue = "1,050"

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

    /// 一覧の行。見出しは日時になったので、行の特定はファイル名を含む補助行で行う
    /// （日時の書式が変わっても壊れないように、完全一致ではなく CONTAINS で見る）。
    func sessionRow(_ app: XCUIApplication, _ csv: String? = nil) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", csv ?? sessionName)).firstMatch
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

    /// グラフの「画面に見えている行」をタップする。グラフはセッションの長さに比例して
    /// 縦に伸びる（1ラップ 12pt）ので画面より高くなり、正規化オフセットをそのまま渡すと
    /// 画面外を指してタップが無効になる。上下 40pt はメモリと角丸を避けるための余白。
    /// `bias` は「画面に見えているグラフの範囲」の中での縦位置（0=上端, 1=下端）。
    func tapChart(_ app: XCUIApplication, _ chart: XCUIElement, bias: CGFloat = 0.5) {
        let f = chart.frame
        // 上下 100pt はナビゲーションバーとタブバーに隠れる帯
        let top = max(f.minY + 40, app.frame.minY + 100)
        let bottom = min(f.maxY - 8, app.frame.maxY - 100)
        let y = top + (bottom - top) * bias
        chart.coordinate(withNormalizedOffset:
            CGVector(dx: 0.35, dy: (y - f.minY) / f.height)).tap()
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
        let row = sessionRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 60), "セッション行が出ない（取込か解析で失敗）")
        // 一覧も値と単位を分けて描くので単位なしで照合（累計と行の両方に出る）
        XCTAssertTrue(app.staticTexts[distanceValue].exists, "一覧に距離が出ていない")
        XCTAssertTrue(app.staticTexts["累計距離"].exists, "累計サマリーが無い")
        XCTAssertTrue(app.staticTexts["平均ペース"].exists, "累計の平均ペースが無い")

        row.tap()

        // レポート: 距離・ペース・ストローク系が出ること
        XCTAssertTrue(app.staticTexts[distanceValue].waitForExistence(timeout: 20),
                      "レポートに距離が出ない")
        XCTAssertTrue(app.staticTexts["ストローク"].exists, "ストローク行が無い")
        XCTAssertTrue(app.staticTexts["平均SWOLF"].exists, "SWOLF 行が無い")
        XCTAssertTrue(scrollTo(app, "インターバル"), "インターバルのセクションが無い")

        // 本ごとセクション（ガーミン互換メトリクス）
        XCTAssertTrue(scrollTo(app, "ラップ（25m）"), "ラップのセクションが無い")
    }

    /// ペースグラフ（docs/pace_chart_design.md）。数値は MokkoriCore のテストで
    /// 固めてあるので、ここでは**画面に出て説明文が付いていること**を見る。
    func testPaceChartAppears() {
        let app = makeApp()
        app.launch()

        let row = sessionRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        row.tap()

        XCTAssertTrue(app.staticTexts[distanceValue].waitForExistence(timeout: 20))
        XCTAssertTrue(scrollTo(app, "ペースの推移"), "ペースの推移セクションが無い")
        dump(app, "pace_chart")

        // 傾向は必ず一行で言い切る（グラフを読めなくても分かるように）
        let trend = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '/100m' AND (label CONTAINS '垂れ' OR label CONTAINS 'ビルドアップ' OR label CONTAINS 'ほぼ一定')"))
        XCTAssertGreaterThan(trend.count, 0, "傾向の要約が出ていない")
        XCTAssertTrue(app.staticTexts["バーをタップするとラップの詳細が出ます"].exists,
                      "タップの案内が無い")

        // バーをタップすると、そのバーに貼り付いたツールチップに
        // ラップの詳細（ラップタイム/ストローク/SWOLF）が出る
        let chart = app.otherElements["paceChart"]
        XCTAssertTrue(chart.exists, "グラフ本体が見つからない")
        // グラフは縦に長く、見出しが出た時点ではまだ画面の下端。人が触るときと同じく
        // グラフ本体が画面に入るまで送ってからタップする（スクショの確認にも要る）。
        app.swipeUp(velocity: .slow)
        app.swipeUp(velocity: .slow)
        // グラフ(536pt)は画面より高いので、正規化オフセットの 0.5 は画面外を指しうる。
        // 画面の中央がグラフのどこに当たるかから dy を出す。
        tapChart(app, chart)
        let tooltip = app.descendants(matching: .any)
            .matching(identifier: "paceTooltip").firstMatch
        let appeared = tooltip.waitForExistence(timeout: 5)
        dump(app, "pace_chart_selected")
        XCTAssertTrue(appeared, "バーをタップしてもツールチップが出ない")
        XCTAssertTrue(tooltip.label.contains("ラップ目") && tooltip.label.contains("SWOLF"),
                      "ツールチップの内容が足りない: \(tooltip.label)")
        XCTAssertTrue(app.staticTexts["もう一度タップで選択を解除"].exists,
                      "解除の案内が無い")
        XCTAssertTrue(chart.frame.insetBy(dx: -6, dy: -6).contains(tooltip.frame),
                      "ツールチップがグラフからはみ出している: \(tooltip.frame) / \(chart.frame)")

        // 遅いラップはバーが右端まで届くので、ツールチップは先端の左へ折り返す。
        // 垂れている終盤のラップを選んで、折り返しても収まることを見る。
        tapChart(app, chart, bias: 1.0)
        dump(app, "pace_chart_selected_flipped")
        XCTAssertTrue(chart.frame.insetBy(dx: -6, dy: -6).contains(tooltip.frame),
                      "折り返したツールチップがはみ出している: \(tooltip.frame) / \(chart.frame)")

        // 同じラップをもう一度タップすると選択が外れ、ツールチップも消える
        tapChart(app, chart, bias: 1.0)
        XCTAssertTrue(app.staticTexts["バーをタップするとラップの詳細が出ます"]
            .waitForExistence(timeout: 5), "選択が解除されていない")
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
            let row = sessionRow(app, csv)
            XCTAssertTrue(row.waitForExistence(timeout: 60))
            row.tap()
            XCTAssertTrue(app.staticTexts["タイム"].waitForExistence(timeout: 20))
            let short = csv.replacingOccurrences(of: "swim_", with: "")
                .replacingOccurrences(of: ".csv", with: "")
            scrollTo(app, "ペースの推移")
            dump(app, "\(tag)_\(short)_top")
            // グラフの末尾とキャプション（傾向の一行）まで送る
            let caption = app.staticTexts["バーをタップするとラップの詳細が出ます"]
            for _ in 0..<8 where !caption.isHittable { app.swipeUp(velocity: .slow) }
            dump(app, "\(tag)_\(short)_bottom")
            scrollTo(app, "ラップ（25m）")
            dump(app, "\(tag)_\(short)_laps")
            app.terminate()
        }
    }

    func testWallEditRecomputesDistance() {
        let app = makeApp()
        app.launch()

        let row = sessionRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        row.tap()

        app.buttons["ラップを確認・修正"].firstMatch.tap()

        // 確認画面: ブロックごとの行が出る
        XCTAssertTrue(app.staticTexts[distance].waitForExistence(timeout: 20),
                      "確認画面に距離が出ない")
        // セット番号は泳ぎのあるブロックだけを 1 から数える（入水前などの
        // 泳ぎゼロのブロックは番号を食わない）
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'セット '")).count > 0,
            "セット見出しが無い")

        let turnCells = app.cells.containing(.staticText, identifier: nil)
        XCTAssertGreaterThan(turnCells.count, 5, "壁インターバルの行が少なすぎる")

        // 壁を1つ消すと距離が即座に 25m 減る（＝再計算が効いている）
        let firstTurn = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'ターン'")).firstMatch
        XCTAssertTrue(firstTurn.waitForExistence(timeout: 10), "ターンの行が無い")
        firstTurn.swipeLeft()
        app.buttons["ターンを削除"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts[distanceAfterRemovingOneWall]
                        .waitForExistence(timeout: 20),
                      "壁を消しても距離が再計算されない")

        // 修正を破棄すると元に戻る
        app.buttons["修正を破棄"].tap()
        app.buttons["破棄する"].tap()
        XCTAssertTrue(app.staticTexts[distance].waitForExistence(timeout: 20),
                      "修正を破棄しても元に戻らない")
    }

    /// タブ構成: デバイス（本体まわり）とログ（今までの画面）の2つ。
    /// 起動時はログ、設定は今までどおりログ画面の左上。
    func testTabsAndDeviceScreen() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["ログ"].waitForExistence(timeout: 20),
                      "ログタブが無い")
        XCTAssertTrue(app.tabBars.buttons["デバイス"].exists, "デバイスタブが無い")
        // 起動時はログ側（セッション行が見えている）
        XCTAssertTrue(sessionRow(app).waitForExistence(timeout: 60),
                      "起動時にログが開いていない")
        XCTAssertTrue(app.buttons["設定"].exists, "設定ボタンがログ画面に無い")

        app.tabBars.buttons["デバイス"].tap()
        XCTAssertTrue(app.staticTexts["Mokkori IQ"].waitForExistence(timeout: 10),
                      "デバイス画面が出ない")
        // シミュレータに BLE は無いので本体には繋がらない。**繋がらない理由を
        // 画面に出したうえで**、本体が要る操作を押せなくしてあることを確かめる
        // （黙って空欄にして押せる、が一番まずい）。
        let reasons = ["この端末は Bluetooth LE に対応していません", "Bluetooth がオフです",
                       "Bluetooth の使用が許可されていません", "本体をさがしています", "未接続"]
        XCTAssertTrue(reasons.contains { app.staticTexts[$0].exists },
                      "未接続の理由が出ていない")
        XCTAssertTrue(app.buttons["CSV から取り込む"].isEnabled, "CSV 取り込みが押せない")
        XCTAssertFalse(app.buttons["本体から吸い出す"].isEnabled, "未接続でも吸い出しが押せる")
        // 時刻合わせは接続時に自動でやるので、ボタンは「合わせ直す」用に残してある
        XCTAssertFalse(app.buttons["いま合わせ直す"].isEnabled, "未接続でも時刻合わせが押せる")
        XCTAssertFalse(app.buttons["メモリーを消去"].isEnabled, "未接続でも消去が押せる")
        dump(app, "device_tab")
    }

    /// 振動は「3パターン固定 × 発動距離」。BLE もモーターも無いが、設定だけは今から作れる。
    func testHapticPatternAssignmentPersists() {
        let app = makeApp()
        app.launch()
        app.tabBars.buttons["デバイス"].tap()

        // 振動の設定は画面の一番下。List は画面に入るまで行を作らないので送ってから見る
        XCTAssertTrue(scrollTo(app, "振動フィードバック"), "振動フィードバックの節が無い")
        for n in 1...3 {
            XCTAssertTrue(app.staticTexts["振動パターン\(n)"].waitForExistence(timeout: 10),
                          "振動パターン\(n) が無い")
        }
        dump(app, "device_haptic")

        // パターン1 に 100m を割り当てる（既定は未設定）。
        // メニュー形式のピッカーなので「セルを叩く → 出てきた選択肢を叩く」の2段。
        let cell = app.cells.containing(.staticText, identifier: "振動パターン1").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "パターン1 の行が無い")
        cell.tap()
        let option = app.buttons["100m ごと"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 10), "距離の選択肢が出ない")
        option.tap()

        let summary = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '振動パターン1=100m'")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10),
                      "割り当てが要約に出ていない")

        // 再起動しても残っている
        app.terminate()
        app.launch()
        app.tabBars.buttons["デバイス"].tap()
        scrollTo(app, "振動フィードバック")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '振動パターン1=100m'"))
            .firstMatch.waitForExistence(timeout: 20),
            "振動の設定が保存されていない")
    }

    func testStravaUploadScreenShowsPreview() {
        let app = makeApp()
        app.launch()

        let row = sessionRow(app)
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
