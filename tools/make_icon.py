"""Draw the app icon in code and write the 1024px PNG Xcode wants.

No image-generation model involved: the icon is a few geometric primitives,
supersampled 4x and downsampled so the curves come out clean.

    .venv/bin/python tools/make_icon.py --concept lanes --out app/MokkoriIQ/Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
    .venv/bin/python tools/make_icon.py --all --out-dir /tmp/icons   # 見比べ用

The mark has to survive being 40pt wide on a home screen, so every concept is
one shape on a flat-ish ground -- no thin lines, no text, no gradients on the
mark itself.
"""
import argparse
import math
import os

from PIL import Image, ImageDraw

SS = 4                      # supersample factor
SIZE = 1024
N = SIZE * SS

# 配色。プールっぽい水色を軸にしつつ、**マークが小さくても潰れないこと**を優先する
# （アイコンは 40pt まで縮む）。明るい背景に白マークだとコントラストが足りないので、
# 明るい水色を使うときはマークを濃紺にする。
PALETTES = {
    # 水色→青。マークは白。明るさとコントラストの折衷
    "aqua": ((0x5c, 0xd0, 0xf5), (0x0f, 0x74, 0xcc), (0xff, 0xff, 0xff)),
    # 淡い水色→水色。マークは濃紺。いちばんプールの水に近い明るさ
    "shallow": ((0xbc, 0xee, 0xff), (0x53, 0xc6, 0xf0), (0x0b, 0x4a, 0x8a)),
    # 濃いめの青。白マーク。コントラストは最大
    "deep": ((0x2f, 0x86, 0xd8), (0x0b, 0x3a, 0x78), (0xff, 0xff, 0xff)),
}
BG_TOP, BG_BOTTOM, MARK = PALETTES["aqua"]


def background() -> Image.Image:
    img = Image.new("RGB", (N, N), BG_TOP)
    d = ImageDraw.Draw(img)
    for y in range(N):
        t = y / (N - 1)
        d.line([(0, y), (N, y)],
               fill=tuple(int(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)))
    return img


def cap(d, x, y, w):
    """線の端を丸める（PIL の line にキャップが無いので自前で置く）。"""
    d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=MARK)


def stroke_line(d, x0, y0, x1, y1, w):
    d.line([(x0, y0), (x1, y1)], fill=MARK, width=w)
    cap(d, x0, y0, w)
    cap(d, x1, y1, w)


def stroke_arc(d, cx, cy, r, a0, a1, w):
    """円弧。`line` に折れ線を渡して joint="curve" にすると放射状の割れが出るので
    PIL の arc を使う（角度は3時方向が0で時計回り）。
    **arc の太さは bbox から内側に伸びる**ので、直線と芯を合わせるには
    半径に w/2 を足しておく（足さないと継ぎ目に段差が出る）。"""
    rr = r + w / 2
    d.arc([cx - rr, cy - rr, cx + rr, cy + rr], a0, a1, fill=MARK, width=w)


def draw_lanes(img: Image.Image) -> None:
    """往復コース: レーンを下って壁でUターン、を3本ぶん。
    「プールを往復する」がそのまま形になっていて、他のスイムアプリと被りにくい。"""
    d = ImageDraw.Draw(img)
    w = int(N * 0.115)
    xs = [N * 0.28, N * 0.5, N * 0.72]
    top, bot = N * 0.24, N * 0.76
    r = (xs[1] - xs[0]) / 2

    stroke_line(d, xs[0], top, xs[0], bot - r, w)
    stroke_arc(d, xs[0] + r, bot - r, r, 0, 180, w)        # 下の壁でターン
    stroke_line(d, xs[1], bot - r, xs[1], top + r, w)
    stroke_arc(d, xs[1] + r, top + r, r, 180, 360, w)      # 上の壁でターン
    stroke_line(d, xs[2], top + r, xs[2], bot, w)


