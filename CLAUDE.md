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
- DEVLOG.md : 作業日誌 (Cosense「mokkori-iq 進捗ログ」のミラー)

## 作業日誌の運用 (2026-07-11 開始、pulse-pump と同じ)
作業のたびに **DEVLOG.md と Cosense「mokkori-iq 進捗ログ」の両方**へ時刻付きエントリで記録する
（日付見出し → `HH:MM タイトル` → 詳細箇条書き。判断理由・ハマり・知見まで詳細に残す）。
Claude Code はひと区切りごとに自発的に追記すること。過去の経緯（〜2026-07-10）は本ファイルと git log 参照。

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
# ※必ず $PWD 付きの絶対パスで。相対 PATH だと Go の exec 制約で
#   "cannot run executable found relative to current directory" になる (2026-07-11 確認)
PATH="$PWD/.venv/bin:$PATH" arduino-cli compile --fqbn Seeeduino:nrf52:xiaonRF52840Sense firmware/imu_bringup
PATH="$PWD/.venv/bin:$PATH" arduino-cli upload -p /dev/cu.usbmodem112101 --fqbn Seeeduino:nrf52:xiaonRF52840Sense firmware/imu_bringup

# IMU ストリームの取得/検証 (サンプルレート・各軸レンジ・重力チェック)
.venv/bin/python tools/serial_capture.py -s 6

# フラッシュ記録版 (ビルド/書込は上の firmware/imu_bringup を firmware/flash_logger に置換)
PATH="$PWD/.venv/bin:$PATH" arduino-cli compile --fqbn Seeeduino:nrf52:xiaonRF52840Sense firmware/flash_logger
PATH="$PWD/.venv/bin:$PATH" arduino-cli upload -p /dev/cu.usbmodem112101 --fqbn Seeeduino:nrf52:xiaonRF52840Sense firmware/flash_logger
.venv/bin/python tools/flash_dump.py --selftest 5         # ベンチ往復テスト
.venv/bin/python tools/flash_dump.py --pull data/swim/session01.csv   # 1泳ぎ吸い出し→保存→消去
.venv/bin/python analysis/explore_swim.py data/swim/session01.csv     # 信号＋検出器を可視化

# 一発レポート (取込済みCSV → 距離/ペース/レップ内訳/SPM/Strava用サマリ)
.venv/bin/python analysis/swim_report.py data/swim/session01.csv --date 2026-06-21
.venv/bin/python analysis/turn_stand.py  data/swim/session01.csv   # gz壁検出の可視化(図)
.venv/bin/python analysis/regression_check.py   # 検出器/レポート変更後は必ず実行 (全セッションの疑似GT回帰、2/2 PASS必須)
.venv/bin/python analysis/stroke_rate.py data/swim/session01.csv   # ストローク率の可視化(図)

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
- コンソールコマンド: `INFO` / `DUMP` / `ERASE` / `TESTLOG <sec>`（USB中でも追記、ベンチ用）/ `VIB [ms] [pct]` / `HELP`
- **振動モーター対応 (2026-07-11、実機未検証)**: コイン型 ERM（JYUDAUFU 10mm×2.7mm、定格3V/最大80mA、Amazon 20個入）を
  D10 の低サイド BSS138 で駆動。回路: 3V3→モーター(+) / モーター(−)→BSS138ドレイン / ソース→GND /
  D10→(100Ω〜1kΩ)→ゲート / ゲート→(100kΩ)→GND プルダウン / 1N4148 をモーター両端に並列（カソード=3V3側）。
  D10 は右側ヘッダで 3V3/GND と同列＝ユニバーサル基板の配線が片側で済む。制御は `analogWrite` 統一（duty 可変）。
  `VIB` はベンチ体感テスト用。**記録中は 60s ごとにダブルパルス**（200ms×2、`BUZZ_PERIOD_S` で変更・0で無効）＝
  水中で筐体＋水着越しの体感を採取と同時に検証する仕掛け。既知タイミングなので IMU データから識別・除外可能
- `INFO` はバッテリも出す: `# vbat_mv=4015 pct=82 charging=1`。VBAT(P0.31)を VBAT_ENABLE(P0.14)=LOW で接続し、
  3.0V内部参照/12bit/16回平均で読む。分圧比は variant の 1M/0.51M（`VBAT_DIVIDER`≈2.96）。専用の充電ステータスGPIOは無いので
  `charging` は VBUS有り＆mv<4150 で導出（=満充電なら0）。主用途は「充電完了したか＋挿した直後の概算残量」。
  分圧比がズレてたら実機をテスタで測って `VBAT_DIVIDER` を補正する（ビルドは通過済み、書込・実測検証は未）。
- `tools/flash_dump.py`: `--pull [PATH]`（DUMP→CSV保存→ERASE を1コマンド＝1泳ぎ分。PATH省略で data/swim/ に自動命名）/
  `--info` / `--erase` / `--testlog N` / `--selftest N`（ベンチ往復）。生int16を g/dps に変換。`--info`/GUIはバッテリ行も表示
- 検証済(2026-06-03): TESTLOG 2s×2で 105→210（追記）、`--pull` で保存＆消去、|acc|=1.03g、往復整合

