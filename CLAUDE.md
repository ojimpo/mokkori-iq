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
- tools/ : ホスト側ツール (pyserial)。serial_capture.py = ストリーム取得/検証、flash_dump.py = フラッシュ記録の吸い出し/変換、flash_gui.py = flash_dump を包む大ボタンGUI(Tkinter)

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

# フラッシュ記録版 (ビルド/書込は上の firmware/imu_bringup を firmware/flash_logger に置換)
PATH=".venv/bin:$PATH" arduino-cli compile --fqbn Seeeduino:nrf52:xiaonRF52840Sense firmware/flash_logger
PATH=".venv/bin:$PATH" arduino-cli upload -p /dev/cu.usbmodem112101 --fqbn Seeeduino:nrf52:xiaonRF52840Sense firmware/flash_logger
.venv/bin/python tools/flash_dump.py --selftest 5         # ベンチ往復テスト
.venv/bin/python tools/flash_dump.py --pull data/swim/session01.csv   # 1泳ぎ吸い出し→保存→消去
.venv/bin/python analysis/explore_swim.py data/swim/session01.csv     # 信号＋検出器を可視化

# 取込GUI (更衣室ロッカー内でUbuntuタブレット運用想定。大ボタン: PULL/INFO/ERASE)
.venv/bin/python tools/flash_gui.py        # Ubuntuは事前に sudo apt install python3-tk
```

# 取込ホストは Ubuntu タブレット (更衣室のロッカー内で運用)。Linuxポートは /dev/ttyACM*。
# シリアルアクセスに dialout グループ必須: sudo usermod -aG dialout $USER → 再ログイン。
# venv はタブレット側で作り直す (macOSの.venvは流用不可)。

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
- QSPI フラッシュ(P25Q16H, 2MB, jedec 0x856015): `flash.begin()` の autodetect では拾えない →
  明示デバイス `SPIFlash_Device_t dev = P25Q16H; flash.begin(&dev,1)` でフォールバック必須（flash_logger で対応済み）
- LED: RED=11 / GREEN=13 / BLUE=12（active low）。VBUS 検出= `NRF_POWER->USBREGSTATUS`

### firmware/imu_bringup
LSM6DS3TR-C を 104Hz で読み `millis,ax,ay,az,gx,gy,gz` を USB CSV 出力（acc±8g, gyro±2000dps）。`tools/serial_capture.py` で検証。

### firmware/flash_logger
プール実データ採取用。**VBUS にライブ追従**（リセット不要）: USB抜く=記録 / USB挿す=コンソール。
これで「短く泳ぐ→更衣室でMacに挿して吸い出し→また泳ぐ」ループが成立。
- 記録は**追記方式**。消去は明示 `ERASE` のみ（USBを抜いても自動消去しない＝うっかりデータ消失なし）
- 6軸 int16 を 256B ページ（magic 0xA55A/count/seq + 20 sample）で QSPI に書込。52Hz で約52分／消去まで
- LED: 消去=青 / 記録=緑点滅 / コンソール=赤 / 満杯=赤点滅
- コンソールコマンド: `INFO` / `DUMP` / `ERASE` / `TESTLOG <sec>`（USB中でも追記、ベンチ用）/ `HELP`
- `tools/flash_dump.py`: `--pull [PATH]`（DUMP→CSV保存→ERASE を1コマンド＝1泳ぎ分。PATH省略で data/swim/ に自動命名）/
  `--info` / `--erase` / `--testlog N` / `--selftest N`（ベンチ往復）。生int16を g/dps に変換
- 検証済(2026-06-03): TESTLOG 2s×2で 105→210（追記）、`--pull` で保存＆消去、|acc|=1.03g、往復整合

### 実データ取込 (device CSV → Phase 0)
- `dataio.load_swim_csv(path)`: flash_dump CSV を session dict 化。**g→m/s²・dps→rad/s に変換**（Brunner/検出器閾値の単位に合わせる）、fs は t から自動推定
- `preprocessing.make_config_for_fs(fs)`: biquad LP を fs 用に再設計（default.json は30Hz用。52Hz等で検出器をネイティブ実行）。30Hz指定で既存係数を完全再現する
- `analysis/explore_swim.py <csv>`: 信号(|acc|/activity＋閾値/|gyro|)をプロットし、手首チューニング検出器の検出を重ねて `analysis/fig_swim_*.png` 出力

### 次段
プールで股間装着の実データ採取 → 上記で取込・可視化 → 検出器を実信号で再チューニング → C 移植。
注意: Phase 0 検出器は「手首/30Hz」チューニング。股間装着は信号が別物なので、いきなり C 移植せず実データ採取が先。

## パラメータ変更
config/default.json を編集して .venv/bin/python src/evaluate.py で再評価。
チューニング履歴: analysis/tune.py 〜 tune5.py（グリッドサーチ）。

## 注意事項
- data/brunner/ は .gitignore 済み。初回は上記の git clone が必要
- detector.py 内で x ** 0.5 (sqrt) を使用。C移植時は sqrtf() に置換
- analysis/ の図 (fig_*.png) はコミットに含まれている（再生成も可能）