def draw_turn(img: Image.Image) -> None:
    """Uターンの矢印 + 水面。検出しているものそのもの。"""
    d = ImageDraw.Draw(img)
    w = int(N * 0.105)
    cx = N * 0.5
    r = N * 0.155
    y_top = N * 0.26
    y_turn = N * 0.52

    stroke_line(d, cx - r, y_top, cx - r, y_turn, w)       # 行き
    stroke_arc(d, cx, y_turn, r, 0, 180, w)                # 壁でターン
    stroke_line(d, cx + r, y_turn, cx + r, y_top + N * 0.10, w)  # 帰り
    # 矢じり（帰りの先端）
    a = N * 0.095
    tip = (cx + r, y_top - N * 0.01)
    d.polygon([tip, (tip[0] - a, tip[1] + a * 1.15), (tip[0] + a, tip[1] + a * 1.15)],
              fill=MARK)
    # 水面（交差しないよう同位相・長さ違いで2本）
    for y, span in [(N * 0.79, 0.60), (N * 0.90, 0.40)]:
        amp = N * 0.028
        x0 = cx - N * span / 2
        wave = [(x0 + N * span * t / 60,
                 y + amp * math.sin(2 * math.pi * (t / 60) * 1.5))
                for t in range(61)]
        d.line(wave, fill=MARK, width=int(N * 0.042), joint="curve")


def draw_bars(img: Image.Image) -> None:
    """ペースグラフの左端揃えのバー。アプリの見た目とそのまま繋がる。"""
    d = ImageDraw.Draw(img)
    x0 = N * 0.24
    widths = [0.34, 0.46, 0.30, 0.52, 0.38]
    h = N * 0.082
    gap = N * 0.043
    y = N * 0.28
    for f in widths:
        d.rounded_rectangle([x0, y, x0 + N * f, y + h], radius=h / 2, fill=MARK)
        y += h + gap


CONCEPTS = {"lanes": draw_lanes, "turn": draw_turn, "bars": draw_bars}


def render(concept: str) -> Image.Image:
    img = background()
    CONCEPTS[concept](img)
    return img.resize((SIZE, SIZE), Image.LANCZOS)


def write_layers(concept: str, out_dir: str) -> None:
    """Icon Composer（Xcode 26 同梱）に渡すための2レイヤー。
    背景（グラデーションの板）と前景（マークだけ・背景は透明）に分けておくと、
    Liquid Glass の光沢・屈折はシステム側が付けてくれる。"""
    os.makedirs(out_dir, exist_ok=True)
    background().resize((SIZE, SIZE), Image.LANCZOS).save(
        os.path.join(out_dir, "layer_background.png"))

    fg = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    CONCEPTS[concept](fg)
    fg.resize((SIZE, SIZE), Image.LANCZOS).save(
        os.path.join(out_dir, "layer_foreground.png"))
    print(f"wrote {out_dir}/layer_background.png, layer_foreground.png")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--concept", choices=sorted(CONCEPTS), default="lanes")
    ap.add_argument("--all", action="store_true", help="全案を書き出す（見比べ用）")
    ap.add_argument("--palette", choices=sorted(PALETTES), default="aqua")
    ap.add_argument("--layers", action="store_true",
                    help="Liquid Glass 用に背景とマークを別レイヤーで書き出す")
    ap.add_argument("--out", default=None)
    ap.add_argument("--out-dir", default=None)
    args = ap.parse_args()

    global BG_TOP, BG_BOTTOM, MARK
    BG_TOP, BG_BOTTOM, MARK = PALETTES[args.palette]

    if args.layers:
        write_layers(args.concept, args.out_dir or ".")
        return

    names = sorted(CONCEPTS) if args.all else [args.concept]
    for name in names:
        img = render(name)
        if args.out and not args.all:
            path = args.out
        else:
            path = os.path.join(args.out_dir or ".", f"icon_{name}.png")
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        img.save(path)
        # ホーム画面サイズでも読めるか見るための縮小版
        if args.out_dir:
            img.resize((120, 120), Image.LANCZOS).save(
                os.path.join(args.out_dir, f"icon_{name}_small.png"))
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