### 実データ取込 (device CSV → Phase 0)
- `dataio.load_swim_csv(path)`: flash_dump CSV を session dict 化。**g→m/s²・dps→rad/s に変換**（Brunner/検出器閾値の単位に合わせる）、fs は t から自動推定
- `preprocessing.make_config_for_fs(fs)`: biquad LP を fs 用に再設計（default.json は30Hz用。52Hz等で検出器をネイティブ実行）。30Hz指定で既存係数を完全再現する
- `analysis/explore_swim.py <csv>`: 信号(|acc|/activity＋閾値/|gyro|)をプロットし、手首チューニング検出器の検出を重ねて `analysis/fig_swim_*.png` 出力
- **`analysis/swim_report.py <csv> [--date ...] [--verbose]`**: **取込CSV→一発で距離/ペース/レップ内訳/SPM/Strava用サマリ**を出力（デバイスの完成形出力）。
  検出は `turn_stand.detect_walls`（gz壁検出）を共有、ケイデンスは `stroke_rate.dominant_cadence` を再利用。
  クロスチェック: 各レップ `本数 = min(壁カウント, round(泳ぎ時間/標準レングス時間))`。標準レングス時間は「ターン間の泳ぎ実時間(立位除外)」の中央値で、
  分子(泳ぎ時間)と単位を揃える。独立2系統の一致確認で、食い違ったら `CROSS-CHECK` 行で警告（[メトリクス算出方針]＝精度優先）。
- `analysis/turn_stand.py` / `stroke_rate.py`: それぞれ gz壁検出・ストローク率の可視化図を出力（detect_walls / dominant_cadence の出どころ）。

### タブレット運用 & 引き継ぎ (Phase 1 データ採取)
データ吸い出しは更衣室ロッカー内で **Ubuntu タブレット**運用。引き継ぎ情報は
（Claude のメモリは端末ローカルで共有されないため）この CLAUDE.md とリポジトリに集約する。

**現在の状態 (2026-06-21 時点)**
- 実機: マイコン+LiPo+スイッチ半田付け完了。組立後の往復セルフテスト合格（5s/260samples/|acc|=1.013g）。
  フラッシュは消去済み（0 samples、プール投入可）。充電は赤い充電LEDが消えれば満充電。
- ファーム正常動作確認: USB有り=コンソール(赤)/USB無し=記録(緑点滅)。LED-A=RGBユーザーLED(ファーム), LED-B=緑の電源系インジケータ。
- 実データはまだ未採取（data/swim/ は空、README のみ）。次は「プールで採取 → 吸い出し → 可視化」。
- 取込タブレット(Ubuntu/Python3.13)セットアップ済(2026-06-21): python3.13-venv/python3-tk導入、.venv作成＋依存導入(pyserial含む)、GUI起動(画面表示)確認。
  **未了**: `sudo usermod -aG dialout $USER` → 再ログイン と、実機データケーブル直挿しでの疎通(INFO)。これが済めば採取運用に入れる。

**タブレット初回セットアップ（家で済ませる）**
```bash
git pull                                                    # GUI・Linux対応・本セクションを取得
sudo apt install python3-venv python3-tk                    # venv作成(ensurepip)とTkinterに必須。素のpython3はvenv不可(Ubuntu/3.13は python3.13-venv)
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt   # venvは端末ごとに作り直す。pyserial含む
sudo usermod -aG dialout $USER                              # シリアル権限 → 実行後に再ログイン必須
.venv/bin/python tools/flash_gui.py                         # デバイス直挿しで INFO が出れば疎通OK
```

**吸い出し → 共有フロー**
- 採取: USB抜く=記録(緑点滅) → 泳ぐ → タブレットに直挿し(赤) → GUI「吸い出して保存」(=PULL: DUMP→CSV→ERASE)
- 共有: `git add data/swim/ && git commit && git push` → Mac で `git pull` → `analysis/explore_swim.py` で可視化
- 保存先 data/swim/ は .gitignore 対象外で追跡可（端末間共有方針）。ファイル名は日時付きで衝突しない。

**鉄則**
- 吸い出しは**データ対応ケーブル＋直挿し**必須。ドック/ハブ/充電専用ケーブルは VBUS は通すがデータ線が通らず、
  シリアルポートが出ない（ioreg で AppleUSBSerial=0）。「充電できる≠データ通る」。本番ケーブルは家で INFO 確認済みの1本を専用化。
- Linux のシリアルポートは /dev/ttyACM*（autodetect 対応済み）。出なければ `-p /dev/ttyACM0`。

### データ採取手順 (プール)
**装着の向き**: SeeedStudio 印字面 = 外側（水着側）／ USB-C 端子 = 上。毎回この向きにそろえ、セッションメモにも記録する。
- 現行検出器は |acc|/activity ベースで**向き不変**なので向きを変えても壊れないが、将来の軸別解析・筐体変更に備えて向きは残す。
  静止区間の重力ベクトル（どの軸が±1g か）からも事後復元できる。

