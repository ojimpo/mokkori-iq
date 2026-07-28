import SwiftUI
import Charts
import MokkoriCore

/// 本ごとのペースを距離順に並べた横バーグラフ（設計は docs/pace_chart_design.md）。
///
/// 縦軸 = 距離（上 0m → 下）で泳ぎ進む向きと同じ。1本 = 1バーで**左端揃え**なので、
/// 右端の輪郭がそのままペースの推移になる。上から下へ目で追って、
/// 短くなっていけばビルドアップ、伸びていけば垂れ。
struct PaceChartView: View {
    let chart: PaceChart
    @State private var selected: PaceChart.Row?

    /// 1本の帯 = バー 10pt + 隙間 2pt。**セッションによらず固定**にする
    /// （縮めて全部を1画面に押し込むと、バーの太さが変わって比較できなくなる）。
    private static let band = 12.0
    private static let barGap = 2.0
    /// 横軸ラベル（上端）と余白のぶん
    private static let axisBand = 32.0
    private static let cornerRadius = 4.0
    /// y 軸ラベルの帯（バーの実幅を出すための概算。角丸の詰め物にしか使わない）
    private static let yAxisBand = 52.0

    private var plotHeight: Double { Double(chart.rows.count) * Self.band }
    /// 隙間 2pt を距離（m）に換算した値。バーの上下をこのぶん詰める。
    private var gapMeters: Double { chart.poolLength * Self.barGap / Self.band }

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
            .accessibilityLabel("本ごとのペース")
            .accessibilityValue(trendSentence)

            caption
        }
    }

    // MARK: - グラフ

    private func chartBody(cap: Double) -> some View {
        Chart {
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

            // 直接ラベルは「強調された本」と「ベスト」だけ。全バーに数値は振らない。
            ForEach(labelled) { row in
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

            // レップ境界（休憩）。ブロック境界は少し強く。
            ForEach(chart.boundaries) { b in
                RuleMark(y: .value("境界", b.distance))
                    .lineStyle(StrokeStyle(lineWidth: b.isBlock ? 1.5 : 1))
                    .foregroundStyle(Palette.muted.opacity(b.isBlock ? 0.9 : 0.45))
                    // ラベルはプロットの内側（線の上・右寄せ）に置く。外側に出すと
                    // カードの右端で切れて "10:3…" になる。
                    .annotation(position: .top, alignment: .trailing, spacing: 1,
                                overflowResolution: .init(x: .fit(to: .plot),
                                                          y: .disabled)) {
                        Text(b.isBlock ? "\(fmtRest(b.rest)) 休憩" : fmtRest(b.rest))
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                    }
            }

            RuleMark(x: .value("平均", chart.averagePace100))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(Palette.muted)

            // 傾向線（ペース vs 距離の線形回帰）。問い「垂れているか」に直接答える。
            LineMark(x: .value("傾向", chart.trendAtStart), y: .value("", 0.0),
                     series: .value("", "trend"))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .foregroundStyle(Palette.muted.opacity(0.8))
            LineMark(x: .value("傾向", chart.trendAtEnd),
                     y: .value("", chart.totalMeters), series: .value("", "trend"))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .foregroundStyle(Palette.muted.opacity(0.8))

            if let s = selected {
                PointMark(x: .value("", chart.axisLo), y: .value("", s.distanceMid))
                    .symbol(.circle)
                    .symbolSize(60)
                    .foregroundStyle(Palette.bar)
            }
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
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { loc in
                        select(at: loc, proxy: proxy, geo: geo)
                    }
            }
        }
    }

    // MARK: - グラフの下の一行

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trendSentence)
                .font(.footnote)
            if let s = selected {
                Text("\(s.id + 1)本目（半\(s.half) R\(s.rep) L\(s.num)）・\(String(format: "%.1f", s.duration))s・\(fmtPace(s.pace100))/100m・\(s.strokes)ストローク・SWOLF \(Int(s.swolf.rounded(.down)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("バーをタップすると、その本の詳細が出ます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(legendSentence)
                .font(.caption2)
                .foregroundStyle(.secondary)
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

    private var legendSentence: String {
        let base = "縦線 = 平均・細い斜線 = 傾向・横線 = 休憩"
        return chart.rows.contains(where: \.isEmphasized)
            ? base + "・橙 = ブロック中央値から ±25% 外れた本"
            : base
    }

    // MARK: - 補助

    /// ラベルを付ける本 = 強調された本 + ベスト（重複は1つに）
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

    /// ペース（s /100m）→ "1:53"。軸ラベルなので小数は落とす。
    private func fmtPace(_ s: Double) -> String {
        let v = Int(s.rounded())
        return String(format: "%d:%02d", v / 60, v % 60)
    }

    /// 休憩時間 → "45s" / "10:32"
    private func fmtRest(_ s: Double) -> String {
        let v = Int(s.rounded())
        return v < 60 ? "\(v)s" : String(format: "%d:%02d", v / 60, v % 60)
    }
}

/// docs/pace_chart_design.md の配色。ライト・ダークとも配色バリデータで全項目 PASS
/// （明度帯・彩度・色覚多様性の分離 ΔE・通常視 ΔE・背景コントラスト）。
/// **ダークは自動反転ではなく明示値**。値の大小で色は変えない（長さで既に表しているため）。
private enum Palette {
    static let bar = dynamic(light: 0x2a78d6, dark: 0x3987e5)
    static let emphasis = dynamic(light: 0xeb6834, dark: 0xd95926)
    static let muted = Color(rgb: 0x898781)          // 両モード共通
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
