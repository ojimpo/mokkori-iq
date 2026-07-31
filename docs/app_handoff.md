# mokkori-iq アプリ開発 引き継ぎメモ (2026-07-31 時点)

次のセッションはこれを読めば続きから入れる。全体計画は `docs/phase2_app_plan.md`、
プロジェクト全体の約束事は `CLAUDE.md`。**Phase A〜D のコードは完成していて、
残りは Phase E と、本体側のコーザル壁カウンタ（振動を鳴らすのに要る）**。

## 30秒でわかる現状

| | 状態 |
|---|---|
| Phase A: 解析エンジンの Swift 移植 + 確認画面 | ✅ 完了（パリティテスト green） |
| Phase B: Strava アップロード | ✅ 実装完了（**実投稿だけ未テスト**） |
| Phase C: ファーム時刻アンカー (TIME/TIMES) | ✅ 完了（実機で往復検証済み） |
| Phase D: BLE | ✅ 完了（吸い出し・時刻合わせ・消去・振動テスト） |
| Phase E: 仕上げ（SPM 移植・履歴画面・一括再処理） | ⬜ 未着手 |

**デバイスタブはもう全部動く。** 本体は電源が入っていれば常時アドバタイズしているので、
タブを開けば勝手に繋がる。タブレットでの吸い出しはもう要らない（CSV 取り込みは過去ぶん用に残してある）。

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

# 実機 iPhone に入れる（署名は project.yml に入れてある。UDID は devicectl list devices）
xcodebuild -project MokkoriIQ.xcodeproj -scheme MokkoriIQ \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> \
  ~/Library/Developer/Xcode/DerivedData/MokkoriIQ-*/Build/Products/Debug-iphoneos/MokkoriIQ.app
xcrun devicectl device process launch --device <UDID> com.ojimpo.mokkori-iq
```

シミュレータ実行は iPhone 17 Pro で確認済み。**Xcode 26.6 は iOS 26.5 の
シミュレータランタイムが必須**（無いと destination が1つも出ず
"iOS 26.5 is not installed" になる）。`xcodebuild -downloadPlatform iOS` で入る。

実機は 2026-07-31 に確認済み（起動・遷移・CSV 取込の体感速度とも問題なし）。
無料 Apple ID の Personal Team なので**署名は7日で切れる**。手順と落とし穴
（ペアリング・デベロッパApp の信頼・USB 確認）は CLAUDE.md「実機 iPhone に入れる」。

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
  BLEManager            本体との BLE（自動接続・状態・時刻合わせ・吸い出し・消去・振動）
  DeviceSettings        振動フィードバックの設定（UserDefaults 永続化）+ DeviceStatus
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

デバイスタブは BLE で本体と繋がるので**全項目が動く**: バッテリー・メモリー残量・
時刻合わせ・メモリー消去（確認ダイアログ付き）・**本体から直接吸い出し**・振動の体感テスト。
繋がっていないときは**理由を画面に出す**（Bluetooth オフ／未許可／さがしています）。
CSV 取り込みはタブレットで吸い出した過去ぶんのために残してある。

振動は **3パターン固定 × 発動距離の割り当て**（未設定なら鳴らない）。
「1000m 連続」以外の使い方にも効くようにこの形にした。設定の送信と体感テスト（▶ボタン）は
動くが、**泳いでいる最中はまだ鳴らない**: 実機に振動モーターが載っていない（配線が未実装）のと、
距離を数える**コーザルな壁カウンタが本体側に無い**ため。

## 吸い出しの中身（BLE と CSV が一致する理由）

BLE で届くのは `raw.bin` と同じ **int16 の並び**なので、`SessionStore.persist()` で
CSV 経路と合流させてある。片方だけ挙動が変わる事故が起きない。
フレームには**絶対サンプル番号**が入っているので、穴や途中切断は**エラーとして出る**
（途中までのデータを「それらしい短いセッション」として保存しない）。
本体に時刻アンカーがあれば `startEpoch` が自動で入り、Strava アップ時の手入力が要らなくなる。

## すぐやれる残作業（優先度順）

1. **Strava に実投稿してみる**。設定画面に API キーを入れるだけで投稿できる状態
   （キー: `ssh arigato-nas 'grep GATEWAY_API_KEY ~/dev/strava-autopilot/.env'`）。
   疎通・トークン・Strava 到達・エラー伝搬までは検証済みだが、**実際にアクティビティを
   作るところだけ未検証**（ゴミ投稿を避けたため）。
2. **本体側のコーザル壁カウンタ**（ファーム）。これが入って振動モーターを配線すれば、
   距離ベースの振動フィードバックが初めて鳴る。設計メモは CLAUDE.md「距離ベース振動フィードバック」。
   解析側のリズムリカバリ／デフラグ／min() は**非コーザル**なのでそのままでは使えない。
3. Phase E（SPM 表示・履歴画面・検出器更新時の一括再処理・修正ログの書き出し）。

CSV インポートは 2026-07-31 に実地確認済み（AirDrop → 「ファイル」→ デバイスタブの
「ログを取り込む」。16万行でも体感で待たされない）。UI テストのほうは環境変数
`UITEST_SEED_CSV` でパスを渡して取り込ませている（アプリ側に種まきフックあり）。

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
「ペースグラフが出て、バーをタップするとツールチップにラップの詳細が出る
（遅いラップで左へ折り返してもグラフからはみ出さない・もう一度タップで解除）」。

**グラフのタップは `tapChart()` を通すこと。** グラフは 1ラップ 12pt で伸びるので
画面より高くなり、`coordinate(withNormalizedOffset: dy: 0.5)` が画面外を指して
タップが無効になる（黙って何も起きないので原因が分かりにくい）。`tapChart` は
「画面に見えているグラフの範囲」から dy を逆算する。

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