**1セッション = 1連続記録**（追記方式）。間を 3タップで区切り、最後にまとめて1回吸い出す（更衣室往復は不要）。
1. スイッチ ON → **緑点滅（記録中）を目視確認** → 股間に仕込む（装着後は LED が見えないので、確認は装着前に必須）
2. 壁で静止 → **3タップ（はっきり等間隔）** → ストップウォッチ開始 → 1本目
3. 「壁で3タップ → 1本/セットを泳ぐ → 壁で3タップ」を繰り返す。各境界の時刻と内容をスマホにメモ（タップ=境界アンカー、メモ=意味）
4. 最後に 3タップ → 上がってスイッチ OFF
5. 更衣室でタブレットに**データ対応ケーブルで直挿し** → GUI で吸い出し（1ファイル）→ push

**制約・コツ**
- ON 合計 ≤ 約52分（休憩中も記録が回る。超えると満杯停止＝データは保全されるがそれ以降は録れない）
- タップは必ず**壁で静止して**打つ（泳ぎの加速度に埋もれさせない）。**水中で打つと jerk が泳ぎに埋もれて復元不能**
  （初回採取で実証）。**足をついて立位で**打つと、立位の gz スイング上の三連ブリップとして拾える見込み（turn_stand.py が gz 領域でタップ三連を検出）。
- 休憩区間がデータに入るのは、セット終わりの誤検出抑制（CONFIRM 状態）を実信号で検証できるので好都合

### 初プール採取の所見 (2026-06-21, swim_20260621_171349.csv)
初の股間装着実データ（46.3分/52Hz/|acc|≒1g健全）。**重力ベクトル z 成分**が壁検出の鍵と判明。
- **この泳者の泳ぎ方（検出の前提・実物）**: クイックターン不可＝**オープンターン**で毎回足を底につけて立ってから壁を蹴る。
  **100mごとの休憩は水から上がらず数秒だけ静止してトントン(3タップ)→すぐ蹴り出す**（プール内に立ったまま）。
  **ベンチに座る長休憩はハーフ間の1回だけ**（数分、前後に約10秒の立位/歩行で出入り）。狙いは 100m×5×2＝1000mを大休憩で半分割。ペース≒30s/25m。
  実際の泳ぎ方の詳細は **`data/swim/swim_20260621_171349.notes.md`**（セッション記録＝疑似GT）。
- **gz オリエンテーション検出 (`analysis/turn_stand.py`)**: 立位/着座で体軸が垂直化し、重力 z が
  **泳ぎ -7.5 ↔ 立位 +9.5 m/s²** に振れる。これが最も明確な壁シグネチャ（グライドギャップ/フリップ回転は弱く不適）。
  gz>2 の立位エピソードを分類: ピークgz>5 で「半立ち/水中ボビング」を除外、不応期12s。
  turn(1.2-7s)=途中ターン壁 / rest(7-90s)=**100m境界(水中の数秒静止+トントン)** / big-rest(>90s)=ハーフ分割。lengths = walls+1。
- **境界は2信号で立つ（実証）**: 立位エピソードの継続時間を見ると、**途中ターン≒3秒(タップ無し)** と **100m境界≒7-17秒(トントン有り)**
  に明確に分離。本人体感は「数秒」でも、減速+静止+トントン+蹴り出しを含むので境界は実際7-17s＝途中ターンより長い。
  → だから前半が綺麗に100mへ割れた。**トントンは無駄でなく有効**（立位ゲートをかけると jerk 三連が長い静止と一致、901/938s等で復元）。
- **結果(当時)**: 半1 ≒100/100/100/175m, 半2 ≒100/325(連続)/50/200m。合計 ≒**1150m**。
  → 現行検出器では 半1 500m / 半2 675m ＝ **1175m**（連続325mが立ち休止で分割される）。
  弱点: 後半の連続325m区間は止まらない＝境界信号が原理的に無く「何本目か」は不明（距離はカウント可）。
- **外部GTが無い問題**: プールにスマホ持込不可＋本人も覚えていられない＝**トントンが唯一のGT機構**。
  → 検出は内的整合性（等間隔性）+妥当ペース+本人の事後記録(notes)で検証。トントンは水中でも「立って静止して」打てば gz+jerk で拾える。
- ~~注意: gz が効くのは装着向き前提~~ → **向き非依存化 実装済み (2026-07-28)**: `turn_stand.verticality()` がセッション内で
  自己キャリブレーション（泳ぎ姿勢=高ジャイロ活動の重力中央値、立位姿勢=短い反復立ちエピソードのピーク重力中央値）し、
  泳ぎ→立位軸への射影を旧 gz スケール（泳ぎ−7.5↔立位+9.5）へ正規化。既存の閾値・分類はそのまま。
  ポイント: 射影軸は**壁立ちにアンカー**する（座位は偏差がより大きいが方向が違い、座位軸に射影すると壁立ちが埋もれる）。
  トレードオフ: 射影シグナルでは3タップのブリップが立ちエピソードに融合し、**タップ三連の復元は失われた**
  （6/21セッションの 901/938s も出なくなった。必要になったら立ちエピソード内の jerk ドメインで再実装）。
  旧セッションの距離は不変（475/675/計1150m）だが、半2の「連続325m」が 7〜26秒の立ち休止で分割されるようになった
  （3軸射影の方が斜め立ちを正しく拾うため。どちらが真かは外部GT無しで未確定）。
