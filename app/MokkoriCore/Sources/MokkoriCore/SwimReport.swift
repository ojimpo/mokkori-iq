import Foundation

/// analysis/swim_report.py の距離/ペース/インターバル内訳計算の Swift 移植。
/// SPM（ストローク率）は Phase A では後回し（プランどおり）。
///
/// 用語は Garmin 日本語と水泳の練習用語に合わせている:
///   - **ラップ** = プールの片道（25m）。Garmin の "length" に相当する単位。
///   - **インターバル** = レストで区切られた連続泳ぎ区間（Garmin の定義そのまま）。
///   - **セット** = 大休憩（big-rest）で区切られた塊。水泳の練習で言う「セット」。
public struct SwimReport {

    /// レストで区切られた連続泳ぎ区間。
    public struct Interval {
        public let setNumber: Int     // 1-based セット番号
        public let number: Int        // 1-based セット内のインターバル番号
        public let span: Span         // 泳ぎ区間 [s0, s1]
        public let swimTime: Double   // prone（うつ伏せ）実泳ぎ時間
        public let wallCount: Int     // 壁カウント由来のラップ数
        public let paceCount: Int     // ペース推定由来のラップ数
        public let laps: Int          // 採用ラップ数 = max(1, min(wall, pace))
        /// 2系統が食い違った（min() が効いた）= 検出ずれの警告対象
        public var crossCheck: Bool { wallCount != paceCount }
    }

    /// 大休憩で区切られたセットの集計。
    public struct SetSummary {
        public let index: Int         // 1-based（泳ぎのあるセットだけを数える）
        public let distance: Double   // m
        public let movingTime: Double // s
        public let pace100: Double    // s /100m
    }

    /// 1ラップ（壁を蹴ってから次の壁到着まで）。ガーミン互換メトリクスの単位。
    public struct Lap {
        public let setNumber: Int     // 1-based セット番号
        public let interval: Int      // 1-based インターバル番号
        public let number: Int        // 1-based インターバル内のラップ番号
        public let span: Span
        public let strokes: Int       // ロールサイクル数 = ガーミンのストローク数
        public var duration: Double { span.duration }
        public var swolf: Double { duration + Double(strokes) }
    }

    public let typicalLapTime: Double
    public let poolLength: Double
    public let intervals: [Interval]
    public let sets: [SetSummary]
    public let laps: [Lap]
    public let distance: Double       // m
    public let movingTime: Double     // s（泳ぎのみ）
    public let elapsed: Double        // s（休憩込み）
    public var pace100: Double { distance > 0 ? movingTime / distance * 100 : 0 }

    // ラップごとメトリクスの集計（strokes>0 のラップだけ。0 = 計測不能は除外）
    public var strokedLaps: [Lap] { laps.filter { $0.strokes > 0 } }
    public var strokesTotal: Int { laps.reduce(0) { $0 + $1.strokes } }
    public var strokesPerLapMedian: Double? {
        let s = strokedLaps
        return s.isEmpty ? nil : Stats.median(s.map { Double($0.strokes) })
    }
    public var swolfAverage: Double? {
        let s = strokedLaps
        return s.isEmpty ? nil : s.reduce(0.0) { $0 + $1.swolf } / Double(s.count)
    }
    public var swolfBest: Double? { strokedLaps.map(\.swolf).min() }
    public var bestLap: Lap? { strokedLaps.min { $0.duration < $1.duration } }
    /// 1ストロークで進む距離 (m/cycle)
    public var dps: Double? {
        guard let m = strokesPerLapMedian, m > 0 else { return nil }
        return poolLength / m
    }
}

public enum SwimReporter {

    /// 1ラップあたりの標準タイム: ターン間ギャップ（立ち終わり→次の立ち始まり）の
    /// prone 時間の中央値（15〜45s のものだけ採用。無ければ 31.0s）。
    static func typicalLapTime(t: [Double], prone: [Bool], dt: [Double],
                                  turns: [Span], lo: Double = 15.0,
                                  hi: Double = 45.0) -> Double {
        let ts = turns.sorted()
        var gaps = [Double]()
        for k in 0..<(max(ts.count, 1) - 1) {
            let a1 = ts[k].end, b0 = ts[k + 1].start
            var st = 0.0
            for i in 0..<t.count where t[i] >= a1 && t[i] <= b0 && prone[i] {
                st += dt[i]
            }
            if st >= lo && st <= hi { gaps.append(st) }
        }
        return gaps.isEmpty ? 31.0 : Stats.median(gaps)
    }

    /// [bs, be] 内の泳ぎ区間を rest で分割（rest がインターバルの境界）。
    static func swimSegments(bs: Double, be: Double, rests: [Span]) -> [Span] {
        var pts = [bs]
        for r in rests.filter({ bs <= $0.start && $0.start <= be }).sorted() {
            pts.append(r.start)
            pts.append(r.end)
        }
        pts.append(be)
        var out = [Span]()
        var i = 0
        while i + 1 < pts.count {
            out.append(Span(pts[i], pts[i + 1]))
            i += 2
        }
        return out
    }

