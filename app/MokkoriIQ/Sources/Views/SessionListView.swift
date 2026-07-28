import SwiftUI
import UniformTypeIdentifiers
import MokkoriCore

/// セッション一覧 + CSV インポート（「ファイル」アプリ経由。Phase A の取込手段）。
struct SessionListView: View {
    @Environment(SessionStore.self) private var store
    @State private var showImporter = false
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    ContentUnavailableView(
                        "セッションがありません",
                        systemImage: "figure.pool.swim",
                        description: Text("右上の＋から flash_dump の CSV を取り込みます"))
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
            .navigationTitle("mokkori-iq")
            .navigationDestination(for: SessionStore.Meta.self) { meta in
                SessionDetailView(model: SessionAnalysisModel(meta: meta, store: store))
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if importing {
                        ProgressView()
                    } else {
                        Button {
                            showImporter = true
                        } label: {
                            Label("インポート", systemImage: "plus")
                        }
                    }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText]) { res in
                guard case .success(let url) = res else { return }
                importing = true
                Task {
                    do {
                        _ = try await store.importCSV(from: url)
                    } catch {
                        importError = error.localizedDescription
                    }
                    importing = false
                }
            }
            .alert("インポート失敗", isPresented: .init(
                get: { importError != nil },
                set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
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
                Label("\(Int(meta.distance))m", systemImage: "ruler")
                Label(fmtTime(meta.movingTime), systemImage: "stopwatch")
                Text("\(Int(meta.elapsed / 60))分記録")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}
