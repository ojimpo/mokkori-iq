import Foundation

/// 本ごとストローク数（ガーミン互換）。swim_report.py の
/// bandpass_coeffs / biquad_filter / count_strokes / length_spans と同一算術。
/// 股間デバイスは体ロール（左右1往復=1サイクル）がジャイロに乗り、これが
/// ガーミンの「時計側の腕のストローク数」と 1:1 で同じ土俵になる。
public enum StrokeCounter {

    public static let strokeBand = (lo: 0.3, hi: 1.2)   // ストロークサイクル帯域 (Hz)

    /// RBJ constant-peak-gain バンドパス biquad（正規化済み係数）。
    public struct BiquadCoeffs {
        public let b0, b1, b2, a1, a2: Double
    }

    public static func bandpassCoeffs(fs: Double,
                                      lo: Double = strokeBand.lo,
                                      hi: Double = strokeBand.hi) -> BiquadCoeffs {
        let f0 = (lo * hi).squareRoot()
        let q = f0 / (hi - lo)
        let w0 = 2.0 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2.0 * q)
        let a0 = 1.0 + alpha
        return BiquadCoeffs(b0: alpha / a0, b1: 0.0, b2: -alpha / a0,
                            a1: -2.0 * cos(w0) / a0, a2: (1.0 - alpha) / a0)
    }

    /// 因果 DF2-transposed biquad、初期状態ゼロ（Python 側と同一算術）。
    public static func biquadFilter(_ x: ArraySlice<Double>, _ c: BiquadCoeffs) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var z1 = 0.0, z2 = 0.0
        var i = 0
        for v in x {
            let yi = c.b0 * v + z1
            z1 = c.b1 * v - c.a1 * yi + z2
            z2 = c.b2 * v - c.a2 * yi
            y[i] = yi
            i += 1
        }
        return y
    }

    /// 1本分のストロークサイクル数。prone 区間の帯域パワー最大のジャイロ軸を
    /// 採用し、ヒステリシス付き正方向ゼロクロスを prone サンプルでだけ数える
    /// （ウォームアップ・立ち上がり等のゴミカウント防止）。
    public static func countStrokes(gx: ArraySlice<Double>, gy: ArraySlice<Double>,
                                    gz: ArraySlice<Double>, prone: ArraySlice<Bool>,
                                    coeffs: BiquadCoeffs) -> Int {
        let proneArr = Array(prone)
        var bestY: [Double]? = nil
        var bestPow = -1.0
        for axis in [gx, gy, gz] {
            let y = biquadFilter(axis, coeffs)
            var sum = 0.0
            var n = 0
            for i in 0..<y.count where proneArr[i] {
                sum += y[i] * y[i]
                n += 1
            }
            let v = n > 0 ? sum / Double(n) : 0.0
            if v > bestPow {
                bestPow = v
                bestY = y
            }
        }
        guard let y = bestY, bestPow > 0.0 else { return 0 }
        let h = 0.3 * bestPow.squareRoot()
        var count = 0
        var low = false
        for i in 0..<y.count {
            if y[i] < -h {
                low = true
            } else if low && y[i] > h {
                if proneArr[i] { count += 1 }
                low = false
            }
        }
        return count
    }

    /// レップ内の本ごとスパン: 壁を蹴った時刻（立ち終わり）→次の壁到着
    /// （立ち始まり）。立位時間は構造上含まれない。
    public static func lengthSpans(s0: Double, s1: Double, turns: [Span]) -> [Span] {
        var pts = [s0]
        for w in turns.filter({ s0 <= $0.start && $0.start <= s1 }).sorted() {
            pts.append(w.start)
            pts.append(w.end)
        }
        pts.append(s1)
        var out = [Span]()
        var i = 0
        while i + 1 < pts.count {
            out.append(Span(pts[i], pts[i + 1]))
            i += 2
        }
        return out
    }
}
