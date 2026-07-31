import SwiftUI
import Charts
import MokkoriCore

/// ラップごとのペースを距離順に並べた横バーグラフ（設計は docs/pace_chart_design.md）。
///
/// 縦軸 = 距離（上 0m → 下）で泳ぎ進む向きと同じ。1ラップ = 1バーで**左端揃え**なので、
/// 右端の輪郭がそのままペースの推移になる。上から下へ目で追って、
/// 短くなっていけばビルドアップ、伸びていけば垂れ。
struct PaceChartView: View {
    let chart: PaceChart
    @State private var selected: PaceChart.Row?
    /// ツールチップの実寸。プロットの縁で折り返す位置を出すのに要る。
    @State private var tooltipSize: CGSize = .zero

    /// 1ラップの帯 = バー 10pt + 隙間 2pt。**セッションによらず固定**にする
    /// （縮めて全部を1画面に押し込むと、バーの太さが変わって比較できなくなる）。
    private static let band = 12.0
    private static let barGap = 2.0
    /// 横軸ラベル（上端）と余白のぶん
    private static let axisBand = 32.0
    private static let cornerRadius = 4.0
    /// y 軸ラベルの帯（バーの実幅を出すための概算。角丸の詰め物にしか使わない）
    private static let yAxisBand = 52.0
    /// バー先端とツールチップの隙間
    private static let tooltipGap = 6.0

