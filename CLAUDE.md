# mokkori-iq

## プロジェクト概要
水着に仕込む DIY スイムトラッカーのターン検知アルゴリズム開発。
Phase 0 は公開データセット（Brunner et al., 手首装着 30Hz）での Python プロトタイプ。

## 技術スタック
- Python 3.9+ / venv (.venv/)
- numpy, scipy, pandas, matplotlib (requirements.txt)
- データ: data/brunner/ (Brunner リポジトリの shallow clone、.gitignore 済み)

## ディレクトリ構成
- src/ : コアモジュール (dataio, preprocessing, detector, lap_logger, evaluate)
- config/default.json : 検出器パラメータ（閾値・窓長・フィルタ係数）
- analysis/ : 探索スクリプト・チューニングスクリプト・生成図・findings.md
- results/ : 評価結果 CSV（セッション別・被験者別）

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
```

## アーキテクチャ
- 検出器 (src/detector.py): Causal FSM (SWIM→DIP→CONFIRM→EMIT)
  - update(ax,ay,az) で1サンプルずつストリーミング処理（MCU移植前提）
  - 適応閾値: ピークフォロワーで「最近の泳ぎ活動」を追跡し、比率で閾値設定
  - CONFIRM 状態: 壁タッチ後に泳ぎが持続再開したらターン確定（セット終わりの誤検出防止）
- 前処理 (src/preprocessing.py): Causal biquad LP + trailing rolling std
  - Biquad / RollingStd クラスは MCU 移植可能（O(1)/O(W) メモリ）
- 評価 (src/evaluate.py): GT ターン窓との greedy distance matching → P/R/F1 + ラップログ精度

## パラメータ変更
config/default.json を編集して .venv/bin/python src/evaluate.py で再評価。
チューニング履歴: analysis/tune.py 〜 tune5.py（グリッドサーチ）。

## 注意事項
- data/brunner/ は .gitignore 済み。初回は上記の git clone が必要
- detector.py 内で x ** 0.5 (sqrt) を使用。C移植時は sqrtf() に置換
- analysis/ の図 (fig_*.png) はコミットに含まれている（再生成も可能）
