import Foundation

/// 時刻区間 [start, end]（秒）。立ちエピソード・タップ等の表現。
public struct Span: Codable, Equatable, Hashable, Comparable {
    public let start: Double
    public let end: Double

    public init(_ start: Double, _ end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
    public var mid: Double { (start + end) / 2 }

    /// Python の (a, b) タプル比較と同じ辞書式順序。
    public static func < (l: Span, r: Span) -> Bool {
        l.start != r.start ? l.start < r.start : l.end < r.end
    }
}

/// analysis/turn_stand.py detect_walls() の結果と同型。
public struct WallDetection {
    /// 向き非依存 verticality 信号（旧 gz スケール: 泳ぎ -7.5 ↔ 立位 +9.5）
    public let gz: [Double]
    public let turns: [Span]
    public let rests: [Span]
    public let bigs: [Span]
    public let taps: [Span]
    public let triples: [Span]
    public let recovered: [Span]
    /// ブロック（big-rest 区切り）の開始/終了時刻
    public let blockStarts: [Double]
    public let blockEnds: [Double]
}

/// analysis/turn_stand.py の Swift 移植。数値挙動は Python (numpy) と一致させる。
public enum WallDetector {

    /// 指数移動平均。s0 = x[0]、a = 1 - exp(-1/(tau*fs))。
    public static func ema(_ x: [Double], fs: Double, tau: Double) -> [Double] {
        let a = 1.0 - exp(-1.0 / (tau * fs))
        var out = [Double](repeating: 0, count: x.count)
        guard !x.isEmpty else { return out }
        var s = x[0]
        for i in 0..<x.count {
            s += a * (x[i] - s)
            out[i] = s
        }
        return out
    }

