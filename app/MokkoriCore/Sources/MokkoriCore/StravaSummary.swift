import Foundation

/// Strava 手動アクティビティの内容を CLAUDE.md「Strava 投稿の規約」どおりに組み立てる。
/// 要点（ガーミンのプールスイムと同じ見え方にする）:
///   - 表示時間 = 泳ぎのみ（moving time）。休憩は含めない
///   - 開始時刻 = 実際に泳ぎ始めた時刻（ウォッチのスタートボタン相当）
///   - 距離は最良推定をそのまま。「控えめ・実際はこれ以上」の断り書きは書かない
///     （2026-07-28 に保守バイアスを撤廃したため）
///   - 手動作成では moving=elapsed になるので、実経過との差は説明文に併記する
public struct StravaSummary {
    public let name: String
    /// 泳ぎ始めの現地時刻
    public let startLocal: Date
    /// elapsed_time に渡す秒数（= moving time）
    public let movingSeconds: Int
    public let distanceMeters: Double
    public let description: String

    /// - Parameters:
    ///   - startEpoch: サンプル 0 の絶対時刻（手動アンカー or BLE 時刻同期）
    ///   - report: 解析結果
    public init(report: SwimReport, startEpoch: Date, calendar: Calendar = .current) {
        let swimStart = report.reps.first?.span.start ?? 0
        let start = startEpoch.addingTimeInterval(swimStart)
        self.startLocal = start
        self.movingSeconds = Int(report.movingTime.rounded())
        self.distanceMeters = report.distance
        self.name = Self.defaultName(for: start, calendar: calendar)
        self.description = Self.makeDescription(report)
    }

    /// 時間帯デフォルト名（Strava の既定命名にならう）
    public static func defaultName(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 4..<11: return "朝のスイム"
        case 11..<15: return "お昼のスイム"
        case 15..<19: return "午後のスイム"
        default: return "夜のスイム"
        }
    }

    static func fmt(_ s: Double) -> String {
        let s = max(0, s)
        let m = Int(s) / 60
        return String(format: "%d:%02d", m, Int(s.rounded()) - 60 * m)
    }

    static func makeDescription(_ r: SwimReport) -> String {
        var lines = [
            "\(Int(r.poolLength))mプール・自由形",
            "ペース \(fmt(r.pace100))/100m",
            "実経過 \(fmt(r.elapsed))（休憩込み。表示時間は泳ぎのみ）",
        ]
        if let spl = r.strokesPerLengthMedian, let sw = r.swolfAverage {
            lines.append("ストローク \(r.strokesTotal)（中央値 \(Int(spl))/本）・SWOLF平均 \(Int(sw.rounded()))")
        }
        if let best = r.bestLength {
            lines.append("ベスト \(fmt(best.duration / r.poolLength * 100))/100m")
        }
        lines.append("mokkori-iq（自作スイムトラッカー）")
        return lines.joined(separator: "\n")
    }
}
