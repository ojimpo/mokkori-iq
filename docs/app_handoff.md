# mokkori-iq アプリ開発 引き継ぎメモ (2026-07-28 時点)

次のセッションはこれを読めば続きから入れる。全体計画は `docs/phase2_app_plan.md`、
プロジェクト全体の約束事は `CLAUDE.md`。**Phase A / B のコードは完成していて、
残りは実機での確認と Phase C 以降**。

## 30秒でわかる現状

| | 状態 |
|---|---|
| Phase A: 解析エンジンの Swift 移植 + 確認画面 | ✅ 完了（パリティテスト green） |
| Phase B: Strava アップロード | ✅ 実装完了（**実投稿だけ未テスト**） |
| Phase C: ファーム時刻アンカー (TIMES) | ⬜ 未着手 |
| Phase D: BLE | ⬜ 未着手 |
| Phase E: 仕上げ（SPM 移植・履歴画面・一括再処理） | ⬜ 未着手 |

## まず動かす

```bash
# 解析コアのテスト（Xcode 不要。Mac の CLI だけで回る。検出器を触ったら必ず）
cd app/MokkoriCore && swift test

# 画面のテスト（シミュレータを実際に操作する。UI を触ったら必ず）
cd app/MokkoriIQ && xcodegen && xcodebuild -project MokkoriIQ.xcodeproj -scheme MokkoriIQ \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MokkoriIQUITests test

# Python 側リファレンスの回帰（Python を触ったら必ず。両方 green にすること）
.venv/bin/python analysis/regression_check.py

# iOS アプリを開く（.xcodeproj は生成物。コミットしていない）
brew install xcodegen              # 未導入なら
cd app/MokkoriIQ && xcodegen && open MokkoriIQ.xcodeproj
```

シミュレータ実行は iPhone 17 Pro で確認済み。**Xcode 26.6 は iOS 26.5 の
シミュレータランタイムが必須**（無いと destination が1つも出ず
"iOS 26.5 is not installed" になる）。`xcodebuild -downloadPlatform iOS` で入る。

## 構成

```
app/MokkoriCore/     解析エンジン（Swift Package, iOS17+/macOS14+）
  Stats            numpy 互換の median / percentile
  SwimSession      flash_dump CSV ローダ（g→m/s²・dps→rad/s、fs 推定）
  RawRecording     生データ int16 コーデック（CSV とビット同値を検証済み）
  WallDetector     turn_stand.py 移植（verticality → 分類 → デフラグ → リズムリカバリ）
  SwimReport       swim_report.py 移植（距離・ペース・セット/インターバル/ラップ）
  StrokeCounter    ラップごとストローク数（バンドパス biquad + prone ゲート ゼロクロス）
  WallOverlay      ターンの人手修正（生データ・自動検出とは分離して保存）
  WallIntervals    ラップ確認画面の行データ（見逃し/偽ターンのハイライト）
  PaceChart        ペースグラフのデータ（軸の切り方・異常値・傾向）
  MetricStyle      Apple フィットネス流の数値タイポグラフィ（アプリ側）
  StravaSummary    投稿内容の組み立て（Strava 投稿規約の実装）

app/MokkoriIQ/       iOS アプリ（SwiftUI, iPhone 専用・2タブ）
  RootView              タブ（デバイス / ログ）。MokkoriIQApp.swift の中
  DeviceSettings        振動フィードバックの設定（UserDefaults 永続化）
  SessionStore          永続化 Documents/sessions/<uuid>/{meta.json,raw.bin,overlay.json}
  SessionAnalysisModel  読込→自動検出→オーバーレイ適用→即時再計算
  StravaService         ゲートウェイ（strava.ojimpo.com）へ投稿
  Views/DeviceView      デバイスタブ（取り込み・本体の状態・メンテナンス・振動）
  Views/                一覧 → レポート → ラップ確認 / Strava アップ / 設定
```

## 用語とタイポグラフィ（2026-07-28 に総入れ替え）

「半」「レップ」「本」は自作語だったので、**Garmin 日本語 + 水泳の練習用語**に置き換えた。
**ラップ**（プールの片道25m）/ **インターバル**（レストで区切られた連続泳ぎ）/ **セット**（大休憩で
区切られた塊）/ **レスト**。コードの識別子も揃えてある（`report.laps` / `.intervals` / `.sets`）。
詳細な対応表は CLAUDE.md「用語」。**新しい語以外は使わないこと。**

レポート画面の見た目は **Apple 純正フィットネスの「ワークアウトの詳細」** に倣う
（`Views/MetricStyle.swift`）。ラベルは小さく控えめ・値は大きく色付き・単位は小さく・行は区切り線。
メトリクスの種類ごとに色（距離=青 / 時間=橙 / ペース=teal / ストローク=緑 / SWOLF=紫）。

## 移植で守るべきルール（崩すとパリティテストが割れる）

- 計算は全部 `Double`。
- `np.percentile` は linear 補間、`np.median` は偶数長で中央2値の平均（`Stats.swift`）。
- Python の `round()` は**偶数丸め** → Swift は `.rounded(.toNearestOrEven)`。
- **Python 実装を変えたら Swift 実装とテスト2種の期待値を同時に更新する**
  （`analysis/regression_check.py` と `ParityTests.swift`）。

ピン留めしてある期待値:
- 6/21: turns 35 / rests 13 / bigs 2 / 復元@724s / 500+675 = **1175m** / 47ラップ 647ストローク
- 7/28: turns 41 / rests 1 / bigs 3 / 復元@533s / 625+425 = **1050m** / 42ラップ 576ストローク
- 両セッションとも全インターバルで CROSS-CHECK 不発（min() が効かない）
- セット番号が 1 からの連番（泳ぎゼロのブロックが番号を食わない）

