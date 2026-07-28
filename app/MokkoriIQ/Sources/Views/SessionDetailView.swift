import SwiftUI
import MokkoriCore

/// レポート画面: swim_report.py の出力に対応（距離/ペース/泳ぎ時間/半分割/レップ内訳）。
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
            Section {
                summaryGrid(report)
            }

            let crossChecks = report.reps.filter(\.crossCheck)
            if !crossChecks.isEmpty {
                Section("CROSS-CHECK 警告") {
                    ForEach(Array(crossChecks.enumerated()), id: \.offset) { _, rep in
                        Label {
                            Text("半\(rep.half) レップ\(rep.rep): 壁カウント\(rep.wallCount)本 vs ペース推定\(rep.paceCount)本 → \(rep.lengths)本を採用。検出がずれている可能性")
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
                    Label("壁インターバルを確認・修正", systemImage: "checklist")
                }
            } footer: {
                Text(model.isEdited ? "壁の修正が適用されています" :
                        "Strava アップ前にここで検出結果を確認します")
            }

            Section("半分割") {
                ForEach(report.halves, id: \.index) { h in
                    HStack {
                        Text("半\(h.index)")
                        Spacer()
                        Text("\(Int(h.distance))m")
                            .monospacedDigit()
                        Text(fmtTime(h.movingTime))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(fmtTime(h.pace100) + "/100m")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ForEach(Array(report.reps.enumerated()), id: \.offset) { _, rep in
                    HStack {
                        Text("半\(rep.half) レップ\(rep.rep)")
                        if rep.crossCheck {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .imageScale(.small)
                        }
                        Spacer()
                        Text("泳ぎ \(fmtTime(rep.swimTime))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text("\(rep.lengths)本 (\(rep.lengths * Int(report.poolLength))m)")
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            } header: {
                Text("レップ内訳")
            } footer: {
                Text("1本の典型泳ぎ時間 \(fmtTime(report.typicalLengthTime)) / \(Int(report.poolLength))m")
            }

            if !report.lengths.isEmpty {
                Section {
                    ForEach(Array(report.lengths.enumerated()), id: \.offset) { _, l in
                        HStack {
                            Text("半\(l.half) R\(l.rep) L\(l.num)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.1fs", l.duration))
                                .monospacedDigit()
                            Text("\(l.strokes)str")
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                            Text("SWOLF \(Int(l.swolf.rounded(.down)))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 76, alignment: .trailing)
                        }
                        .font(.caption)
                    }
                } header: {
                    Text("本ごと（\(Int(report.poolLength))m）")
                } footer: {
                    if let best = report.bestLength, let dps = report.dps {
                        Text("ベストペース \(fmtTime(best.duration / report.poolLength * 100))/100m（\(String(format: "%.1f", best.duration))s・半\(best.half) R\(best.rep) L\(best.num)）・DPS \(String(format: "%.2f", dps))m/ストローク")
                    }
                }
            }
        }
    }

    private func summaryGrid(_ report: SwimReport) -> some View {
        VStack(spacing: 12) {
            HStack {
                stat("距離", "\(Int(report.distance)) m")
                stat("ペース", "約" + fmtTime(report.pace100) + " /100m")
            }
            HStack {
                stat("泳ぎ時間", fmtTime(report.movingTime))
                stat("総経過時間", fmtTime(report.elapsed))
            }
            if let spl = report.strokesPerLengthMedian,
               let swAvg = report.swolfAverage, let swBest = report.swolfBest {
                HStack {
                    stat("ストローク", "\(report.strokesTotal)（\(Int(spl))/本）")
                    stat("SWOLF", "平均\(Int(swAvg.rounded()))・ベスト\(Int(swBest.rounded()))")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}