- **ストローク率(SPM)も計測可 (`analysis/stroke_rate.py`)**: 股間は体ロールのリズムが乗る。泳ぎ区間でジャイロのロール軸の
  スペクトルピーク＝**ストロークサイクル率**。本セッションは両半とも安定して **30 cyc/min（≒60 arm strokes/min）**。
  3手法一致（窓FFT29/自己相関28-29/トラッカー30）。注: |acc|/|gyro| は整流で2倍/4倍harmonicsが出るので符号付き単軸で取る。
  8s窓だと分解能0.125Hz=7.5cyc/min刻みに量子化（精度要るなら自己相関/放物線補間/長窓）。当初想定外だがログとして有用。

### 2回目プール採取の所見 (2026-07-28, swim_20260728_153415.csv)
装着向きを**無造作に入れた**セッション（52.5分でフラッシュ満杯＝赤点滅停止。シャワーまで記録を回したため）。
詳細は `data/swim/swim_20260728_153415.notes.md`。
- 泳ぎ2ブロック: **625m（本人の感覚カウントと完全一致）+ 425m、レポート合計 1050m**・ペース≒1:58/100m・SPM 30（前回と同値）。
  間に市民プールの休憩時間（ベンチ着座 約10分）。
- この採取が向き非依存化（`verticality()`）の直接の動機。壁立ちは約30秒間隔で極めて等間隔＝内的整合性が強い。
- 入水前（7.5分）とシャワー・更衣（2430s以降）の偽ブロックは swim_report の保守ルールが正しく除外。

### リズムリカバリ & 疑似GT回帰ハーネス (2026-07-28)
- **リズムリカバリ (`detect_walls` 内)**: ブロック内の壁は準等間隔という事前分布を利用。泳ぎギャップ（前の立ち終わり→次の立ち始まり、
  立位時間除外）が中央値の1.6〜2.6倍で、かつ中間に閾値未満の明確な姿勢変化（verticality>0 ≈ スイングの45%超、泳ぎノイズ −7.5±1.5 から遠い）が
  ある場合のみ1壁補完。両セッションの既知の取りこぼし各1（6/21@724s ピーク3.5、7/28@533s 浅いクイックタッチ ピーク1.35）が正確に復元され、
  誤補完ゼロ。図ではオレンジ線。保守ルール min(壁,ペース) はそのまま＝時間シグナルが既に支持する本数に壁カウントが追いつくだけで距離を盛らない。
  復元後は 7/28 半1=625m（体感一致）、6/21 半1=500m（意図「WU+100×4」と一致）・合計1175m。レップ7(壁2/ペース1)以外の全レップで両推定が一致。
- **`analysis/regression_check.py`**: 全セッションの notes.md 由来の疑似GT（壁/rest/big数・復元位置・半距離・総距離）をピン留めした回帰チェック。
  **検出器・レポートに触ったら必ず実行**（片方を直してもう片方を壊す事故を機械検出。CSV欠品はSKIP）。

### 次段
プールで股間装着の実データ採取 → 上記で取込・可視化 → 検出器を実信号で再チューニング → C 移植。
注意: Phase 0 検出器は「手首/30Hz」チューニング。股間装着は信号が別物なので、いきなり C 移植せず実データ採取が先。
**再チューニング方針**: 手首ベースの |acc|/activity FSM ではなく、上記 gz-オリエンテーション壁検出を主軸に据える。

### 将来構想 (プロダクト像)
最終的には水上でデータを吸い出して、スマホでログ閲覧・Strava アップまで完結させたい。
- **BLE オフロード（水上）**: 泳ぎ終わって水から上がった後、USB/タブレットではなく BLE でスマホへ記録を送る。
  ※水中は 2.4GHz が水に強く吸収されるため BLE は水上専用。プール採取フェーズ（現在）は引き続きフラッシュ記録＋USB 吸い出し。
- **スマホアプリ**: ラップログ閲覧 → Strava アップロード。
- 注意: BLE を使う水上フェーズではアンテナ向き（nRF52840 の PCB アンテナ端）が効くので、筐体設計時に考慮する。
- **電源スイッチ (筐体設計時に決定)**: 現行スライドスイッチ(SS-12D00G3)はプロト用。最終形（完全封入）では物理スイッチの穴を廃し、
  マグネット式（リードスイッチ/ホールIC）か タップ起動（ディープスリープ5μA＋加速度タップ、BLE起動と同思想）に置換。可動シール部は浸水経路になるため防水スイッチ製品でも避ける。詳細は DEVLOG 2026-07-11。

### Phase 2 (スマホアプリ / BLE) — 着手中の設計
振動モーター待ちでハード（筐体・触覚）が止まっている間にソフト側を進める。最初は「時刻合わせ」を通しで実装。
詳細設計は **`docs/ble_time_sync_design.md`**。要点:
- **プラットフォーム = iPhone / Swift ネイティブ（SwiftUI + CoreBluetooth）で確定**。iPhone専用＆取込タブレットもBLE化で不要になるため、
  Flutter のクロス利点は効かない。核が自作BLE機器との通信なので抽象層の無い CoreBluetooth が最適。
