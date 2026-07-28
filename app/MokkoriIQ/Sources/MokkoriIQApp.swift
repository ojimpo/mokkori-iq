import SwiftUI

@main
struct MokkoriIQApp: App {
    @State private var store = SessionStore()
    @State private var strava = StravaService()

    var body: some Scene {
        WindowGroup {
            SessionListView()
                .environment(store)
                .environment(strava)
        }
    }
}

/// 秒 → "m:ss.s" / "12.3s"（swim_report.py の fmt と同じ見た目）
func fmtTime(_ s: Double) -> String {
    let s = max(0, s)
    if s < 60 { return String(format: "%.1fs", s) }
    let m = Int(s) / 60
    return String(format: "%d:%04.1f", m, s - Double(60 * m))
}

/// 秒 → "20:34" / "1:02:34"（小数を落とした時計表記）。
/// サマリーの大きい数字用。Apple フィットネスの「ワークアウト時間」と同じ見せ方。
func fmtClock(_ s: Double) -> String {
    let v = Int(max(0, s).rounded())
    let (h, m, sec) = (v / 3600, (v % 3600) / 60, v % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                 : String(format: "%d:%02d", m, sec)
}

/// ペース（s /100m）→ "1:58"。単位はラベル側に持たせる。
func fmtPace(_ s: Double) -> String {
    let v = Int(max(0, s).rounded())
    return String(format: "%d:%02d", v / 60, v % 60)
}

/// 距離 → "1,050 m"。桁区切りの有無が画面ごとにブレると同じ数値に見えないので、
/// 距離の表示は必ずこれを通す（SwiftUI の Text("\(Int)") はロケール依存で
/// 勝手に桁区切りが入り、String 補間だと入らない、という差が出る）。
func fmtMeters(_ m: Double) -> String {
    let n = Int(m.rounded())
    return (NumberFormatter.distance.string(from: NSNumber(value: n)) ?? "\(n)") + " m"
}

private extension NumberFormatter {
    static let distance: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
}
