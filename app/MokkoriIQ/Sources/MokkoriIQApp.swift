import SwiftUI

@main
struct MokkoriIQApp: App {
    @State private var store = SessionStore()

    var body: some Scene {
        WindowGroup {
            SessionListView()
                .environment(store)
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