- **時刻問題**: 電源OFF中はRTC保持不可。スマホから epoch をもらい「サンプル番号K=epoch E」のアンカーをフラッシュに追記、
  ホストが `E+(i-K)/ODR` で各サンプルの絶対時刻を逆算（既存のサンプルページ形式は壊さない。新 magic `0xA55B`＋新 `TIMES` コマンド）。
- **BLE起動トリガー = タップ（叩く）**。物理ボタンは防水ケースに穴=浸水リスクなので今あるハードのまま加速度のタップ検出で起こす
  （叩いた時だけ数十秒BLEを開く＝記録の52Hzと無線がぶつからない）。既存の3タップ境界マーカー・泳ぎと誤作動しないパターン＋静止ゲートが要件。
  物理ボタンは筐体設計時に再検討。
- **役割分担 = 重い処理はスマホへオフロード (2026-07-28 確定)**。デバイス側は「記録＋（振動用の）コーザル壁カウンタ」だけに絞り、
  非コーザルな解析パイプライン（verticality 自己キャリブレーション・リズムリカバリ・デフラグ・レポート）は**スマホ側で実行**する。
  生データ(6軸int16)を BLE でフル転送する前提（フラッシュ満杯でも 2MB ≒ iOS 実効 20〜40kB/s で1〜2分。時刻同期と同じ接続で送れる）。
  → Phase 0 からの「検出器を C へフル移植」計画はスコープ縮小: **C 移植はコーザル壁カウンタのみ**（上の振動フィードバック要件参照）、
  解析パイプラインの移植先は C ではなく Swift。Python 側 (turn_stand/swim_report) が仕様のリファレンス実装になる。
- **取込後/Stravaアップ前の確認画面 (2026-07-28 確定)**: **壁インターバル表**（壁を蹴ってから次に蹴るまでの時間を表形式で一覧）を出し、
  明らかに変な行をユーザーが確認・修正してからアップする。
  - ハイライト規則は解析側の知見をそのまま流用: ブロック中央値の ≳1.6倍 = 壁見逃し疑い（リズムリカバリ発動箇所も明示）、
    ≲0.6倍 = 偽壁疑い、`CROSS-CHECK`（壁 vs ペース推定の不一致）も行warning化。
  - 修正操作 = 壁の追加/削除/隣接マージ → 距離・レップ・ペースを即時再計算してから Strava へ。
  - 意義: ①自動検出の最後の砦が人間の目になる（保守バイアス撤廃後の安全網はこれ） ②**修正ログはラベル付きGTとして蓄積**＝
    「外部GT不在」問題への構造的な回答。修正されたセッションは notes.md 相当の教師データになり検出器チューニングに回せる。
  - **生データはアプリ側に永続保存**（解析結果だけ残すのではない）。解析はいつでも再実行できるので、
    検出器を後から改良すれば**過去セッションも再処理して精度を引き上げられる**（今回 6/21 を新検出器で 1150→1175m に
    再集計したのと同じことがアプリ内で起きる）。デバイス上のフラッシュは吸い出し後に消してよい理由もこれ。

### Phase A 実装状況 (2026-07-28 着手。app/ ディレクトリ)
**アプリ開発を再開するときは `docs/app_handoff.md` を最初に読む**（現状・起動手順・残作業・落とし穴）。
プランは `docs/phase2_app_plan.md`。**解析コアの Swift 移植とパリティは完了**、アプリはシミュレータでビルド・起動確認済み。
- **`app/MokkoriCore`** = 解析エンジン Swift Package（turn_stand / swim_report の移植。iOS17+/macOS14+ 両対応）。
  ```bash
  cd app/MokkoriCore && swift test   # パリティテスト。Swift検出器に触ったら必ず実行（Mac上でXcode不要）
  ```
  regression_check.py と同一期待値（6/21: 35/13/2・復元@724s・1175m、7/28: 41/1/3・復元@533s・1050m）をピン留め。全 PASS。
  Python 検出器を変えたら **regression_check.py と両方**を回し、期待値がズレたら両者を同時に更新する。
- **移植の数値パリティ規則（崩すとテストが割れる）**: 全計算 Double / `np.percentile`=linear 補間・`np.median`=偶数長は中央2値平均
  （Stats.swift）/ Python `round()`=偶数丸め → Swift は `.rounded(.toNearestOrEven)`（ペース推定本数）。
- **`app/MokkoriIQ`** = iOS アプリ本体（SwiftUI, iOS 17+, iPhone 専用）。`.xcodeproj` は生成物でコミットしない:
  ```bash
  brew install xcodegen && cd app/MokkoriIQ && xcodegen    # MokkoriIQ.xcodeproj を生成 → Xcode で開く
  xcodebuild -project MokkoriIQ.xcodeproj -scheme MokkoriIQ -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
  ```
