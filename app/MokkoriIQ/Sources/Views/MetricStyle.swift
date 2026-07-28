import SwiftUI

/// Apple フィットネス（ワークアウトの詳細）のタイポグラフィに合わせた数値表示。
///
/// 型は3つだけ:
///   - **ラベルは小さく控えめ、値は大きく色付き**（＝知りたい情報とそうでない情報の
///     認知的コントラストを、サイズと彩度の両方で付ける）
///   - **単位は値にくっつけて一回り小さく**（`1,050` + `M`）。単位で行を食わない
///   - **行は区切り線で分ける**（枠線でセルを囲まない）
///
/// 色はメトリクスの「種類」に付ける（値の大小では変えない）。同じ系統のメトリクスは
/// 同じ色にする（Apple がカロリー2種を同じ赤にしているのと同じ）。
enum Metric {
    /// ライト/ダークとも背景コントラスト 3:1 以上を配色バリデータで確認済み。
    /// ダークは自動反転ではなく明示値（暗いままだと沈む）。
    static let distance = dynamic(light: 0x2a78d6, dark: 0x4a9bf0)   // 距離系
    static let time     = dynamic(light: 0xcf6a24, dark: 0xf0913f)   // 時間系
    static let pace     = dynamic(light: 0x0f8a8f, dark: 0x3fc0c8)   // ペース系
    static let stroke   = dynamic(light: 0x2e9e6b, dark: 0x45c489)   // ストローク系
    static let swolf    = dynamic(light: 0x8257c8, dark: 0xa98bea)   // 効率系

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(metricRGB: dark) : UIColor(metricRGB: light) })
    }
}

private extension UIColor {
    convenience init(metricRGB rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xff) / 255,
                  green: Double((rgb >> 8) & 0xff) / 255,
                  blue: Double(rgb & 0xff) / 255, alpha: 1)
    }
}

/// サマリーカードの1マス。ラベル（小・控えめ）＋ 値（大・色付き）＋ 単位（小）。
struct MetricTile: View {
    let label: String
    let value: String
    var unit: String = ""
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.title.weight(.medium))
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 表（ラップ一覧など）の列見出し。値より一段落として、数字を主役にする。
struct ColumnHeader: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// 表のセル（色付きの数値 + 小さい単位）。
struct MetricCell: View {
    let value: String
    var unit: String = ""
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
            if !unit.isEmpty {
                Text(unit).font(.caption2.weight(.semibold))
            }
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
