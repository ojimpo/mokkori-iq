import Foundation
import Observation
import MokkoriCore

/// 1セッション分の解析状態。生データ読込→自動検出は1回だけ行い、
/// 壁の編集（オーバーレイ）はその上に適用して即時再計算する。
@Observable
final class SessionAnalysisModel {
    let meta: SessionStore.Meta
    private let store: SessionStore

    private(set) var session: SwimSession?
    /// 自動検出そのまま（オーバーレイ非適用）。編集のリセット先。
    private(set) var baseDetection: WallDetection?
    private(set) var overlay: WallOverlay
    /// オーバーレイ適用後の検出・レポート・確認画面の行
    private(set) var detection: WallDetection?
    private(set) var report: SwimReport?
    private(set) var intervals: [WallInterval] = []
    private(set) var loading = false
    private(set) var error: String?

    init(meta: SessionStore.Meta, store: SessionStore) {
        self.meta = meta
        self.store = store
        self.overlay = store.loadOverlay(meta)
    }

    var isEdited: Bool { !overlay.isEmpty }

    @MainActor
    func load() async {
        guard session == nil, !loading else { return }
        loading = true
        error = nil
        let meta = meta
        let store = store
        let overlay = overlay
        do {
            let r = try await Task.detached(priority: .userInitiated) {
                let sess = try store.loadSession(meta)
                let base = WallDetector.detectWalls(sess)
                let d = overlay.apply(to: base)
                let rep = SwimReporter.makeReport(sess, detection: d)
                let rows = WallIntervalTable.rows(for: d)
                return (sess, base, d, rep, rows)
            }.value
            session = r.0
            baseDetection = r.1
            detection = r.2
            report = r.3
            intervals = r.4
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    // MARK: - 壁の編集（追加/削除/隣接マージ=境界壁の削除）

    @MainActor
    func removeWall(_ span: Span) async {
        overlay.removed.append(span.start)
        overlay.added.removeAll { abs($0 - span.mid) < WallOverlay.matchTol }
        await recompute()
    }

    @MainActor
    func addWall(at time: Double) async {
        overlay.added.append(time)
        await recompute()
    }

    @MainActor
    func resetOverlay() async {
        overlay = WallOverlay()
        await recompute()
    }

    @MainActor
    private func recompute() async {
        guard let session, let baseDetection else { return }
        try? store.save(overlay: overlay, for: meta)
        let overlay = overlay
        let r = await Task.detached(priority: .userInitiated) {
            let d = overlay.apply(to: baseDetection)
            let rep = SwimReporter.makeReport(session, detection: d)
            let rows = WallIntervalTable.rows(for: d)
            return (d, rep, rows)
        }.value
        detection = r.0
        report = r.1
        intervals = r.2
        // 一覧のサマリも編集後の値へ追随させる
        var m = meta
        m.distance = r.1.distance
        m.movingTime = r.1.movingTime
        m.elapsed = r.1.elapsed
        try? store.save(meta: m)
    }
}