- 実装済み: CSV インポート（「ファイル」アプリ経由 fileImporter）→ 永続化は **raw.bin (int16) + meta.json + overlay.json** に分離
  （`Documents/sessions/<uuid>/`）。int16 化は**CSV 直読みとビット単位同値をテストで担保**（RawRecording。ダメな形式は raw.csv フォールバック）。
  画面: セッション一覧 → レポート（距離/ペース/半分割/レップ内訳/CROSS-CHECK警告）→ **壁インターバル確認画面**
  （ハイライト・壁の追加/削除/マージ＝オーバーレイ編集・即時再計算・修正破棄）。
- **ペースグラフ実装済み (2026-07-28)**: レポート画面の「ペースの推移」。データは `MokkoriCore/PaceChart`、
  描画は `MokkoriIQ/Views/PaceChartView`（Swift Charts）。縦軸=距離（上0m→下）・1本25m=1バーの**左端揃え**で、
  右端の輪郭がペースの推移になる。平均線（マゼンタ）・インターバル/セット境界（緑）を重ね、下に
  `後半にかけて +5.9s/100m（垂れ）` と言葉でも言い切る。バーをタップでラップの詳細。
  **回帰の傾向線は引かない**（輪郭で既に読めるうえ、線が3種類交差して読みづらかった。
  ユーザー判断 2026-07-28。回帰の計算自体は残っていて、上の一行の数字がそれ）。
  設計と実装で分かったことは `docs/pace_chart_design.md`。
  **異常値の強調（橙）は実データ2セッションでは1本も出ない**（ペースが揃っており、ブロック中央値比が
  最大 1.17 で判定値 1.25 に届かない）。閾値は緩めず据え置き＝「検出がずれた／泳ぎが崩れた」ときの
  非常口という位置づけ。色が付く経路は合成データのテスト（`PaceChartTests.testOutlierEmphasis`）で担保。
- **本ごとメトリクス実装済み (2026-07-28)**: swim_report.py と MokkoriCore の両方に ストローク数/SWOLF/DPS/ベストペース
  （RBJ バンドパス biquad + prone ゲート付きヒステリシスゼロクロス。FFT 不使用で Swift と同一算術）。中央値 14/本・SWOLF 平均44。
  期待値は regression_check.py と ParityTests の両方にピン留め済み（変更時は3点同時更新: Python実装/Swift実装/両テスト）。
- **Phase B (Strava) 実装済み (2026-07-28)**: 設定画面でゲートウェイ URL と API キーを入力 → 接続確認 →
  レポート画面「Strava へアップ」→ 時刻アンカー（泳ぎ始め or 記録終了の1点）を入れて投稿。
  **アプリは Strava を直接叩かず `strava-autopilot` のゲートウェイ経由**（理由は下記の認証節）。
  投稿内容の組み立ては `MokkoriCore/StravaSummary`（規約の実装。名前は時間帯デフォルト、
  説明文に実経過・ペース・ストローク・SWOLF・ベスト）。
- **UI テスト (`app/MokkoriIQ/UITests/ScreenFlowTests.swift`)**: シミュレータを実際に操作する。UI を触ったら必ず実行。
  `UITEST_SCREENSHOT_DIR` を渡すと目視用スクリーンショットも書き出す（`xcodebuild` からは **`TEST_RUNNER_` 前置**が必要。
  出力先は `/Users/...` 配下にすること＝`/tmp` はシミュレータ内に落ちてホストに出てこない）。
- 未了: SPM 表示（スペクトル cadence はコア未移植・後回し可。本ごとストローク数から導出可能）、
  実機 iPhone での動作確認、**実アクティビティの投稿テスト**（疎通と Strava 到達までは検証済み）。
- 落とし穴: Xcode 26.6 は **iOS 26.5 シミュレータランタイム必須**（26.4 が残っていても destination が1つも出ず
  "iOS 26.5 is not installed" になる）。`xcodebuild -downloadPlatform iOS` で導入（2026-07-28 導入済み・26.4 は削除）。
  CoreSimulator が古い警告が出たら `launchctl remove com.apple.CoreSimulator.CoreSimulatorService` で再起動。

### 記録時間の延長（将来検討）
記録可能時間 **約52分**は 2MB QSPI ÷ 12.8 byte/サンプル(6軸int16+ページヘッダ) ÷ 52Hz ≒ 約3150秒 から来る、**デバイス上のバイナリ形式**による制約。
吸い出し後の CSV 容量（1セッション約9.6MB＝テキスト展開で約5倍に膨張）とは別物で、記録時間を縛るのはあくまでフラッシュ上のバイナリ形式。
- きっかけ: 2026-06-21 の初プール採取が約2776秒(≒46分)で上限に近づいた。複数セッション/長め採取では満杯停止が現実的な制約になりうる。
- 延長策の候補（いずれも未着手）: ①サンプルレートを下げる（52→26Hz で約2倍）②デバイス上で1サンプルのバイト数を削る（軸削減・低ビット量子化・delta差分エンコード）③大容量フラッシュへ載せ替え。
- 判断時期: 実データの再チューニング（Mac側）が落ち着いてから。

