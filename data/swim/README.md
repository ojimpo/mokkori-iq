# data/swim/ — 実機スイムキャプチャ

XIAO nRF52840 Sense（股間装着）で採取した IMU 記録の置き場。
`tools/flash_dump.py --pull` / `tools/flash_gui.py` の PULL がここに
`swim_<YYYYMMDD_HHMMSS>.csv` を保存する。

## 運用フロー
更衣室のロッカー内で Ubuntu タブレットに**データ対応ケーブルで直挿し**し、
GUI の「吸い出して保存」で取り込む。タブレットから `git push` し、
Mac で `git pull` して `analysis/explore_swim.py` で可視化する想定。

```bash
# タブレット（吸い出し）
.venv/bin/python tools/flash_gui.py        # or: flash_dump.py --pull
git add data/swim/ && git commit -m "swim: session capture" && git push

# Mac（可視化）
git pull
.venv/bin/python analysis/explore_swim.py data/swim/swim_YYYYMMDD_HHMMSS.csv
```

## CSV 形式
`idx,t,ax,ay,az,gx,gy,gz`（acc=g, gyro=dps, t=秒）。
`dataio.load_swim_csv()` が取り込み時に g→m/s² / dps→rad/s へ変換する。

## 注意
- 公開データセット `data/brunner/` は `.gitignore` 済みだが、この `data/swim/` は
  追跡対象（実データを git に含めて端末間で共有する方針）。
- CSV は ~5–6MB/30分。肥大化したら Git LFS / 別保管へ移行を検討。
