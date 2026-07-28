import Foundation

/// analysis/swim_report.py の距離/ペース/レップ内訳計算の Swift 移植。
/// SPM（ストローク率）は Phase A では後回し（プランどおり）。
public struct SwimReport {
    public struct Rep {
        public let half: Int          // 1-based ブロック番号
        public let rep: Int           // 1-based ブロック内レップ番号
        public let span: Span         // 泳ぎ区間 [s0, s1]
        public let swimTime: Double   // prone（うつ伏せ）実泳ぎ時間
        public let wallCount: Int     // 壁カウント由来の本数
        public let paceCount: Int     // ペース推定由来の本数
        public let lengths: Int       // 採用本数 = max(1, min(wall, pace))
        /// 2系統が食い違った（min() が効いた）= 検出ずれの警告対象
        public var crossCheck: Bool { wallCount != paceCount }
    }

    public struct Half {
        public let index: Int         // 1-based
        public let distance: Double   // m
        public let movingTime: Double // s
        public let pace100: Double    // s /100m
    }

    public let typicalLengthTime: Double
    public let poolLength: Double
    public let reps: [Rep]
    public let halves: [Half]
    public let distance: Double       // m
    public let movingTime: Double     // s（泳ぎのみ）
    public let elapsed: Double        // s（休憩込み）
    public var pace100: Double { distance > 0 ? movingTime / distance * 100 : 0 }
}

public enum SwimReporter {

    /// 1本あたりの典型泳ぎ時間: ターン間ギャップ（立ち終わり→次の立ち始まり）の
    /// prone 時間の中央値（15〜45s のものだけ採用。無ければ 31.0s）。
    static func typicalLengthTime(t: [Double], prone: [Bool], dt: [Double],
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

    /// [bs, be] 内の泳ぎ区間を rest で分割（rest がレップ境界）。
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
    /// - lengths = max(1, min(壁カウント, round(泳ぎ時間 / 典型1本時間)))
    ///   min() はバイアスではなく物理制約（詳細は CLAUDE.md メトリクス算出方針）。
    public static func makeReport(_ sess: SwimSession, detection d: WallDetection,
                                  pool: Double = 25.0) -> SwimReport {
        let t = sess.t
        var dt = [Double](repeating: 0, count: t.count)
        for i in 1..<t.count { dt[i] = t[i] - t[i - 1] }

        var prone = [Bool](repeating: false, count: t.count)
        for i in 0..<t.count { prone[i] = d.gz[i] < -2.0 }  // うつ伏せ=泳いでいる

        let Lt = typicalLengthTime(t: t, prone: prone, dt: dt, turns: d.turns)

        var reps = [SwimReport.Rep]()
        var halves = [SwimReport.Half]()
        var totalLen = 0
        var totalSwim = 0.0
        for (hi, (bs, be)) in zip(d.blockStarts, d.blockEnds).enumerated() {
            var hl = 0
            var hs = 0.0
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
                reps.append(SwimReport.Rep(half: hi + 1, rep: ri + 1, span: seg,
                                           swimTime: st, wallCount: wallLen,
                                           paceCount: paceLen, lengths: n))
            }
            if hl > 0 {
                let dist = Double(hl) * pool
                halves.append(SwimReport.Half(index: hi + 1, distance: dist,
                                              movingTime: hs,
                                              pace100: hs / dist * 100))
                totalLen += hl
                totalSwim += hs
            }
        }

        return SwimReport(typicalLengthTime: Lt,
                          poolLength: pool,
                          reps: reps,
                          halves: halves,
                          distance: Double(totalLen) * pool,
                          movingTime: totalSwim,
                          elapsed: t.isEmpty ? 0 : t[t.count - 1] - t[0])
    }
}