## 用語（2026-07-28 確定。Python・Swift・画面・ドキュメントで統一する）
「半」「レップ」「本」は自作語で意味が伝わらなかったため、**Garmin 日本語の公式定義**と
**日本の水泳練習用語**に合わせて置き換えた。新しい語以外は使わないこと。

| 語 | 意味 | 出典 |
|---|---|---|
| **ラップ** | プールの片道（25m）。1ラップ = 壁を蹴ってから次の壁に着くまで | Garmin JA「ラップ＝プールの片道」 |
| **インターバル** | レストで区切られた連続泳ぎ区間 | Garmin JA の定義そのまま |
| **セット** | 大休憩（big-rest）で区切られた塊 | 水泳の練習用語（セット間は長めのレスト） |
| **レスト** | 休憩 | 水泳の練習用語 |
| **タイム / 経過時間** | 泳ぎのみ（moving）/ レスト込み | Garmin・Strava |
| **ストローク / SWOLF / ストローク長** | 装着腕1回転 / ラップタイム+ストローク数 / DPS | Garmin JA |

- コードの識別子も揃えてある: `SwimReport.Lap` / `.Interval` / `.SetSummary`、
  `report.laps` / `.intervals` / `.sets`、`typicalLapTime`、Python は `laps` / `interval` / `set_no`。
- **セット番号は「泳ぎのあるブロック」だけを 1 から数える**。検出ブロックの通し番号を
  そのまま出すと、入水前やシャワーの泳ぎゼロのブロックが番号を食って
  7/28 が「セット2 / セット3」から始まってしまう（2026-07-28 に修正。ParityTests でピン留め）。
- 「壁 / ターン」は**検出器の内部語としては残す**（`detect_walls`・`WallOverlay` 等）。
  画面では編集対象を「ターン」、その結果できる区間を「ラップ」と呼ぶ。

## 画面のタイポグラフィ（2026-07-28 確定。Apple フィットネス準拠）
レポート画面は **Apple 純正フィットネスの「ワークアウトの詳細」** に倣う。実装は
`app/MokkoriIQ/Sources/Views/MetricStyle.swift`（`MetricTile` / `ColumnHeader` / `MetricCell`）。
- **ラベルは小さく控えめ、値は大きく色付き**（知りたい情報とそうでない情報の認知的コントラストを
  サイズと彩度の両方で付ける）。**単位は値にくっつけて一回り小さく**（`1,050` + `M`）。
- **行は区切り線で分ける**（セルを枠線で囲まない）。セクション見出しは `.headerProminence(.increased)`。
- 色は**メトリクスの種類**に付ける（値の大小では変えない）。同系統は同色:
  距離=青 / 時間=橙 / ペース=teal / ストローク系=緑 / SWOLF=紫。ライト・ダークとも
  背景コントラスト 3:1 以上を配色バリデータで確認済み（ダークは自動反転せず明示値）。

## メトリクス算出方針（精度優先。2026-07-28 に保守バイアスを撤廃）
**距離・ペースは意図的なバイアスをかけず、正確さを狙う。**
- **撤廃の理由（ユーザー判断 2026-07-28）**: ①距離ベースの**振動フィードバック**（「100mごとにブザー」等）を実装すると、
  少なめに出る距離はズレが累積して**間違った壁で鳴る**＝保守側が実害になる。②精度が実証された（下記）。
- **実証**: 7/28 セッションの 1050m は本人の実績（狙い1000m＋最後に50m多め）と**完全一致**。
  両セッション24レップすべてで「壁カウント」と「ペース推定」の独立2系統が一致し、保守ルール min() は**1回も発火しない**。
- **min(壁, ペース) は残すが、これはバイアスではなく物理制約**（泳ぎ時間が許す以上の本数は泳げない）＝妥当性クロスチェック。
  発火したら「検出がずれている」というシグナルなので、レポートが `CROSS-CHECK` 行で**明示的に警告**する（黙って削らない）。
- かつて min() が発火していた唯一の箇所（6/21 @2251s）は**立ちエピソードの分断**が原因で、`detect_walls` の
  デフラグ（下記）で根本解決済み。
- レポート/Strava 説明文から「控えめ・実際はこれ以上」の断り書きは削除（数値が最良推定になったため、
  むしろ誤解を招く）。

### 距離ベース振動フィードバック（保守バイアス撤廃の動機。未着手）
「Nmごとにブザー」を実装するときの要件。**現行の解析系はそのままでは使えない**ことに注意:
- `swim_report` の min() クロスチェックも `detect_walls` のリズムリカバリ／デフラグも**非コーザル**
  （セッション全体の中央値・「次の壁」を参照する）。実機のリアルタイム振動には**コーザルな壁カウンタ**が別途必要。
- リアルタイムで効くのは精度ではなく**ドリフトしないこと**。壁を1回落とすとカウントが恒久的にズレて
  「500mのブザーが525mで鳴る」＝以降ずっと間違う。過大/過小どちらのバイアスも等しく有害なので、
  ここに保守バイアスを持ち込む余地はない（＝方針撤廃の直接の動機）。
