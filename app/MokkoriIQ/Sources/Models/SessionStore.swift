import Foundation
import Observation
import MokkoriCore

/// セッションの永続化。Documents/sessions/<uuid>/ に
///   meta.json    — メタ + 一覧用のキャッシュ済みサマリ
///   raw.bin      — 生サンプル int16 (RawRecording。CSVとビット同値が検証済みの場合)
///   raw.csv      — 量子化ラウンドトリップに失敗した場合のフォールバック（原文コピー）
///   overlay.json — 壁の人手修正（生データ・自動検出とは分離。無ければ未修正）
/// 生データを残すのは方針（検出器改良時に過去セッションを再処理できる）。
@Observable
final class SessionStore {

    struct Meta: Codable, Identifiable, Hashable {
        var id: UUID
        var sourceFilename: String
        var importedAt: Date
        var sampleCount: Int
        var odr: Double
        var storage: String            // "bin" | "csv"
        // 一覧用キャッシュ（オーバーレイ無しの自動検出値。編集後は再計算で更新）
        var distance: Double
        var movingTime: Double
        var elapsed: Double
        /// 時刻アンカー: サンプル0の絶対時刻。BLE 時刻同期（Phase C/D）までは手動入力
        var startEpoch: Date?
        /// Strava にアップ済みならその activity id
        var stravaActivityId: Int?
    }


    private(set) var sessions: [Meta] = []

    /// 一覧の見出し用の合計。平均ペースは「累計タイム ÷ 累計距離」で、
    /// セッションごとのペースを平均し直さない（レポートの出し方と揃える）。
    var totalDistance: Double { sessions.reduce(0) { $0 + $1.distance } }
    var totalMovingTime: Double { sessions.reduce(0) { $0 + $1.movingTime } }
    var averagePace100: Double? {
        totalDistance > 0 ? totalMovingTime / totalDistance * 100 : nil
    }

