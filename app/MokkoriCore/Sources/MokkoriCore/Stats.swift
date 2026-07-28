import Foundation

/// numpy 互換の統計関数。パリティテストが Python 実装とビット近傍で一致する
/// ことを要求するので、np.median / np.percentile(method="linear") の定義に合わせる。
public enum Stats {
    /// np.percentile(x, q) — 既定の linear 補間。
    public static func percentile(_ x: [Double], _ q: Double) -> Double {
        precondition(!x.isEmpty)
        let s = x.sorted()
        let h = Double(s.count - 1) * q / 100.0
        let lo = Int(h.rounded(.down))
        let hi = Int(h.rounded(.up))
        if lo == hi { return s[lo] }
        return s[lo] + (h - Double(lo)) * (s[hi] - s[lo])
    }

    /// np.median(x) — 偶数長は中央2値の平均。
    public static func median(_ x: [Double]) -> Double {
        precondition(!x.isEmpty)
        let s = x.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