- コーザル版の設計メモ: 立ちエピソードは「verticality>thr が 0.8s 継続」で即確定できる（因果的）。
  デフラグは「直近の壁から `refractory` 未満なら同一壁として無視」で因果的に実装できる。
  リズムリカバリだけは「次の壁」を要するので、走行中の間隔中央値を保持し
  「予想間隔の1.8倍を超えた時点で、その間の弱い姿勢ピークを1壁として遡って加算」する形にすれば近似できる。

### 立ちエピソードのデフラグ (2026-07-28)
1回の壁立ち中に verticality が一瞬 thr を下回ると、1つの壁が2エピソードに分断され壁カウントが過大になる
（6/21 @2251+2259 が 4秒差、7/28 @2430+2471 が 0.8秒差）。**間隔が `refractory`(12s) 未満の連続立ちエピソードは
同一の壁として union**し、合算スパンで再分類する。実測ギャップは二峰性で、分断が 0.8〜8.4s・次の正当なギャップが 14.4s と
広い空白帯があるので 12s は安全圏。旧実装の「近すぎる turn を drop」ではなく union なので、立ちの**真の終了時刻**が
保たれ（レポートが泳ぎ区間の境界に使う）、これで min() が完全に不発になった。

## Strava 投稿の規約 (2026-07-28 確定、スマホアプリでも同じ挙動にする)
**ガーミン等の既製ウォッチで泳いだ場合と同じ見え方にする**のが方針。ユーザー確定事項:
- **表示時間 = 泳ぎのみ（moving time）**。プールの休憩・ベンチ休憩は含めない（今回 20:35。実経過 33:02 は説明文に併記）。
  ガーミンのプールスイムがそう出るため。ペースも moving 基準（1:58/100m）。
- **開始時刻 = 実際に泳ぎ始めた時刻**（ウォッチのスタートボタン相当。今回 13:38:58 JST）。
- 距離は [メトリクス算出方針]（精度優先）の推定値をそのまま使う。**「控えめ・実際はこれ以上」の断り書きは書かない**
  （2026-07-28 に保守バイアスを撤廃したため。7/28 の投稿も説明文を修正済み）。
- 現状は Strava の**手動アクティビティ** `POST /api/v3/activities`（`sport_type=Swim` / `start_date_local` /
  `elapsed_time`=moving / `distance` / `description`）。手動作成では moving=elapsed になるため、実経過との差は説明文で補う。
  将来レップ別スプリットまで出したくなったら TCX アップロード（Lap に `Intensity=Resting` で休憩を表現）へ移行する。
- **認証 (2026-07-28 方針確定)**: **投稿は arigato-nas の `strava-autopilot`（= Strava ゲートウェイ）経由**で行う。
  アプリは Strava を直接叩かず `POST https://strava.ojimpo.com/api/gateway/activities`（`X-API-Key` 認証）を呼ぶ。
  - 理由①: Strava は **1 アカウントにつき API アプリ 1個**で、本アカウントの枠は既に `strava-autopilot` が使用中。
  - 理由②: **2026-06 以降、Standard Tier の API 利用には Strava サブスクが必須**（月 $11.99 相当＝通常のサブスク）。
    つまり「API 登録用の無料サブアカウントを作る」回避策は**もう使えない**（2026-07-28 に確認。
    2023年の「サブスク不要」という公式回答は失効している）。
  - 理由③: 同じ client を複数箇所で個別に認可するとトークン系統が枝分かれし、リフレッシュのローテーションで
    **お互いを壊しうる**。トークンを持つのを NAS 側だけにすればその心配がない。`client_secret` もスマホに置かずに済む。
  - アプリが持つのは**ゲートウェイ URL と API キーのみ**（Keychain 保存）。API キーは NAS の
    `~/dev/strava-autopilot/.env` の `GATEWAY_API_KEY`。ゲートウェイは公開 URL なので Tailscale 不要。
  - ゲートウェイ側の仕様・注意点は `strava-autopilot` の CLAUDE.md「Strava ゲートウェイ」節に記載。
  - `health-ojimpo` も同じ client を共有していたが、**2026-07-28 にゲートウェイ経由へ移行済み**
    （`GET /api/gateway/token` でトークンを借りる）。これで**リフレッシュするのは autopilot だけ**になった。
  - **Strava の再認可は autopilot 側（`/api/oauth`）で行うこと。** 他アプリから再認可すると新しい認可が
    発行されてトークン系統が枝分かれし、既存アプリを壊しうる。
- 手動アクティビティの旧経路（Mac から curl / Python で autopilot のトークンを「使うだけ・refresh しない」）は
  緊急時のフォールバックとして残すが、通常はアプリから投稿する。
- 注意: アカウントの既定公開範囲が `everyone`。非公開にしたいセッションは投稿後に Strava 側で変更する。

## パラメータ変更
config/default.json を編集して .venv/bin/python src/evaluate.py で再評価。
チューニング履歴: analysis/tune.py 〜 tune5.py（グリッドサーチ）。

## 注意事項
- data/brunner/ は .gitignore 済み。初回は上記の git clone が必要
- detector.py 内で x ** 0.5 (sqrt) を使用。C移植時は sqrtf() に置換
- analysis/ の図 (fig_*.png) はコミットに含まれている（再生成も可能）
