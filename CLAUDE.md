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

# 一発レポート (取込済みCSV → 距離/ペース/レップ内訳/SPM/Strava用サマリ。保守バイアス内蔵)
.venv/bin/python analysis/swim_report.py data/swim/session01.csv --date 2026-06-21
.venv/bin/python analysis/turn_stand.py  data/swim/session01.csv   # gz壁検出の可視化(図)
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
- コンソールコマンド: `INFO` / `DUMP` / `ERASE` / `TESTLOG <sec>`（USB中でも追記、ベンチ用）/ `HELP`
- `tools/flash_dump.py`: `--pull [PATH]`（DUMP→CSV保存→ERASE を1コマンド＝1泳ぎ分。PATH省略で data/swim/ に自動命名）/
  `--info` / `--erase` / `--testlog N` / `--selftest N`（ベンチ往復）。生int16を g/dps に変換
- 検証済(2026-06-03): TESTLOG 2s×2で 105→210（追記）、`--pull` で保存＆消去、|acc|=1.03g、往復整合

### 実データ取込 (device CSV → Phase 0)
- `dataio.load_swim_csv(path)`: flash_dump CSV を session dict 化。**g→m/s²・dps→rad/s に変換**（Brunner/検出器閾値の単位に合わせる）、fs は t から自動推定
- `preprocessing.make_config_for_fs(fs)`: biquad LP を fs 用に再設計（default.json は30Hz用。52Hz等で検出器をネイティブ実行）。30Hz指定で既存係数を完全再現する
- `analysis/explore_swim.py <csv>`: 信号(|acc|/activity＋閾値/|gyro|)をプロットし、手首チューニング検出器の検出を重ねて `analysis/fig_swim_*.png` 出力
- **`analysis/swim_report.py <csv> [--date ...] [--verbose]`**: **取込CSV→一発で距離/ペース/レップ内訳/SPM/Strava用サマリ**を出力（デバイスの完成形出力）。
  検出は `turn_stand.detect_walls`（gz壁検出）を共有、ケイデンスは `stroke_rate.dominant_cadence` を再利用。
  保守ルール: 各レップ `本数 = min(壁カウント, round(泳ぎ時間/標準レングス時間))`。標準レングス時間は「ターン間の泳ぎ実時間(立位除外)」の中央値で、
  分子(泳ぎ時間)と単位を揃える。これで偽分割の過大を潰しつつ検証済みの綺麗な100mは保持。距離は下振れ・ペースは遅め＝[メトリクス算出方針]に合致。
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
- **結果(保守版)**: 半1 ≒100/100/100/175m, 半2 ≒100/325(連続)/50/200m。合計 ≒**1150m**（[メトリクス算出方針]の保守側）。
  弱点: 後半の連続325m区間は止まらない＝境界信号が原理的に無く「何本目か」は不明（距離はカウント可）。
- **外部GTが無い問題**: プールにスマホ持込不可＋本人も覚えていられない＝**トントンが唯一のGT機構**。
  → 検出は内的整合性（等間隔性）+妥当ペース+本人の事後記録(notes)で検証。トントンは水中でも「立って静止して」打てば gz+jerk で拾える。
- 注意: gz が効くのは装着向き（USB-C上/Seeed面外側）前提。向きが変わる/未知なら「泳ぎ⇄静止で最も振れる軸」を自動選択する一般化が必要。
- **ストローク率(SPM)も計測可 (`analysis/stroke_rate.py`)**: 股間は体ロールのリズムが乗る。泳ぎ区間でジャイロのロール軸の
  スペクトルピーク＝**ストロークサイクル率**。本セッションは両半とも安定して **30 cyc/min（≒60 arm strokes/min）**。
  3手法一致（窓FFT29/自己相関28-29/トラッカー30）。注: |acc|/|gyro| は整流で2倍/4倍harmonicsが出るので符号付き単軸で取る。
  8s窓だと分解能0.125Hz=7.5cyc/min刻みに量子化（精度要るなら自己相関/放物線補間/長窓）。当初想定外だがログとして有用。

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

### 記録時間の延長（将来検討）
記録可能時間 **約52分**は 2MB QSPI ÷ 12.8 byte/サンプル(6軸int16+ページヘッダ) ÷ 52Hz ≒ 約3150秒 から来る、**デバイス上のバイナリ形式**による制約。
吸い出し後の CSV 容量（1セッション約9.6MB＝テキスト展開で約5倍に膨張）とは別物で、記録時間を縛るのはあくまでフラッシュ上のバイナリ形式。
- きっかけ: 2026-06-21 の初プール採取が約2776秒(≒46分)で上限に近づいた。複数セッション/長め採取では満杯停止が現実的な制約になりうる。
- 延長策の候補（いずれも未着手）: ①サンプルレートを下げる（52→26Hz で約2倍）②デバイス上で1サンプルのバイト数を削る（軸削減・低ビット量子化・delta差分エンコード）③大容量フラッシュへ載せ替え。
- 判断時期: 実データの再チューニング（Mac側）が落ち着いてから。

## メトリクス算出方針（保守バイアス）
距離・ペースの算出は常に保守側に倒す（Strava用一発計算に限らず全般）。
- **距離**: 実際より少なめはOK、多めはNG。
- **ペース**: 遅めはOK、速めはNG。（距離を少なめにすると 時間÷距離 のペースは自動で遅め＝安全側になり整合）
- 実装: 不確実時は切り捨て寄り。ただし floor 一律は過小すぎる（綺麗な100mレップまで削る）ので、
  「偽分割で増える方を潰して過大を防ぐ／検証済みの綺麗なレップはそのまま／怪しい連続区間だけ保守的に」が正解。
  壁カウント(turn_stand.py)は偽分割で過大に出やすい→ペースベースの本数推定や偽分割除去で過大を抑える。端数は下に丸める。

## パラメータ変更
config/default.json を編集して .venv/bin/python src/evaluate.py で再評価。
チューニング履歴: analysis/tune.py 〜 tune5.py（グリッドサーチ）。

## 注意事項
- data/brunner/ は .gitignore 済み。初回は上記の git clone が必要
- detector.py 内で x ** 0.5 (sqrt) を使用。C移植時は sqrtf() に置換
- analysis/ の図 (fig_*.png) はコミットに含まれている（再生成も可能）