    private var plotHeight: Double { Double(chart.rows.count) * Self.band }
    /// 隙間 2pt を距離（m）に換算した値。バーの上下をこのぶん詰める。
    private var gapMeters: Double { chart.poolLength * Self.barGap / Self.band }
    /// 縁取りの太さ 1.5pt を距離（m）に換算した値。隙間 2pt に収まる幅にする。
    private var outlineMeters: Double { chart.poolLength * 1.5 / Self.band }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let plotWidth = max(120.0, geo.size.width - Self.yAxisBand)
                // 角丸はデータ側（右端）だけに付けたい。左端は軸に接するので、
                // 同色の四角を 4pt ぶん重ねて左の角丸を潰す。
                let cap = (chart.axisHi - chart.axisLo) * Self.cornerRadius / plotWidth
                chartBody(cap: cap)
            }
            .frame(height: plotHeight + Self.axisBand)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("paceChart")
            .accessibilityLabel("ラップごとのペース")
            .accessibilityValue(trendSentence)

            caption
        }
    }

    // MARK: - グラフ

    private func chartBody(cap: Double) -> some View {
        Chart {
            // 選択行の帯。バーより先に置いて背面にする。バーの長さは行ごとに違うので、
            // 「どの行を選んだか」はプロット幅いっぱいの帯でないと伝わらない
            // （以前は左端の小さな丸だけで、実機で選択が分からなかった）。
            if let s = selected {
                RectangleMark(
                    xStart: .value("", chart.axisLo),
                    xEnd: .value("", chart.axisHi),
                    yStart: .value("", s.distanceStart),
                    yEnd: .value("", s.distanceEnd)
                )
                .foregroundStyle(Palette.selection)

                // 選択中のバーの縁取り。バーより先に置いて、バーがこの上に乗ることで
                // 外周だけが残る（RectangleMark に stroke が無いのでこの作り）。
                // 帯だけだと「選んだ行」は分かっても「選んだバー」が変わらないので、
                // どのラップを見ているのか分からない（実機フィードバック 2026-07-31）。
                RectangleMark(
                    xStart: .value("", chart.axisLo),
                    xEnd: .value("", s.pace100 + cap / 2),
                    yStart: .value("", s.distanceStart + gapMeters / 2 - outlineMeters),
                    yEnd: .value("", s.distanceEnd - gapMeters / 2 + outlineMeters)
                )
                .cornerRadius(Self.cornerRadius)
                .foregroundStyle(Palette.selectionOutline)
            }

            ForEach(chart.rows) { row in
                RectangleMark(
                    xStart: .value("", chart.axisLo),
                    xEnd: .value("ペース", row.pace100),
                    yStart: .value("", row.distanceStart + gapMeters / 2),
                    yEnd: .value("", row.distanceEnd - gapMeters / 2)
                )
                .cornerRadius(Self.cornerRadius)
                .foregroundStyle(row.isEmphasized ? Palette.emphasis : Palette.bar)

                RectangleMark(
                    xStart: .value("", chart.axisLo),
                    xEnd: .value("", min(chart.axisLo + cap, row.pace100)),
                    yStart: .value("", row.distanceStart + gapMeters / 2),
                    yEnd: .value("", row.distanceEnd - gapMeters / 2)
                )
                .foregroundStyle(row.isEmphasized ? Palette.emphasis : Palette.bar)
            }

            // 直接ラベルは「強調されたラップ」と「ベスト」だけ。全バーに数値は振らない。
            // 選択中の行だけは外す（同じ場所にツールチップが出て重なるため）。
            ForEach(labelled.filter { $0.id != selected?.id }) { row in
                RectangleMark(
                    xStart: .value("", row.pace100),
                    xEnd: .value("", row.pace100),
                    yStart: .value("", row.distanceMid),
                    yEnd: .value("", row.distanceMid)
                )
                .foregroundStyle(.clear)
                .annotation(position: .trailing, spacing: 4,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    Text(label(for: row))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(row.isEmphasized ? Palette.emphasis : Palette.muted)
                }
            }

            // インターバル境界（レスト）。セット境界は太さで区別する（色は同じ＝同じ意味だから）。
            ForEach(chart.boundaries) { b in
                RuleMark(y: .value("境界", b.distance))
                    .lineStyle(StrokeStyle(lineWidth: b.isBlock ? 2 : 1))
                    .foregroundStyle(Palette.rest)
                    // ラベルはプロットの内側（線の上・右寄せ）に置く。外側に出すと
                    // カードの右端で切れて "10:3…" になる。
                    .annotation(position: .top, alignment: .trailing, spacing: 1,
                                overflowResolution: .init(x: .fit(to: .plot),
                                                          y: .disabled)) {
                        Text(b.isBlock ? "\(fmtRest(b.rest)) レスト" : fmtRest(b.rest))
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                    }
            }

            RuleMark(x: .value("平均", chart.averagePace100))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .foregroundStyle(Palette.average)

            // 傾向線（回帰直線）は引かない。バーの右端の輪郭で既に読めるうえ、
            // 線を重ねると平均線・レスト線と合わせて3種類の線が交差して読みづらかった。
            // 「垂れているか」は下の一行（trendSentence）で言葉にする。

            // ツールチップは Chart の外（chartOverlay）に置く。Charts の annotation は
            // アクセシビリティツリーに出ないので、VoiceOver からも UI テストからも
            // 中身が読めなくなる（2026-07-31 に実機フィードバックで作り直したときに判明）。
        }
        .chartXScale(domain: chart.axisLo...chart.axisHi)
        .chartYScale(domain: [chart.totalMeters, 0])   // 上が 0m（泳ぎ進む向き）
        .chartXAxis {
            AxisMarks(position: .top, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Palette.muted.opacity(0.35))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(fmtPace(v)).font(.caption2).foregroundStyle(Palette.muted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .stride(by: 100)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Palette.muted.opacity(0.35))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(fmtMeters(v)).font(.caption2).foregroundStyle(Palette.muted)
                    }
                }
            }
        }
        .chartPlotStyle { $0.background(Palette.surface) }
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { loc in
                            select(at: loc, proxy: proxy, geo: geo)
                        }
                    if let s = selected, let anchor = proxy.plotFrame {
                        tooltip(for: s)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: TooltipSizeKey.self,
                                                       value: g.size)
                            })
                            .offset(tooltipOffset(for: s, in: geo[anchor], proxy: proxy))
                            // 触れてもツールチップ自身は反応せず、下のバーの選択解除に通す
                            .allowsHitTesting(false)
                    }
                }
                .onPreferenceChange(TooltipSizeKey.self) { tooltipSize = $0 }
            }
        }
    }

    // MARK: - ツールチップ

    /// バーの先端に出す吹き出し。ペースを主役にして、他は下に小さく1行でまとめる。
    private func tooltip(for row: PaceChart.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(row.id + 1)ラップ目・セット\(row.setNumber)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(fmtPace(row.pace100))
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                Text("/100m").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("\(String(format: "%.1f", row.duration))秒・\(row.strokes)ストローク・SWOLF \(Int(row.swolf.rounded(.down)))")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // バーの上に浮かせるので、下地は必ず不透明側に寄せる（material + 影）
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Palette.muted.opacity(0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("paceTooltip")
        .accessibilityLabel(detailSentence(for: row))
    }

    /// ツールチップの位置。**選択中のバーには絶対に重ねない**（重なると、いま見ている
    /// ラップそのものが隠れる。実機フィードバック 2026-07-31）。
    /// 既定はバー先端の右隣。遅いラップでバーが右端まで届いて入らない場合は、
    /// 先端の左へ倒す（＝バーに重なる）のではなく、**行の上下へ逃がす**。
    private func tooltipOffset(for row: PaceChart.Row,
                               in rect: CGRect,
                               proxy: ChartProxy) -> CGSize {
        let size = tooltipSize
        let tip = rect.minX + (proxy.position(forX: row.pace100) ?? 0)
        let rowTop = rect.minY + (proxy.position(forY: row.distanceStart) ?? 0)
        let rowBottom = rect.minY + (proxy.position(forY: row.distanceEnd) ?? 0)

        if tip + Self.tooltipGap + size.width <= rect.maxX {
            let mid = (rowTop + rowBottom) / 2
            return CGSize(width: tip + Self.tooltipGap,
                          height: clamp(mid - size.height / 2,
                                        rect.minY + 2, rect.maxY - size.height - 2))
        }

        // 右に入らないケース。右端に寄せたうえで、行の下 → 行の上 の順に逃がす。
        let x = max(rect.minX + 2, rect.maxX - size.width - 2)
        let below = rowBottom + Self.tooltipGap
        if below + size.height <= rect.maxY - 2 { return CGSize(width: x, height: below) }
        return CGSize(width: x,
                      height: max(rect.minY + 2, rowTop - Self.tooltipGap - size.height))
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), max(lo, hi))
    }

    private func detailSentence(for row: PaceChart.Row) -> String {
        "\(row.id + 1)ラップ目（セット\(row.setNumber)）・\(String(format: "%.1f", row.duration))秒・\(fmtPace(row.pace100))/100m・\(row.strokes)ストローク・SWOLF \(Int(row.swolf.rounded(.down)))"
    }

    // MARK: - グラフの下の一行

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trendSentence)
                .font(.footnote)
            // 詳細はツールチップ側に移した（下に出していた頃は実機で気づけなかった）。
            // ここには操作の案内だけを残す。
            Text(selected == nil ? "バーをタップするとラップの詳細が出ます"
                                 : "もう一度タップで選択を解除")
                .font(.caption)
                .foregroundStyle(.secondary)
            legend
            if let m = chart.distanceMismatch {
                Label("グラフは壁ベースの \(fmtMeters(chart.totalMeters))。レポートの距離とは \(fmtMeters(abs(m))) 違います（CROSS-CHECK）",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 問い1（ビルドアップか垂れか）に数字でも言い切る。
    private var trendSentence: String {
        if chart.isTrendFlat {
            return "セッションを通してほぼ一定（平均 \(fmtPace(chart.averagePace100))/100m）"
        }
        let d = chart.trendDelta
        let word = d > 0 ? "垂れ" : "ビルドアップ"
        return String(format: "後半にかけて %+.1fs/100m（%@）", d, word)
    }

    /// 線の意味は色だけに載せない（向きと言葉も添える）。
    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(Palette.average, "平均 \(fmtPace(chart.averagePace100))")
            if !chart.boundaries.isEmpty { legendItem(Palette.rest, "レスト") }
            if chart.rows.contains(where: \.isEmphasized) {
                legendItem(Palette.emphasis, "中央値から ±25%")
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 14, height: 2)
            Text(label)
        }
    }

    // MARK: - 補助

    /// ラベルを付けるラップ = 強調されたラップ + ベスト（重複は1つに）
    private var labelled: [PaceChart.Row] {
        var out = chart.rows.filter(\.isEmphasized)
        if let best = chart.best, !out.contains(best) { out.append(best) }
        return out
    }

    private func label(for row: PaceChart.Row) -> String {
        row.id == chart.best?.id ? "ベスト \(fmtPace(row.pace100))" : fmtPace(row.pace100)
    }

    private func select(at loc: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let anchor = proxy.plotFrame else { return }
        let rect = geo[anchor]
        guard rect.contains(loc),
              let meters = proxy.value(atY: loc.y - rect.minY, as: Double.self)
        else { return }
        let idx = Int((meters / chart.poolLength).rounded(.down))
        guard chart.rows.indices.contains(idx) else { return }
        selected = chart.rows[idx].id == selected?.id ? nil : chart.rows[idx]
    }

    /// レストの長さ → "45s" / "10:32"
    private func fmtRest(_ s: Double) -> String {
        let v = Int(s.rounded())
        return v < 60 ? "\(v)s" : String(format: "%d:%02d", v / 60, v % 60)
    }
}