    /// swim_report.py の main 計算部と同一。
    /// - laps = max(1, min(壁カウント, round(泳ぎ時間 / 1ラップの標準タイム)))
    ///   min() はバイアスではなく物理制約（詳細は CLAUDE.md メトリクス算出方針）。
    public static func makeReport(_ sess: SwimSession, detection d: WallDetection,
                                  pool: Double = 25.0) -> SwimReport {
        let t = sess.t
        var dt = [Double](repeating: 0, count: t.count)
        for i in 1..<t.count { dt[i] = t[i] - t[i - 1] }

        var prone = [Bool](repeating: false, count: t.count)
        for i in 0..<t.count { prone[i] = d.gz[i] < -2.0 }  // うつ伏せ=泳いでいる

        let Lt = typicalLapTime(t: t, prone: prone, dt: dt, turns: d.turns)
        let coeffs = StrokeCounter.bandpassCoeffs(fs: sess.fs)

        /// t は単調増加なので [lo, hi] のマスクは連続区間 → 二分探索で範囲を取る
        func indexRange(_ lo: Double, _ hi: Double) -> Range<Int>? {
            var a = 0, b = t.count
            while a < b {
                let m = (a + b) / 2
                if t[m] < lo { a = m + 1 } else { b = m }
            }
            let start = a
            var c = start, dHi = t.count
            while c < dHi {
                let m = (c + dHi) / 2
                if t[m] <= hi { c = m + 1 } else { dHi = m }
            }
            return start < c ? start..<c : nil
        }

        var intervals = [SwimReport.Interval]()
        var laps = [SwimReport.Lap]()
        var sets = [SwimReport.SetSummary]()
        var totalLen = 0
        var totalSwim = 0.0
        // セット番号は「泳ぎのあるブロック」だけを 1 から数える。検出ブロックの通し番号を
        // そのまま使うと、入水前やシャワーの泳ぎゼロのブロックが番号を食って
        // 「セット2 / セット3」から始まってしまう。
        var setNumber = 0
        for (bs, be) in zip(d.blockStarts, d.blockEnds) {
            var hl = 0
            var hs = 0.0
            var blockIntervals = [SwimReport.Interval]()
            var blockLaps = [SwimReport.Lap]()
            for (ri, seg) in swimSegments(bs: bs, be: be, rests: d.rests).enumerated() {
                var st = 0.0
                for i in 0..<t.count
                where t[i] >= seg.start && t[i] <= seg.end && prone[i] {
                    st += dt[i]
                }
                if st < 8.0 { continue }  // 入水前/ボビング等の偽区間を除外
                let wallLen = d.turns.filter {
                    seg.start <= $0.start && $0.start <= seg.end
                }.count + 1
                // Python round() = 偶数丸め（banker's rounding）に合わせる
                let paceLen = Int((st / Lt).rounded(.toNearestOrEven))
                let n = max(1, min(wallLen, paceLen))
                hl += n
                hs += st
                blockIntervals.append(
                    SwimReport.Interval(setNumber: 0, number: ri + 1, span: seg,
                                        swimTime: st, wallCount: wallLen,
                                        paceCount: paceLen, laps: n))
                for (li, ls) in StrokeCounter.lapSpans(
                        s0: seg.start, s1: seg.end, turns: d.turns).enumerated() {
                    guard let r = indexRange(ls.start, ls.end) else { continue }
                    let strokes = StrokeCounter.countStrokes(
                        gx: sess.gx[r], gy: sess.gy[r], gz: sess.gz[r],
                        prone: prone[r], coeffs: coeffs)
                    blockLaps.append(SwimReport.Lap(setNumber: 0, interval: ri + 1,
                                                    number: li + 1, span: ls,
                                                    strokes: strokes))
                }
            }
            if hl > 0 {
                setNumber += 1
                let dist = Double(hl) * pool
                sets.append(SwimReport.SetSummary(index: setNumber, distance: dist,
                                                  movingTime: hs,
                                                  pace100: hs / dist * 100))
                intervals += blockIntervals.map {
                    SwimReport.Interval(setNumber: setNumber, number: $0.number,
                                        span: $0.span, swimTime: $0.swimTime,
                                        wallCount: $0.wallCount,
                                        paceCount: $0.paceCount, laps: $0.laps)
                }
                laps += blockLaps.map {
                    SwimReport.Lap(setNumber: setNumber, interval: $0.interval,
                                   number: $0.number, span: $0.span,
                                   strokes: $0.strokes)
                }
                totalLen += hl
                totalSwim += hs
            }
        }

        return SwimReport(typicalLapTime: Lt,
                          poolLength: pool,
                          intervals: intervals,
                          sets: sets,
                          laps: laps,
                          distance: Double(totalLen) * pool,
                          movingTime: totalSwim,
                          elapsed: t.isEmpty ? 0 : t[t.count - 1] - t[0])
    }
}
