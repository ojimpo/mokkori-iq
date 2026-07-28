import SwiftUI
import MokkoriCore

/// 壁インターバル確認画面（Strava アップ前の最後の砦）。
/// 行 = 壁イベント + その前の泳ぎギャップ。ハイライト:
///   橙 = ギャップがブロック中央値の ≳1.6倍（壁見逃し疑い）
///   赤 = ≲0.6倍（偽壁疑い） / 「補完」バッジ = リズムリカバリ由来
/// 修正 = 壁の追加（見逃しギャップの中点）/ 削除（偽壁・隣接マージ）→ 即時再計算。
struct WallIntervalView: View {
    @Bindable var model: SessionAnalysisModel
    @State private var confirmReset = false

    var body: some View {
        List {
            if let report = model.report {
                Section {
                    HStack {
                        Text(fmtMeters(report.distance))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                        Spacer()
                        Text("泳ぎ " + fmtTime(report.movingTime))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } footer: {
                    Text("修正すると距離・レップ・ペースが即時再計算されます")
                }
            }

            let blocks = Dictionary(grouping: model.intervals, by: \.blockIndex)
            ForEach(blocks.keys.sorted(), id: \.self) { bi in
                Section("ブロック \(bi)") {
                    ForEach(blocks[bi] ?? []) { row in
                        IntervalRow(row: row)
                            .swipeActions(edge: .trailing) {
                                if row.kind == .turn, let wall = row.wall {
                                    Button(role: .destructive) {
                                        Task { await model.removeWall(wall) }
                                    } label: {
                                        Label("壁を削除", systemImage: "trash")
                                    }
                                }
                            }
                            .contextMenu {
                                if row.kind != .blockEnd, let wall = row.wall {
                                    Button {
                                        // 見逃し疑いギャップの中点に1壁追加
                                        Task {
                                            await model.addWall(
                                                at: wall.start - row.gap / 2)
                                        }
                                    } label: {
                                        Label("この前のギャップに壁を追加",
                                              systemImage: "plus.circle")
                                    }
                                    if row.kind == .turn {
                                        Button(role: .destructive) {
                                            Task { await model.removeWall(wall) }
                                        } label: {
                                            Label("この壁を削除（隣とマージ）",
                                                  systemImage: "trash")
                                        }
                                    }
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("壁インターバル")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isEdited {
                ToolbarItem(placement: .primaryAction) {
                    Button("修正を破棄") { confirmReset = true }
                }
            }
        }
        .confirmationDialog("すべての修正を破棄して自動検出に戻しますか？",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("破棄する", role: .destructive) {
                Task { await model.resetOverlay() }
            }
        }
    }
}

private struct IntervalRow: View {
    let row: WallInterval

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout)
                    if row.isRecovered {
                        Text("補完")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(fmtTime(row.gap))
                .monospacedDigit()
                .foregroundStyle(gapColor)
        }
    }

    private var title: String {
        switch row.kind {
        case .turn: return "ターン壁 @\(Int(row.time))s"
        case .rest: return "休憩 @\(Int(row.time))s"
        case .blockEnd: return "ブロック終わり"
        }
    }

    private var subtitle: String {
        switch row.flag {
        case .ok: return "直前の泳ぎ"
        case .missedSuspect: return "ギャップが長い → 壁見逃し疑い"
        case .falseSuspect: return "ギャップが短い → 偽壁疑い"
        }
    }

    private var icon: String {
        switch row.kind {
        case .turn: return "arrow.uturn.left"
        case .rest: return "figure.stand"
        case .blockEnd: return "flag.checkered"
        }
    }

    private var iconColor: Color {
        switch row.flag {
        case .ok: return row.kind == .rest ? .green : .secondary
        case .missedSuspect: return .orange
        case .falseSuspect: return .red
        }
    }

    private var gapColor: Color {
        switch row.flag {
        case .ok: return .primary
        case .missedSuspect: return .orange
        case .falseSuspect: return .red
        }
    }
}