## 画面構成（2タブ）

**デバイス**（本体まわり）と**ログ**（一覧→レポート）。起動時はログ。Strava の設定は
設定するものがそれしか無いのでログ画面の左上のまま。

デバイスタブで**いま実際に動くのは「ログを取り込む」と「振動の設定（保存だけ）」の2つ**。
バッテリー・メモリー・時刻合わせ・メモリー消去は本体と話す必要があるので、
**「未接続」と画面に出したうえで操作を無効にしてある**（黙って空欄にしない）。
BLE が入ったら `DeviceStatus` を埋めてボタンを有効にするだけで済む形にしてある。

振動は **3パターン固定 × 発動距離の割り当て**（未設定なら鳴らない）。
「1000m 連続」以外の使い方にも効くようにこの形にした。**まだ鳴らない**: 実機に
振動モーターが載っておらず、BLE で送る仕組みも無いため。

## すぐやれる残作業（優先度順）

1. **実機 iPhone で動かす**（無料 Apple ID で可・7日で再署名）。シミュレータ限定の
   確認しかしていない。**画面の描画・遷移・ターン編集の再計算は UI テストで自動確認済み**なので、
   実機で見るのは「実際の指の操作感」と「取込の体感速度」。
2. **Strava に実投稿してみる**。設定画面に API キーを入れるだけで投稿できる状態
   （キー: `ssh arigato-nas 'grep GATEWAY_API_KEY ~/dev/strava-autopilot/.env'`）。
   疎通・トークン・Strava 到達・エラー伝搬までは検証済みだが、**実際にアクティビティを
   作るところだけ未検証**（ゴミ投稿を避けたため）。
3. **CSV インポートの実地確認**。UI テストは環境変数 `UITEST_SEED_CSV` でパスを渡して
   取り込ませている（アプリ側に種まきフックあり）。「ファイル」アプリを人が操作する
   `fileImporter` 経路だけは未実行。
4. Phase C（ファーム時刻アンカー + `TIMES`）。これが入ると手動アンカー入力が不要になる。

## 手を付けていない設計判断

- **SPM（スペクトルのストローク率）のコア移植**。`analysis/stroke_rate.py` の
  `dominant_cadence` は FFT を使うので、そのままでは Swift に持ってきづらい。
  ラップごとストローク数 ÷ ラップタイムで代用できるので、そもそも移植が要るか要検討。
- **履歴・集計画面**、**検出器更新時の一括再処理ボタン**、**修正ログの書き出し**
  （＝ラベル付き GT を Python 側チューニングへ還流）は Phase E のまま未着手。
- ラップ確認画面の**ターン追加はラップの中点固定**。任意の時刻を指定したくなったら
  波形を出して指でつまむ UI が要る（現状は「このラップの途中にターンを追加」のみ）。

## UI テストの仕組み（画面を触る作業を自動化してある）

`app/MokkoriIQ/UITests/ScreenFlowTests.swift` がシミュレータを実際に操作する。
セッションは `UITEST_SEED_CSV` に `data/swim/*.csv` のパスを渡して取り込ませる
（`SessionListView` の `.task` に種まきフックがあり、**環境変数があるときだけ**動く）。
検証しているのは「レポートの主要な数値が出る」「ラップ表が出る」
「ターンを1つ消すと距離が 25m 減り、破棄すると戻る」「ゲートウェイ未設定なら投稿ボタンが押せない」
「ペースグラフが出て、バーをタップするとラップの詳細が出る」。

**目視用のスクリーンショット**も撮れる（グラフのように数値が通っても見た目が壊れうるもの用）。
`UITEST_SCREENSHOT_DIR` を渡したときだけ書き出す。`xcodebuild` から渡すときは
**`TEST_RUNNER_` を前置**しないとシミュレータ内のテストランナーに届かない。
書き出し先は **`/Users/...` 配下**にすること（`/tmp` はシミュレータ内の tmp に落ちてホストに出てこない）。

```bash
TEST_RUNNER_UITEST_SCREENSHOT_DIR=$PWD/.shots TEST_RUNNER_UITEST_SCREENSHOT_TAG=light \
  xcodebuild -project app/MokkoriIQ/MokkoriIQ.xcodeproj -scheme MokkoriIQ \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:MokkoriIQUITests/ScreenFlowTests/testPaceChartSnapshots test
xcrun simctl ui booted appearance dark    # ダークで撮り直すとき
```

## 落とし穴メモ

- `Section("タイトル") { } footer: { }` という初期化子は SwiftUI に無い。
  `Section { } header: { } footer: { }` を使う。
- ゲートウェイは Cloudflare 越しなので、**5xx を返すと CF のエラーページに
  差し替わって理由が消える**。エラーは 4xx で返す（autopilot 側は 422 にしてある）。
- `.xcodeproj` と `Sources/Info.plist` は XcodeGen の生成物なのでコミットしない。
  設定を変えるときは `project.yml` を編集する。
- **距離の表示は必ず `fmtMeters()` を通す**。SwiftUI の `Text("\(Int(x)) m")` は
  LocalizedStringKey 扱いでロケールの桁区切りが入るが、`String` 変数に入れてから渡すと
  入らない。同じ数値が画面によって `1050 m` と `1,050 m` になっていた（2026-07-28 に統一）。
- CSV の読み取りは `FastCSV`（strtod）。`String.enumerateLines` + `Double(Substring)` に
  戻すと 16 万行で 2.3 秒（実機ではその数倍）かかる。