    /// mask の連続 True 区間のうち t[j-1]-t[i] >= minDur のもの。(start, end, peak)。
    static func episodes(mask: [Bool], t: [Double], sig: [Double],
                         minDur: Double) -> [(Double, Double, Double)] {
        var out: [(Double, Double, Double)] = []
        var i = 0
        let n = mask.count
        while i < n {
            if mask[i] {
                var j = i
                while j < n && mask[j] { j += 1 }
                if t[j - 1] - t[i] >= minDur {
                    var pk = sig[i]
                    for k in i..<j where sig[k] > pk { pk = sig[k] }
                    out.append((t[i], t[j - 1], pk))
                }
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    /// mask の連続 True 区間を (i, j) index ペアで（j は排他）。
    static func indexRuns(_ mask: [Bool]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var i = 0
        let n = mask.count
        while i < n {
            if mask[i] {
                var j = i
                while j < n && mask[j] { j += 1 }
                out.append((i, j))
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    /// 向き非依存の「体軸が垂直」信号。セッション内で自己キャリブレーションし、
    /// 泳ぎ→立位軸への射影を旧 gz スケール（泳ぎ -7.5 ↔ 立位 +9.5）に正規化。
    /// 詳細は turn_stand.verticality() の docstring 参照（壁立ちアンカーが要点）。
    public static func verticality(_ sess: SwimSession, tau: Double = 1.0) -> [Double] {
        let n = sess.count
        let fs = sess.fs
        let ex = ema(sess.ax, fs: fs, tau: tau)
        let ey = ema(sess.ay, fs: fs, tau: tau)
        let ez = ema(sess.az, fs: fs, tau: tau)

        var gyroNorm = [Double](repeating: 0, count: n)
        for i in 0..<n {
            gyroNorm[i] = (sess.gx[i] * sess.gx[i] + sess.gy[i] * sess.gy[i]
                           + sess.gz[i] * sess.gz[i]).squareRoot()
        }
        let act = ema(gyroNorm, fs: fs, tau: 2.0)

        let actThr = Stats.percentile(act, 60)
        var swimX = [Double](), swimY = [Double](), swimZ = [Double]()
        for i in 0..<n where act[i] > actThr {
            swimX.append(ex[i]); swimY.append(ey[i]); swimZ.append(ez[i])
        }
        let gSwim = [Stats.median(swimX), Stats.median(swimY), Stats.median(swimZ)]

        var dev = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let dx = ex[i] - gSwim[0], dy = ey[i] - gSwim[1], dz = ez[i] - gSwim[2]
            dev[i] = (dx * dx + dy * dy + dz * dz).squareRoot()
        }
        let ref = Stats.percentile(dev, 99.0)
        let devThr = 0.55 * ref
        var devMask = [Bool](repeating: false, count: n)
        for i in 0..<n { devMask[i] = dev[i] > devThr }
        let runs = indexRuns(devMask)
        var peaks = [Int]()
        var shortPeaks = [Int]()
        for (i, j) in runs {
            var p = i
            for k in i..<j where dev[k] > dev[p] { p = k }
            peaks.append(p)
            let d = sess.t[j - 1] - sess.t[i]
            if d >= 1.2 && d <= 7.0 { shortPeaks.append(p) }
        }
        let anchor = shortPeaks.count >= 3 ? shortPeaks : peaks
        if anchor.isEmpty {
            // 退化ケース: 一度も立たなかった → 素の az EMA を返す
            return ema(sess.az, fs: fs, tau: tau)
        }
        let gStand = [Stats.median(anchor.map { ex[$0] }),
                      Stats.median(anchor.map { ey[$0] }),
                      Stats.median(anchor.map { ez[$0] })]

        let ux = gStand[0] - gSwim[0], uy = gStand[1] - gSwim[1], uz = gStand[2] - gSwim[2]
        let scale = (ux * ux + uy * uy + uz * uz).squareRoot()
        var out = [Double](repeating: 0, count: n)
        let k = 17.0 / scale
        for i in 0..<n {
            let v = ((ex[i] - gSwim[0]) * ux + (ey[i] - gSwim[1]) * uy
                     + (ez[i] - gSwim[2]) * uz) / scale
            out[i] = -7.5 + v * k
        }
        return out
    }

    /// turn_stand.detect_walls() と同一のロジック:
    /// エピソード分類 → デフラグ (union) → リズムリカバリ → タップ三連。
    public static func detectWalls(_ sess: SwimSession,
                                   thr: Double = 2.0,
                                   vthr: Double = 5.0,
                                   refractory: Double = 12.0,
                                   tau: Double = 1.0) -> WallDetection {
        let t = sess.t
        let gz = verticality(sess, tau: tau)
        var mask = [Bool](repeating: false, count: gz.count)
        for i in 0..<gz.count { mask[i] = gz[i] > thr }
        let eps = episodes(mask: mask, t: t, sig: gz, minDur: 0.8)

        // 分類: 本物の立位はピーク gz > vthr に達する（水中ボビング除外）
        var taps = [Span](), turnsE = [Span](), rests = [Span](), bigs = [Span]()
        for (a, b, pk) in eps {
            let d = b - a
            if d >= 90.0 {
                bigs.append(Span(a, b))
            } else if d >= 7.0 && pk > vthr {
                rests.append(Span(a, b))
            } else if d < 1.2 {
                taps.append(Span(a, b))
            } else if pk > vthr {
                turnsE.append(Span(a, b))
            }
            // else: 短い＆垂直に達しない = ボビング/ノイズ → 破棄
        }

        // デフラグ: refractory 未満で連続する立ちエピソードは同一の壁として union
        // （立ちの真の終了時刻を保つ。旧 drop 方式との違いが min() 不発の根拠）
        var merged = [Span]()
        for s in (turnsE + rests + bigs).sorted() {
            if let last = merged.last, s.start - last.end < refractory {
                merged[merged.count - 1] = Span(last.start, max(last.end, s.end))
            } else {
                merged.append(s)
            }
        }
        var turns = [Span]()
        rests = []; bigs = []
        for s in merged {
            if s.duration >= 90.0 { bigs.append(s) }
            else if s.duration >= 7.0 { rests.append(s) }
            else { turns.append(s) }
        }

        // リズムリカバリ: ブロック内の壁は準等間隔。泳ぎギャップ（立ち終わり→
        // 次の立ち始まり）が中央値の 1.6〜2.6 倍で、中間に閾値未満の明確な姿勢
        // 変化（gz > 0）があれば 1 壁補完。壁 6 本未満のブロックは対象外。
        let blockStarts = [t[0]] + bigs.map { $0.end }
        let blockEnds = bigs.map { $0.start } + [t[t.count - 1]]
        let wallsAll = (turns + rests).sorted()
        var recovered = [Span]()
        for (bs, be) in zip(blockStarts, blockEnds) {
            let w = wallsAll.filter { bs <= $0.start && $0.start <= be }
            if w.count < 6 { continue }
            var gaps = [Double]()
            for k in 0..<(w.count - 1) { gaps.append(w[k + 1].start - w[k].end) }
            let med = Stats.median(gaps)
            for k in 0..<(w.count - 1) {
                let g = gaps[k]
                guard g >= 1.6 * med && g <= 2.6 * med else { continue }
                let lo = w[k].end + 0.3 * g
                let hi = w[k].end + 0.7 * g
                var best = -1
                for i in 0..<t.count where t[i] >= lo && t[i] <= hi {
                    if best < 0 || gz[i] > gz[best] { best = i }
                }
                guard best >= 0, gz[best] > 0.0 else { continue }
                recovered.append(Span(t[best] - 0.5, t[best] + 0.5))
            }
        }
        turns = (turns + recovered).sorted()

        // タップ三連: 4 秒以内に 3 個以上のタップブリップ
        var triples = [Span]()
        var i = 0
        while i < taps.count {
            var j = i
            while j + 1 < taps.count && taps[j + 1].start - taps[i].start < 4.0 { j += 1 }
            if j - i + 1 >= 3 {
                triples.append(Span(taps[i].start, taps[j].end))
                i = j + 1
            } else {
                i += 1
            }
        }

        return WallDetection(gz: gz, turns: turns, rests: rests, bigs: bigs,
                             taps: taps, triples: triples, recovered: recovered,
                             blockStarts: blockStarts, blockEnds: blockEnds)
    }
}
