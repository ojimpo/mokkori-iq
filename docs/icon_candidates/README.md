# アプリアイコン

コードで描いている（画像生成モデルは使っていない）。ソースは `tools/make_icon.py`。
図形をいくつか置いて 4 倍で描き、縮小してエッジを整えているだけなので、
形も色も値を変えて何度でも出し直せる。

```bash
# 採用しているもの（lanes / aqua）を本番の位置に書き出す
.venv/bin/python tools/make_icon.py --concept lanes --palette aqua \
  --out app/MokkoriIQ/Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png

# 見比べ用に全案・全配色
.venv/bin/python tools/make_icon.py --all --out-dir docs/icon_candidates
```

## 採用

**lanes4m / aqua**: レーンを泳いで壁で U ターン、を 4 本ぶん。上に山が2つ出て
**M** に見える（往復コースであると同時に mokkori の M）。泳者アイコンだらけの中で被りにくい。
配色はプールの水色（`#5cd0f5` → `#0f74cc`）にマークは白。

レーン数と向きは `serpentine()` の引数なので、3本の S 字（`lanes`）や
4本の W 字（`lanes4w`）にも振り直せる。`_shapes4.png` に並べてある。

`_compare.png` に形の 3 案、`_colors.png` に配色の 3 案が並べてある
（下段はホーム画面と同じ 120px。小さくして潰れないかを見るため）。

## 外観バリアント（ライト / ダーク / 淡色）

**1枚だけ置くと、ダークモードでシステムが勝手に暗くする**（実機の並びで確認した。
水色のはずが濃紺に沈む）。明るい水色を保ちたいので、`Contents.json` に
`appearances` を書いて3枚を明示している:

| 外観 | ファイル | 中身 |
|---|---|---|
| ライト | `icon-1024.png` | 水色の不透明画像 |
| ダーク | `icon-1024-dark.png` | 同じ水色（暗くしない） |
| 淡色 | `icon-1024-tinted.png` | **背景透過・マークのみ**（色はシステムが付ける） |

```bash
.venv/bin/python tools/make_icon.py --concept lanes4m --palette aqua --tinted \\
  --out app/MokkoriIQ/Sources/Assets.xcassets/AppIcon.appiconset/icon-1024-tinted.png
```

なお iOS 26 は**このフラットな PNG にもガラスの光沢を乗せてくれる**（ホーム画面で確認済み）。

## Liquid Glass (iOS 26)

iOS 26 のアイコンは **Icon Composer**（Xcode 26 同梱。
`/Applications/Xcode.app/Contents/Applications/Icon Composer.app`）で作る `.icon` が正式で、
レイヤーを渡すとシステムが光沢・屈折とライト/ダーク/淡色/クリアの各バリアントを生成する。

**`.icon` の中身は自分で書き起こしていない**（非公開のバンドル形式なので、
推測で書くとビルドが壊れる）。代わりに Icon Composer に渡せる 2 レイヤーを書き出してある:

```
liquid_glass/layer_background.png   グラデーションの板
liquid_glass/layer_foreground.png   マークだけ（背景は透明）
```

```bash
.venv/bin/python tools/make_icon.py --concept lanes --palette aqua --layers \
  --out-dir docs/icon_candidates/liquid_glass
```

いま組み込んであるのは**従来のフラットな 1024px PNG** で、iOS 26 でもそのまま動く
（システムが既定の処理をする）。Liquid Glass にしたくなったら上の 2 枚を
Icon Composer にドロップして書き出す。そのときは**背景のグラデーションを弱める**とよい
（システム側が光沢を足すので、素材にも入れると二重になる）。
