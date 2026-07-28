import SwiftUI
import MokkoriCore

/// ログタブ: これまでの累計 → セッション一覧 → レポート。
/// **取り込みはデバイスタブに置いてある**（本体まわりの操作をあちらに集約したため）。
struct SessionListView: View {
    @Environment(SessionStore.self) private var store
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    ContentUnavailableView(
                        "ログがありません",
                        systemImage: "figure.pool.swim",
                        description: Text("デバイスタブの「ログを取り込む」から取り込みます"))
                } else {
                    List {
                        Section { totals }
                        Section {
                            ForEach(store.sessions) { meta in
                                NavigationLink(value: meta) {
                                    SessionRow(meta: meta)
                                }
                            }
                            .onDelete { idx in
                                for i in idx { store.delete(store.sessions[i]) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("ログ")
            .navigationDestination(for: SessionStore.Meta.self) { meta in
                SessionDetailView(model: SessionAnalysisModel(meta: meta, store: store))
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if importing { ProgressView() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("設定", systemImage: "gearshape")
                    }
                }
            }
            .task {
                // UI テスト用の種まき。環境変数で CSV のパスを渡されたときだけ動く
                // （テストのたびに「ファイル」アプリを人手で操作しなくて済む）。
                // 取込済みかどうかはファイル名で見る（アプリのデータはテスト間で
                // 残るので、別のセッションを続けて渡せるようにしておく）。
                guard let path = ProcessInfo.processInfo.environment["UITEST_SEED_CSV"],
                      !store.sessions.contains(where: {
                          $0.sourceFilename == URL(fileURLWithPath: path).lastPathComponent
                      })
                else { return }
                importing = true
                _ = try? await store.importCSV(from: URL(fileURLWithPath: path))
                importing = false
            }
        }
    }

    /// これまでの累計。開いた瞬間に「どれだけ泳いだか」が見えるようにする。
    private var totals: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                MetricTile(label: "累計距離", value: fmtMetersValue(store.totalDistance),
                           unit: "M", color: Metric.distance)
                MetricTile(label: "累計タイム", value: fmtClock(store.totalMovingTime),
                           color: Metric.time)
            }
            .padding(.vertical, 8)
            Divider()
            HStack(alignment: .top, spacing: 12) {
                MetricTile(label: "平均ペース",
                           value: store.averagePace100.map(fmtPace) ?? "—",
                           unit: store.averagePace100 == nil ? "" : "/100M",
                           color: store.averagePace100 == nil ? .secondary : Metric.pace)
                MetricTile(label: "ログ", value: "\(store.sessions.count)",
                           unit: "件", color: .primary)
            }
            .padding(.vertical, 8)
        }
        .padding(.vertical, 4)
    }
}

private struct SessionRow: View {
    let meta: SessionStore.Meta

    private var pace100: Double? {
        meta.distance > 0 ? meta.movingTime / meta.distance * 100 : nil
    }

    var body: some View {
        let stamp = meta.displayDate
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(fmtDayTime(stamp.date))
                    .font(.headline)
                if let caption = stamp.source.caption {
                    // 泳いだ時刻そのものではないので、何の時刻かを明示する。
                    // 時刻アンカーが入っているセッションではこのバッジは出ない。
                    Text(caption)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if meta.stravaActivityId != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 14) {
                MetricInline(value: fmtMetersValue(meta.distance), unit: "M",
                             color: Metric.distance)
                MetricInline(value: fmtClock(meta.movingTime), color: Metric.time)
                if let p = pace100 {
                    MetricInline(value: fmtPace(p), unit: "/100M", color: Metric.pace)
                }
            }
            Text("取り込み \(fmtDayTime(meta.importedAt))・\(meta.sourceFilename)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

/// 行の中に並べる小さめの数値（サマリーの MetricTile と同じ配色・組み方）。
private struct MetricInline: View {
    let value: String
    var unit: String = ""
    var color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
            if !unit.isEmpty {
                Text(unit).font(.caption2.weight(.semibold))
            }
        }
        .foregroundStyle(color)
    }
}
