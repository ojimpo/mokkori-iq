# mokkori-iq: 水泳ターン検知アルゴリズム（Phase 0）

水着の中に仕込む DIY ウェアラブルスイムトラッカー「mokkori-iq」のターン検知アルゴリズムを、公開データセットで開発・検証するプロジェクト。

## 背景・動機

日本の市民プールでは Garmin 等のスマートウォッチを着けて泳ぐことが禁止されている。
水着に仕込める小型デバイス（Seeed XIAO nRF52840 Sense, 6軸IMU内蔵）で
スイムログ（ラップ数・ラップタイム・距離）を記録し、Strava にアップロードしたい。
さらに泳いでいる最中に ERM 振動モーターで距離通知（100mごと等）を行う。

装着位置は股間（仙骨付近）。泳法は自由形（クロール）のみ、ターン方式はタッチターン
（壁に足をついて反転して蹴り出す。フリップターン/前転はしない）。

## Phase 0 のゴール

プールに行く前に、公開データセット（Brunner et al., ISWC 2019）を使って
Python でターン検知アルゴリズムを開発・検証する。
最終的に Arduino/C（Cortex-M4, 256KB RAM）に移植するため、
TFLite/機械学習ではなく *閾値ベースのヒューリスティック* をまず作る。

## データセット

