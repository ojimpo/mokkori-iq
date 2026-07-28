import Foundation

/// レポート画面のペースグラフ（docs/pace_chart_design.md）のデータモデル。
///
/// 描画は SwiftUI 側（PaceChartView）だが、**軸の切り方・異常値判定・傾向線**は
/// 見た目ではなく解析の話なのでここに置く（＝ Xcode 無しでテストできる）。
///
/// グラフが答えるべき問いは2つだけ:
///   1. 1000m を通してビルドアップできているか、垂れていくか → 右端の輪郭
///   2. 異常値が一目で分かるか                                → 強調色 + 直接ラベル
public struct PaceChart {

    /// 1ラップ = 1バー。
    public struct Row: Identifiable, Equatable {
        public let id: Int             // 通し番号（0-based）
        public let setNumber: Int      // 1-based セット番号
        public let interval: Int       // 1-based インターバル番号
        public let number: Int         // 1-based インターバル内のラップ番号
        public let span: Span
        public let strokes: Int
        /// バーが占める距離帯 [start, end]（m）。連続軸なので実距離で置く。
        public let distanceStart: Double
        public let distanceEnd: Double
        public let duration: Double
        public let pace100: Double     // s /100m
        /// セット中央値から ±25% 外れたラップ（＝見てほしいラップ。良し悪しの評価ではない）
        public let isOutlier: Bool
        /// ラップ確認画面と同じ疑い（見逃し / 偽壁）。異常値と同じ強調で出す。
        public let suspect: WallInterval.Flag

        public var distanceMid: Double { (distanceStart + distanceEnd) / 2 }
        public var swolf: Double { duration + Double(strokes) }
        /// 強調するかどうか（色 + 直接ラベル）
        public var isEmphasized: Bool { isOutlier || suspect != .ok }
    }

    /// インターバルの境界（レスト）。距離軸上の水平ヘアラインとして引く。
    public struct Boundary: Identifiable, Equatable {
        public let id: Int
        public let distance: Double    // m（この位置に線を引く）
        public let rest: Double        // s（レストの長さ）
        public let isBlock: Bool       // true = セット境界（大休憩）
    }

    public let rows: [Row]
    public let boundaries: [Boundary]
    public let poolLength: Double
    public let totalMeters: Double
    /// 基準線。レポート上部と食い違わないよう report.pace100 をそのまま使う
    /// （ラップごとの平均を取り直さない）。
    public let averagePace100: Double
    /// 横軸（s /100m）。0 起点にしない理由と最低幅の根拠は設計ドキュメント参照。
    public let axisLo: Double
    public let axisHi: Double
    /// 傾向線（ペース vs 距離の線形回帰）を距離 0 と totalMeters で評価した値
    public let trendAtStart: Double
    public let trendAtEnd: Double
    public let best: Row?
    /// report.distance と `rows.count * pool` が食い違う場合の差（m）。
    /// min(壁, ペース) が効いたセッションで出る。黙って辻褄を合わせず注記する。
    public let distanceMismatch: Double?

    /// セッションを通したペースの変化量（s /100m）。正 = 垂れ、負 = ビルドアップ。
    public var trendDelta: Double { trendAtEnd - trendAtStart }

    /// 傾向が「ほぼ一定」と言える範囲（s /100m）。1ラップ数秒の揺れは傾向ではない。
    public static let flatTrendTolerance = 2.0
    public var isTrendFlat: Bool { abs(trendDelta) < Self.flatTrendTolerance }

    // MARK: - 構築

    /// 異常値の判定はセット中央値の倍率。ラップ確認画面の 1.6 / 0.6 とは別の値だが、
    /// あちらは「泳ぎギャップ」で壁の有無を疑う基準、こちらは「ラップのペース」で
    /// 目を留めさせる基準なので役割が違う（疑いが付いたラップは下で必ず強調される）。
    static let slowFactor = 1.25
    static let fastFactor = 0.75
    /// 軸の余白と、均一なセッションで拡大しすぎないための最低幅（平均 ± これ）。
    static let axisPadding = 0.04
    static let axisMinHalfWidth = 10.0

    public static func make(report: SwimReport, detection: WallDetection) -> PaceChart {
        let pool = report.poolLength

        // 確認画面の疑いフラグを壁の開始時刻で引けるようにする。
        // ラップの span.end は（インターバル最終ラップを除いて）その壁の start と一致する。
        var suspectByWallStart = [Double: WallInterval.Flag]()
        for r in WallIntervalTable.rows(for: detection) where r.flag != .ok {
            if let w = r.wall { suspectByWallStart[w.start] = r.flag }
        }

        // 異常値の基準はセット単位（ウォームアップとメインで基準が変わるため）
        var medianBySet = [Int: Double]()
        for setNumber in Set(report.laps.map(\.setNumber)) {
            let paces = report.laps.filter { $0.setNumber == setNumber }
                .map { $0.duration / pool * 100 }
            if !paces.isEmpty { medianBySet[setNumber] = Stats.median(paces) }
        }

        var rows = [Row]()
        var boundaries = [Boundary]()
        for (i, l) in report.laps.enumerated() {
            let pace = l.duration / pool * 100
            let med = medianBySet[l.setNumber] ?? pace
            let outlier = med > 0 && (pace > slowFactor * med || pace < fastFactor * med)
            rows.append(Row(id: i, setNumber: l.setNumber, interval: l.interval,
                            number: l.number,
                            span: l.span, strokes: l.strokes,
                            distanceStart: Double(i) * pool,
                            distanceEnd: Double(i + 1) * pool,
                            duration: l.duration, pace100: pace,
                            isOutlier: outlier,
                            suspect: suspectByWallStart[l.span.end] ?? .ok))

            if i + 1 < report.laps.count {
                let next = report.laps[i + 1]
                if next.interval != l.interval || next.setNumber != l.setNumber {
                    boundaries.append(Boundary(id: boundaries.count,
                                               distance: Double(i + 1) * pool,
                                               rest: next.span.start - l.span.end,
                                               isBlock: next.setNumber != l.setNumber))
                }
            }
        }

        let total = Double(rows.count) * pool
        let avg = report.pace100
        let paces = rows.map(\.pace100)
        var lo = (paces.min() ?? avg), hi = (paces.max() ?? avg)
        let pad = max(1.0, (hi - lo) * axisPadding)
        lo = min(lo - pad, avg - axisMinHalfWidth)
        hi = max(hi + pad, avg + axisMinHalfWidth)

        // 傾向線: ペース(y) vs 距離(x) の最小二乗
        var slope = 0.0, intercept = avg
        if rows.count >= 2 {
            let xs = rows.map(\.distanceMid)
            let mx = xs.reduce(0, +) / Double(rows.count)
            let my = paces.reduce(0, +) / Double(rows.count)
            var sxy = 0.0, sxx = 0.0
            for (x, y) in zip(xs, paces) {
                sxy += (x - mx) * (y - my)
                sxx += (x - mx) * (x - mx)
            }
            if sxx > 0 {
                slope = sxy / sxx
                intercept = my - slope * mx
            }
        }

        let mismatch = abs(report.distance - total) > 0.5 ? report.distance - total : nil

        return PaceChart(rows: rows, boundaries: boundaries, poolLength: pool,
                         totalMeters: total, averagePace100: avg,
                         axisLo: lo, axisHi: hi,
                         trendAtStart: intercept,
                         trendAtEnd: intercept + slope * total,
                         best: rows.min { $0.duration < $1.duration },
                         distanceMismatch: mismatch)
    }
}
