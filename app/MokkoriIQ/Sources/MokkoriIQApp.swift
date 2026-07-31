import SwiftUI

@main
struct MokkoriIQApp: App {
    @State private var store = SessionStore()
    @State private var strava = StravaService()
    @State private var device = DeviceSettings()
    @State private var ble = BLEManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(strava)
                .environment(device)
                .environment(ble)
        }
    }
}

/// タブは2つだけ。**デバイス**＝本体まわり（取り込み・状態・メンテナンス・振動）、
/// **ログ**＝取り込んだセッションの一覧とレポート。
/// Strava の設定はログ側の左上に置く（設定するものが Strava しか無いため）。
struct RootView: View {
    /// 起動時はログを開く。デバイスタブは取り込むときと設定を変えるときに行く場所で、
    /// 毎回見るものではない。
    @State private var tab = Tab.log

    enum Tab: Hashable { case device, log }

    var body: some View {
        TabView(selection: $tab) {
            DeviceView()
                .tabItem { Label("デバイス", systemImage: "sensor.tag.radiowaves.forward") }
                .tag(Tab.device)
            SessionListView()
                .tabItem { Label("ログ", systemImage: "figure.pool.swim") }
                .tag(Tab.log)
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