[Brunner et al. "Swimming Style Recognition and Lane Counting Using a Smartwatch"](https://github.com/brunnergino/swimming-recognition-lap-counting)

- 40人分のスマートウォッチIMUデータ（手首装着、Android TYPE_ACCELEROMETER）
- 加速度・ジャイロ・磁気・気圧・照度、30Hz リサンプル済み
- ラベル: 0=null, 1=freestyle, 2=breaststroke, 3=backstroke, 4=butterfly, 5=turn
- 自由形: 92セッション / 30被験者 / 310ターン

*注意*: 本デバイスの装着位置（股間）とデータセットの装着位置（手首）は異なる。
このデータでの精度に固執するより、位置非依存で汎用的なアルゴリズム構造を優先した。

## アルゴリズム

### 核心の発見: ターンの信号 signature

データ探索（`analysis/findings.md`）から、ターンは装着位置・泳法を問わず
以下の共通 signature を持つことを確認した:

1. 定常ストローク（高い活動量）
2. 壁タッチ/グライドで *活動量が泳ぎの約1/10に急落*（静止区間、中央値1.27秒）
3. 壁キックで再加速

この「低活動の谷」は全4泳法のターンに存在し、98%のターンで検出可能。

### 検出器: Causal 有限状態機械

```
SWIM ──activity<thr_low──▶ DIP ──activity>thr_high & valid──▶ CONFIRM ──sustained swim──▶ EMIT
                            │                                    │
                            ├──dip too long──▶ REST              ├──dips again──▶ DIP (discard)
                            │                                    │
                        REST ──activity>thr_high──▶ SWIM         └──timeout──▶ SWIM (discard)
```

*SWIM*: 泳いでいる状態。活動量（acc_norm の移動標準偏差）が閾値を下回ると DIP へ。

*DIP*: 壁タッチ候補。静止区間の最小活動点を追跡。
活動量が回復すれば CONFIRM へ（条件: 最小継続時間を満たし、不応期外）。
長すぎれば REST（休憩）と判定し破棄。

*CONFIRM*: ターン候補の検証。泳ぎが持続的に再開すればターンを確定して発報。
再び低下すればセット終わりと判断し破棄（end-of-set の誤検出を防ぐ核心）。

*REST*: 休憩中。活動量が戻れば SWIM へ（発報なし）。

### 適応閾値

閾値は「最近の泳ぎ活動」のピークフォロワー（fast attack / slow release）に対する
比率で設定。装着位置・被験者で絶対スケールが変わっても追従する
（Phase 1 で股間装着に移っても効く設計）。

### MCU 移植性

- コアの `update()` は純粋なスカラ演算（for文 + 基本四則 + sqrt）で C に直接変換可能
- メモリ: リングバッファ（66サンプル = 2.2秒分）+ biquad状態2変数 + FSM状態変数数個
- 因果的（causal）: 未来のデータを一切参照しない
- パラメータは `config/default.json` に外出し（Phase 1 で自分のデータに合わせて調整）

## 評価結果

### 自由形（主評価、30被験者 / 92セッション / 310ターン）

| 指標 | 値 |
|---|---|
| Precision | 0.646 |
| Recall | 0.635 |
| F1 | 0.641 |
| ラップ数 完全一致 | 47.8% |
| ラップ数 +-1以内 | 64.1% |
| ラップタイム MAE | 0.67秒 |
| 累積ドリフト | 0.61秒 |

### 他泳法（参考、自由形用チューニングのまま）

| 泳法 | F1 | 完全一致 | +-1以内 |
|---|---|---|---|
| Butterfly | 0.455 | 55.2% | 75.9% |
| Backstroke | 0.364 | 39.4% | 78.8% |
| Breaststroke | 0.292 | 21.7% | 52.2% |

### 考察

- *ラップタイムの精度は良好*（MAE 0.67秒、ドリフト 0.61秒）。ターンを正しく拾えた
  ケースではタイミングが正確であることを示す。
- *ラップ数の一致率が課題*。主因は (a) 一部の長尺セッションでの過剰検出
  （ストロークの活動変動が大きい泳者で閾値を反復的に跨ぐ）、
  (b) 約35%のターン取りこぼし（活動の谷が浅い/短いターン）。
- *装着位置の違いが根本的制約*。手首の加速度パターンは股間と大きく異なる。
  Phase 1（自分のデータ）で飛躍的な精度向上が見込める。
- 誤検出の32%は GT=0（ターンラベル無し）のセッションに集中。
  うち1セッション（swimmer 20）だけで全FPの23%を占める。
  この泳者は21分間泳いでいるがターンラベルが一切無く、ラベル品質の問題と推定される。

## プロジェクト構成

```
mokkori-iq/
├── config/default.json        # 検出器パラメータ（閾値・窓長・フィルタ係数）
├── src/
│   ├── dataio.py              # Brunner データセット読み込み
│   ├── preprocessing.py       # Butterworth LP (causal biquad) + 移動標準偏差
│   ├── detector.py            # ターン検出器（causal FSM、MCU移植可能）
│   ├── lap_logger.py          # ターンタイムスタンプ → ラップログ変換
│   └── evaluate.py            # 全被験者評価パイプライン
├── analysis/
│   ├── findings.md            # データ探索の発見まとめ
│   ├── explore_turns.py       # ターン信号の可視化・定量分析
│   ├── tune*.py               # パラメータグリッドサーチ（tune1〜5）
│   ├── diag_fp.py             # 誤検出の集中分析
│   ├── fig_*.png              # 生成された図
│   └── session_manifest.csv   # 全セッション一覧
├── results/
│   ├── per_session_*.csv      # セッション別評価結果
│   └── per_subject_*.csv      # 被験者別評価結果
├── data/brunner/              # Brunner データセット（git clone、.gitignore）
├── requirements.txt           # numpy, scipy, pandas, matplotlib
└── mokkori-iq-phase0-prompt.md
```

## セットアップ・実行

```bash
# 環境構築
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# データ取得
git clone --depth 1 https://github.com/brunnergino/swimming-recognition-lap-counting.git data/brunner

# 評価実行
.venv/bin/python src/evaluate.py --all-styles

# 探索的分析の再現
.venv/bin/python analysis/explore_turns.py
```

## 参考文献

- Brunner et al., "Swimming Style Recognition and Lane Counting Using a Smartwatch", ISWC 2019
- Delhaye et al., "Swimming Stroke and Turn Detection Using a Single Sacral-Mounted IMU", Sensors 2022
  - 仙骨装着の単一IMUでの先行研究。前処理パイプライン（2次バターワースLP 10Hz）を参考にした

## 今後（Phase 1 以降）

1. *Phase 1*: 実際にプールで XIAO nRF52840 Sense を股間に装着してデータ収集。
   自分のタッチターンの信号を `config/default.json` のパラメータで調整して精度を詰める。
2. *Phase 2*: Arduino/C に `detector.py` の `update()` ロジックを移植。
   リアルタイムでターン検知 + フラッシュにラップログ書き込み。
3. *Phase 3*: BLE/USB-C でPC転送 → .fit ファイル生成 → Strava API アップロード。
   ERM 振動モーターによる 100m ごとの触覚通知。
