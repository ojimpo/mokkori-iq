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
  SwimReport       swim_report.py 移植（距離・ペース・レップ・本ごとメトリクス）
  StrokeCounter    本ごとストローク数（バンドパス biquad + prone ゲート ゼロクロス）
  WallOverlay      壁の人手修正（生データ・自動検出とは分離して保存）
  WallIntervals    確認画面の行データ（見逃し/偽壁ハイライト）
  StravaSummary    投稿内容の組み立て（Strava 投稿規約の実装）

app/MokkoriIQ/       iOS アプリ（SwiftUI, iPhone 専用）
  SessionStore          永続化 Documents/sessions/<uuid>/{meta.json,raw.bin,overlay.json}
  SessionAnalysisModel  読込→自動検出→オーバーレイ適用→即時再計算
  StravaService         ゲートウェイ（strava.ojimpo.com）へ投稿
  Views/                一覧 → レポート → 壁インターバル確認 / Strava アップ / 設定
```

## 移植で守るべきルール（崩すとパリティテストが割れる）

- 計算は全部 `Double`。
- `np.percentile` は linear 補間、`np.median` は偶数長で中央2値の平均（`Stats.swift`）。
- Python の `round()` は**偶数丸め** → Swift は `.rounded(.toNearestOrEven)`。
- **Python 実装を変えたら Swift 実装とテスト2種の期待値を同時に更新する**
  （`analysis/regression_check.py` と `ParityTests.swift`）。

ピン留めしてある期待値:
- 6/21: turns 35 / rests 13 / bigs 2 / 復元@724s / 500+675 = **1175m** / 47本 647ストローク
- 7/28: turns 41 / rests 1 / bigs 3 / 復元@533s / 625+425 = **1050m** / 42本 576ストローク
- 両セッションとも全レップで CROSS-CHECK 不発（min() が効かない）

## すぐやれる残作業（優先度順）

1. **実機 iPhone で動かす**（無料 Apple ID で可・7日で再署名）。シミュレータ限定の
   確認しかしていない。
2. **Strava に実投稿してみる**。設定画面に API キーを入れるだけで投稿できる状態
   （キー: `ssh arigato-nas 'grep GATEWAY_API_KEY ~/dev/strava-autopilot/.env'`）。
   疎通・トークン・Strava 到達・エラー伝搬までは検証済みだが、**実際にアクティビティを
   作るところだけ未検証**（ゴミ投稿を避けたため）。
3. **CSV インポートの実地確認**。シミュレータではコンテナに直接ファイルを置いて
   確認した。「ファイル」アプリ経由の `fileImporter` 経路は未実行。
4. Phase C（ファーム時刻アンカー + `TIMES`）。これが入ると手動アンカー入力が不要になる。

## 手を付けていない設計判断

- **SPM（スペクトルのストローク率）のコア移植**。`analysis/stroke_rate.py` の
  `dominant_cadence` は FFT を使うので、そのままでは Swift に持ってきづらい。
  本ごとストローク数 ÷ 本タイムで代用できるので、そもそも移植が要るか要検討。
- **履歴・集計画面**、**検出器更新時の一括再処理ボタン**、**修正ログの書き出し**
  （＝ラベル付き GT を Python 側チューニングへ還流）は Phase E のまま未着手。
- 壁インターバル画面の**壁追加はギャップ中点固定**。任意の時刻を指定したくなったら
  波形を出して指でつまむ UI が要る（現状は「この前のギャップに壁を追加」のみ）。

## 落とし穴メモ

- `Section("タイトル") { } footer: { }` という初期化子は SwiftUI に無い。
  `Section { } header: { } footer: { }` を使う。
- ゲートウェイは Cloudflare 越しなので、**5xx を返すと CF のエラーページに
  差し替わって理由が消える**。エラーは 4xx で返す（autopilot 側は 422 にしてある）。
- `.xcodeproj` と `Sources/Info.plist` は XcodeGen の生成物なのでコミットしない。
  設定を変えるときは `project.yml` を編集する。
