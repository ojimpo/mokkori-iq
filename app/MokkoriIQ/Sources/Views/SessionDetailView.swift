import SwiftUI
import MokkoriCore

/// レポート画面: swim_report.py の出力に対応（距離/ペース/タイム/セット/インターバル/ラップ）。
///
/// 用語は Garmin 日本語と水泳の練習用語に合わせている:
/// ラップ = プールの片道(25m) / インターバル = レストで区切られた連続泳ぎ /
/// セット = 大休憩で区切られた塊。
///
/// レイアウトは Apple フィットネスの「ワークアウトの詳細」に倣う（`MetricStyle.swift`）。
struct SessionDetailView: View {
    @State var model: SessionAnalysisModel

    var body: some View {
        Group {
            if let report = model.report {
                reportList(report)
            } else if let error = model.error {
                ContentUnavailableView("読み込みエラー",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ProgressView("解析中…")
            }
        }
        .navigationTitle(model.meta.sourceFilename)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    private func reportList(_ report: SwimReport) -> some View {
        List {
            Section { summaryCard(report) }

            let crossChecks = report.intervals.filter(\.crossCheck)
            if !crossChecks.isEmpty {
                Section("CROSS-CHECK 警告") {
                    ForEach(Array(crossChecks.enumerated()), id: \.offset) { _, iv in
                        Label {
                            Text("セット\(iv.setNumber) インターバル\(iv.number): 壁カウント\(iv.wallCount)ラップ vs ペース推定\(iv.paceCount)ラップ → \(iv.laps)ラップを採用。検出がずれている可能性")
                                .font(.caption)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            Section {
                NavigationLink {
                    WallIntervalView(model: model)
                } label: {
                    Label("ラップを確認・修正", systemImage: "checklist")
                }
                NavigationLink {
                    StravaUploadView(model: model)
                } label: {
                    Label(model.meta.stravaActivityId == nil
                          ? "Strava へアップ" : "Strava にアップ済み",
                          systemImage: model.meta.stravaActivityId == nil
                          ? "square.and.arrow.up" : "checkmark.circle")
                }
            } footer: {
                Text(model.isEdited ? "ターンの修正が適用されています" :
                        "Strava アップ前にここで検出結果を確認します")
            }

            if let chart = model.paceChart, chart.rows.count >= 2 {
                Section("ペースの推移") {
                    PaceChartView(chart: chart)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12,
                                                  bottom: 12, trailing: 12))
                }
                .headerProminence(.increased)
            }

            setSection(report)
            intervalSection(report)
            lapSection(report)
        }
    }

    // MARK: - サマリー

    private func summaryCard(_ report: SwimReport) -> some View {
        VStack(spacing: 0) {
            metricRow(
                MetricTile(label: "距離", value: fmtMetersValue(report.distance),
                           unit: "M", color: Metric.distance),
                MetricTile(label: "タイム", value: fmtClock(report.movingTime),
                           color: Metric.time))
            Divider()
            metricRow(
                MetricTile(label: "平均ペース", value: fmtPace(report.pace100),
                           unit: "/100M", color: Metric.pace),
                MetricTile(label: "経過時間", value: fmtClock(report.elapsed),
                           color: .secondary))
            if let spl = report.strokesPerLapMedian, let swAvg = report.swolfAverage {
                Divider()
                metricRow(
                    MetricTile(label: "ストローク", value: "\(report.strokesTotal)",
                               color: Metric.stroke),
                    MetricTile(label: "平均SWOLF", value: "\(Int(swAvg.rounded()))",
                               color: Metric.swolf))
                if let dps = report.dps {
                    Divider()
                    metricRow(
                        MetricTile(label: "1ラップのストローク", value: "\(Int(spl))",
                                   color: Metric.stroke),
                        MetricTile(label: "ストローク長",
                                   value: String(format: "%.2f", dps),
                                   unit: "M", color: Metric.stroke))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func metricRow(_ a: MetricTile, _ b: MetricTile) -> some View {
        HStack(alignment: .top, spacing: 12) {
            a
            b
        }
        .padding(.vertical, 8)
    }

    // MARK: - セット / インターバル / ラップ

    private func setSection(_ report: SwimReport) -> some View {
        Section {
            ForEach(report.sets, id: \.index) { s in
                HStack(spacing: 8) {
                    Text("\(s.index)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .leading)
                    MetricCell(value: fmtMetersValue(s.distance), unit: "M",
                               color: Metric.distance)
                    MetricCell(value: fmtClock(s.movingTime), color: Metric.time)
                    MetricCell(value: fmtPace(s.pace100), unit: "/100M",
                               color: Metric.pace)
                }
            }
        } header: {
            Text("セット")
        } footer: {
            Text("大休憩で区切られた塊です")
        }
        .headerProminence(.increased)
    }

    private func intervalSection(_ report: SwimReport) -> some View {
        Section {
            HStack(spacing: 8) {
                Text("").frame(width: 68, alignment: .leading)
                ColumnHeader(text: "ラップ")
                ColumnHeader(text: "距離")
                ColumnHeader(text: "タイム")
            }
            ForEach(Array(report.intervals.enumerated()), id: \.offset) { _, iv in
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Text("S\(iv.setNumber)-\(iv.number)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if iv.crossCheck {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .imageScale(.small)
                        }
                    }
                    .frame(width: 68, alignment: .leading)
                    MetricCell(value: "\(iv.laps)", color: .primary)
                    MetricCell(value: fmtMetersValue(Double(iv.laps) * report.poolLength),
                               unit: "M", color: Metric.distance)
                    MetricCell(value: fmtClock(iv.swimTime), color: Metric.time)
                }
            }
        } header: {
            Text("インターバル")
        } footer: {
            Text("レストで区切られた連続泳ぎです。1ラップの標準タイムは \(String(format: "%.1f", report.typicalLapTime))秒 / \(Int(report.poolLength))m")
        }
        .headerProminence(.increased)
    }

    private func lapSection(_ report: SwimReport) -> some View {
        Group {
            if !report.laps.isEmpty {
                Section {
                    HStack(spacing: 8) {
                        Text("").frame(width: 44, alignment: .leading)
                        ColumnHeader(text: "タイム")
                        ColumnHeader(text: "ストローク")
                        ColumnHeader(text: "SWOLF")
                    }
                    ForEach(Array(report.laps.enumerated()), id: \.offset) { i, l in
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Text("\(i + 1)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                if report.sets.count > 1 {
                                    Text("S\(l.setNumber)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(width: 44, alignment: .leading)
                            MetricCell(value: String(format: "%.1f", l.duration),
                                       unit: "S", color: Metric.time)
                            MetricCell(value: "\(l.strokes)", color: Metric.stroke)
                            MetricCell(value: "\(Int(l.swolf.rounded(.down)))",
                                       color: Metric.swolf)
                        }
                    }
                } header: {
                    Text("ラップ（\(Int(report.poolLength))m）")
                } footer: {
                    if let best = report.bestLap {
                        Text("ベストペース \(fmtPace(best.duration / report.poolLength * 100))/100m（\(String(format: "%.1f", best.duration))秒・セット\(best.setNumber) インターバル\(best.interval) ラップ\(best.number)）")
                    }
                }
                .headerProminence(.increased)
            }
        }
    }
}

/// 距離の数値だけ（単位は MetricTile 側が小さく付ける）。桁区切りは fmtMeters と揃える。
func fmtMetersValue(_ m: Double) -> String {
    String(fmtMeters(m).dropLast(2))
}
