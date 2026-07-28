import SwiftUI
import UniformTypeIdentifiers
import MokkoriCore

/// ログタブ: 取り込んだセッションの一覧 → レポート。
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
}

private struct SessionRow: View {
    let meta: SessionStore.Meta

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meta.sourceFilename)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 12) {
                Label(fmtMeters(meta.distance), systemImage: "ruler")
                Label(fmtTime(meta.movingTime), systemImage: "stopwatch")
                Text("\(Int(meta.elapsed / 60))分記録")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}