private struct TooltipSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// docs/pace_chart_design.md の配色。ライト・ダークとも配色バリデータで全項目 PASS
/// （明度帯・彩度・色覚多様性の分離 ΔE・通常視 ΔE・背景コントラスト）。
/// **ダークは自動反転ではなく明示値**。値の大小で色は変えない（長さで既に表しているため）。
private enum Palette {
    static let bar = dynamic(light: 0x2a78d6, dark: 0x3987e5)
    static let emphasis = dynamic(light: 0xeb6834, dark: 0xd95926)
    /// 平均線（縦・1本だけなので強く出してよい）
    static let average = dynamic(light: 0xc0479f, dark: 0xcf62ad)
    /// レスト線（横に何本も出るので落ち着いた色にする）
    static let rest = dynamic(light: 0x2e9e6b, dark: 0x35a273)
    static let muted = Color(rgb: 0x898781)          // 両モード共通
    /// 選択行の帯。バーの色より薄く、かつ背景から確実に浮く濃さにする。
    static let selection = dynamic(light: 0xd8e6f7, dark: 0x2c3a4a)
    /// 選択中のバーの縁取り。バーの青とも帯とも見分けが付く強さが要るので、
    /// ライトは濃紺・ダークはほぼ白（どちらもバーに対して最もコントラストが出る側）。
    static let selectionOutline = dynamic(light: 0x0f2f52, dark: 0xdce9f7)
    static let surface = dynamic(light: 0xfcfcfb, dark: 0x1a1a19)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }
}

private extension Color {
    init(rgb: UInt32) { self.init(UIColor(rgb: rgb)) }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xff) / 255,
                  green: Double((rgb >> 8) & 0xff) / 255,
                  blue: Double(rgb & 0xff) / 255,
                  alpha: 1)
    }
}
