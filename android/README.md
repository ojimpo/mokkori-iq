# Mokkori IQ — Android UI prototype 0.1

既存の iPhone 版を元にした **Kotlin + Jetpack Compose のネイティブ Android アプリ**です。
今回の成果物は、実機センサーなしで画面と操作の流れを確認するための、オフラインのデモ版です。
データは固定の架空サンプルです。iPhone の記録や `data/swim/` の個人ログを同梱していません。

## 今回できること

- 起動時のログ一覧 → レポート → ラップ一覧、Strava 投稿内容のプレビュー
- 距離・タイム・ペース・ストローク・SWOLF、セット/インターバルの表示
- 日本語 UI、デバイス/ログの 2 タブ、Android の戻る操作
- デモ本体から取り込み、進捗、中止、接続断、失敗、再試行、重複取込防止
- 確認ダイアログ付きの「デモメモリーを空にする」操作と復元
- 3 種類の振動パターンの距離割当・強さの端末内保存
- 元ファームの BLE v1 ステータス、コマンド、順序付きダンプ、生 int16 の Kotlin コーデック

## 今回まだできないこと

- 実機への BLE 接続、GATT 通信、時刻送信、消去、モーター駆動
- CSV 取り込み、実データの解析、iOS/Python 解析結果とのパリティ
- ターンの追加/削除と再集計
- Strava 認証、投稿、API キー保存

アプリに Bluetooth・位置情報・インターネットの権限を付けていません。
「接続状態を試す」は UI シナリオを切り替える機能で、端末の Bluetooth 設定は変えません。
「取り込み」は架空の既知セッション ID を保存します。まだ raw.bin を読み込む経路ではありません。
生データ/プロトコルのコア実装と UI のデモは分離しています。

## ビルド

前提: JDK 17、Android SDK Platform 35、Build-Tools 35.0.0。
Gradle 8.13 の Wrapper を同梱し、配布物の SHA-256 を固定しています。
Android Gradle Plugin 8.9.2 / Kotlin 2.1.20 / Compose BOM 2025.04.01 を使用します。

```sh
cd android
# ANDROID_HOME を SDK の場所へ設定するか、Android Studio でこのフォルダを開く
./gradlew :core:test :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
```

APK: `app/build/outputs/apk/debug/app-debug.apk`
アプリ ID: `com.ojimpo.mokkori.android.demo`
最低 OS: **Android 6.0 / API 23**。Galaxy S5 は OS の実際のバージョンを確認してください。
この試作のために古い OS へ合わせて依存関係を下げてはいません。
デバッグ署名の開発用 APK で、ストア公開/本番署名はしていません。

## エミュレーターで触る

1. Android Studio で `android/` を Open し、Gradle Sync を完了
2. Device Manager で一般的な Pixel の仮想端末を追加（API 35 での確認を推奨）
3. 実行構成 `app` を選び Run
4. 最初にログ一覧が開く。上部に常時「デモモード」と表示

このプロトタイプの受け渡しに、クラウド上の操作可能なエミュレーター配信は含まれません。
ソースを手元の Android Studio で実行するか、APK を対応 Android 端末で使います。

## 試してほしい操作

1. ログを開く → レポート → ラップ → 戻るを 2 回。ログ一覧へ戻る
2. デバイスタブ → デモログを取り込む → 完了を閉じる → ログが 3 件になる
3. もう一度取り込む → 3 件のまま。重複は作られない
4. 取り込み中に中止する/未接続へ切り替える → 未完成のログは増えない
5. 「転送エラーを試す」をオン → 取り込みが失敗 → 再試行で成功
6. デモメモリー消去を開いて「やめる」→ 中身は残る。「空にする」→ 既存ログは残る
7. 振動パターン 1 を 100m ごとに設定 → アプリを終了して開く → 設定が残る
8. Strava プレビュー → 投稿できないことを確認

## 構成と移植の根拠

- `app/`: Android UI、デモ状態管理、SharedPreferences 保存、UI/状態テスト
- `core/`: Android 非依存のモデル・BLE/raw.bin コーデック・固定サンプル・単体テスト
- `core/README.md`: バイト仕様、厳密な受信条件、移植済/未移植の境界
- `VERIFICATION.md`: 実際に実行した検証結果

基準コミット: `2d62eabeadcdc6730c39efd129d703911f55026b`（既存 iPhone 版）
参照: `../docs/app_handoff.md`、`../CLAUDE.md`、`../app/MokkoriIQ/Sources/`、
`../app/MokkoriCore/Sources/`、`../firmware/flash_logger/`。
既存 iPhone コードとファームは変更していません。

次の移植順は、解析エンジンの Swift/Python パリティ → ローカル raw/CSV 保存 → BLE GATT →
実機での中断/再試行検証 → Strava です。UI だけの値を実測として保存/投稿しない境界を維持します。
