# mokkori-iq

## プロジェクト概要
水着に仕込む DIY スイムトラッカーのターン検知アルゴリズム開発。
Phase 0 は公開データセット（Brunner et al., 手首装着 30Hz）での Python プロトタイプ。
Phase 1 は実機 XIAO nRF52840 Sense（股間装着）への移植と実データ採取（firmware/）。

## 技術スタック
- Python 3.9+ / venv (.venv/)
- numpy, scipy, pandas, matplotlib (requirements.txt)
- データ: data/brunner/ (Brunner リポジトリの shallow clone、.gitignore 済み)

## ディレクトリ構成
- src/ : コアモジュール (dataio, preprocessing, detector, lap_logger, evaluate)
- config/default.json : 検出器パラメータ（閾値・窓長・フィルタ係数）
- analysis/ : 探索スクリプト・チューニングスクリプト・生成図・findings.md
- results/ : 評価結果 CSV（セッション別・被験者別）
- firmware/ : 実機ファーム (Arduino/Seeed nRF52)。imu_bringup = IMU ブリングアップ
- tools/ : ホスト側ツール。serial_capture.py = シリアル取得/検証 (pyserial)

## コマンド
```bash
# 環境構築
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt

# データ取得
git clone --depth 1 https://github.com/brunnergino/swimming-recognition-lap-counting.git data/brunner

# 全泳法評価
.venv/bin/python src/evaluate.py --all-styles

# 自由形のみ
.venv/bin/python src/evaluate.py --style Freestyle

# 探索的分析
.venv/bin/python analysis/explore_turns.py

# --- 実機ファーム (Phase 1) --- ※すべてリポジトリルートで実行
# ビルド & 書き込み (venv の bin を PATH 先頭に: コアのビルド後処理が python を呼ぶため)
PATH=".venv/bin:$PATH" arduino-cli compile --fqbn Seeeduino:nrf52:xiaonRF52840Sense firmware/imu_bringup
PATH=".venv/bin:$PATH" arduino-cli upload -p /dev/cu.usbmodem112101 --fqbn Seeeduino:nrf52:xiaonRF52840Sense firmware/imu_bringup

# IMU ストリームの取得/検証 (サンプルレート・各軸レンジ・重力チェック)
.venv/bin/python tools/serial_capture.py -s 6
```

## アーキテクチャ
- 検出器 (src/detector.py): Causal FSM (SWIM→DIP→CONFIRM→EMIT)
  - update(ax,ay,az) で1サンプルずつストリーミング処理（MCU移植前提）
  - 適応閾値: ピークフォロワーで「最近の泳ぎ活動」を追跡し、比率で閾値設定
  - CONFIRM 状態: 壁タッチ後に泳ぎが持続再開したらターン確定（セット終わりの誤検出防止）
- 前処理 (src/preprocessing.py): Causal biquad LP + trailing rolling std
  - Biquad / RollingStd クラスは MCU 移植可能（O(1)/O(W) メモリ）
- 評価 (src/evaluate.py): GT ターン窓との greedy distance matching → P/R/F1 + ラップログ精度

## ファームウェア (Phase 1, 実機)
- ツールチェーン: arduino-cli + Seeed nRF52 コア (`Seeeduino:nrf52@1.1.13`、UF2ブートローダ)
  - board index URL: https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json
  - FQBN: `Seeeduino:nrf52:xiaonRF52840Sense` / IMU ライブラリ: `Seeed Arduino LSM6DS3`
- 落とし穴: コアのビルド後処理が `python` を呼ぶが macOS は `python3` のみ → `exec: "python"... not found` で失敗。
  上のコマンドのように venv の bin (`python`→python3 シンボリックリンク) を PATH 先頭に通す。compile/upload 両方で必要
- Sense の IMU/mic はスイッチ電源レール: `PIN_LSM6DS3TR_C_POWER (=15)` を HIGH にしないと応答しない（firmware で対応済み）
- firmware/imu_bringup: LSM6DS3TR-C を 104Hz で読み `millis,ax,ay,az,gx,gy,gz` を USB CSV 出力（acc±8g, gyro±2000dps）
- 次段: QSPI フラッシュ記録版ファーム → プールで股間装着の実データ採取 → 検出器を実信号で再チューニング
  - 注意: Phase 0 検出器は「手首/30Hz」チューニング。股間装着は信号が別物なので、いきなり C 移植せず実データ採取が先

## パラメータ変更
config/default.json を編集して .venv/bin/python src/evaluate.py で再評価。
チューニング履歴: analysis/tune.py 〜 tune5.py（グリッドサーチ）。

## 注意事項
- data/brunner/ は .gitignore 済み。初回は上記の git clone が必要
- detector.py 内で x ** 0.5 (sqrt) を使用。C移植時は sqrtf() に置換
- analysis/ の図 (fig_*.png) はコミットに含まれている（再生成も可能）