    private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: self.root,
                                                 withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
            ?? []
        sessions = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json"))
            else { return nil }
            return try? JSONDecoder().decode(Meta.self, from: data)
        }
        .sorted { $0.importedAt > $1.importedAt }
    }

    private func dir(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }

    // MARK: - インポート

    enum ImportError: LocalizedError {
        case unreadable
        var errorDescription: String? { "ファイルを読めません（アクセス権かCSV形式を確認）" }
    }

    /// flash_dump CSV を取り込む。int16 化を検証付きで試み、ダメなら CSV のまま保存。
    /// 解析（検出＋レポート）まで行い、一覧用サマリをキャッシュする。
    /// 重い処理（解析）はバックグラウンド、observable な一覧更新はメインで行う。
    @MainActor
    func importCSV(from url: URL) async throws -> Meta {
        let meta = try await Task.detached(priority: .userInitiated) {
            try self.processCSV(from: url)
        }.value
        sessions.insert(meta, at: 0)
        return meta
    }

    private func processCSV(from url: URL) throws -> Meta {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Data のまま扱う（String 経由にすると 16 万行で無駄なコピーと変換が入る）
        guard let data = try? Data(contentsOf: url) else {
            throw ImportError.unreadable
        }

        let sess: SwimSession
        var storage = "bin"
        var rec: RawRecording?
        do {
            let r = try RawRecording.encode(csvData: data)
            rec = r
            sess = r.decode()
        } catch {
            // int16 に丸め直せない形式（記録側の変更など）。解析できるなら
            // CSV のまま保存して取り込む。ヘッダ違いはここで弾かれる。
            storage = "csv"
            sess = try SwimSession.parseCSV(data)
        }

        let d = WallDetector.detectWalls(sess)
        let report = SwimReporter.makeReport(sess, detection: d)

        let meta = Meta(id: UUID(),
                        sourceFilename: url.lastPathComponent,
                        importedAt: Date(),
                        sampleCount: sess.count,
                        odr: rec?.odr ?? sess.fs,
                        storage: storage,
                        distance: report.distance,
                        movingTime: report.movingTime,
                        elapsed: report.elapsed,
                        startEpoch: nil)

        let fm = FileManager.default
        let d0 = dir(meta.id)
        try fm.createDirectory(at: d0, withIntermediateDirectories: true)
        if let rec {
            try rec.binaryData().write(to: d0.appendingPathComponent("raw.bin"))
        } else {
            try data.write(to: d0.appendingPathComponent("raw.csv"))
        }
        try writeMeta(meta)
        return meta
    }

    private func writeMeta(_ meta: Meta) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(meta).write(to: dir(meta.id).appendingPathComponent("meta.json"))
    }

    func save(meta: Meta) throws {
        try writeMeta(meta)
        if let i = sessions.firstIndex(where: { $0.id == meta.id }) {
            sessions[i] = meta
        }
    }

    func delete(_ meta: Meta) {
        try? FileManager.default.removeItem(at: dir(meta.id))
        sessions.removeAll { $0.id == meta.id }
    }

    // MARK: - 読み出し

    func loadSession(_ meta: Meta) throws -> SwimSession {
        let d0 = dir(meta.id)
        if meta.storage == "bin" {
            let data = try Data(contentsOf: d0.appendingPathComponent("raw.bin"))
            return RawRecording(binaryData: data, odr: meta.odr).decode()
        }
        return try SwimSession.loadCSV(d0.appendingPathComponent("raw.csv"))
    }

    func loadOverlay(_ meta: Meta) -> WallOverlay {
        let url = dir(meta.id).appendingPathComponent("overlay.json")
        guard let data = try? Data(contentsOf: url),
              let ov = try? JSONDecoder().decode(WallOverlay.self, from: data)
        else { return WallOverlay() }
        return ov
    }

    func save(overlay: WallOverlay, for meta: Meta) throws {
        let url = dir(meta.id).appendingPathComponent("overlay.json")
        if overlay.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(overlay).write(to: url)
    }
}

extension SessionStore.Meta {

    /// 一覧に出す日時が「どれくらい信用できるか」。
    enum DateSource {
        /// 時刻アンカー（Strava アップ時に人が入れた泳ぎ始め）。これだけが正確
        case anchor
        /// ファイル名 `swim_YYYYMMDD_HHMMSS.csv` の時刻。**記録開始ではなく吸い出し時刻**
        /// （6/21・7/28 のセッションで確認済み）。泳いだのはこれより前
        case dump
        /// 上のどちらも取れないとき。アプリに取り込んだ時刻
        case imported

        var caption: String? {
            switch self {
            case .anchor:   return nil
            case .dump:     return "吸い出し"
            case .imported: return "取り込み"
            }
        }
    }

    /// 一覧の見出しに出す日時と、その出どころ。
    var displayDate: (date: Date, source: DateSource) {
        if let anchor = startEpoch { return (anchor, .anchor) }
        if let d = Self.dateFromFilename(sourceFilename) { return (d, .dump) }
        return (importedAt, .imported)
    }

    /// `swim_20260728_153415.csv` → その日時（端末のローカル時刻として読む）
    static func dateFromFilename(_ name: String) -> Date? {
        let digits = name.drop { !$0.isNumber }
        let stamp = digits.filter(\.isNumber)
        guard stamp.count >= 14 else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        return f.date(from: String(stamp.prefix(14)))
    }
}

/// 一覧の日時表記。Apple フィットネスと同じ「7月28日(火)」の形。
func fmtDay(_ d: Date) -> String {
    SessionDateFormat.day.string(from: d)
}
func fmtDayTime(_ d: Date) -> String {
    SessionDateFormat.dayTime.string(from: d)
}

private enum SessionDateFormat {
    static let day = make("M月d日(E)")
    static let dayTime = make("M月d日(E) HH:mm")

    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = format
        return f
    }
}
