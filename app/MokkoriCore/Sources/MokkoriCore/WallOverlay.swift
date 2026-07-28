import Foundation

/// 壁インターバル確認画面での人手修正。生データ・自動検出結果は書き換えず、
/// このオーバーレイだけを別保存する（検出器改良時に自動検出をやり直しても
/// 修正の意図が残る。修正ログ＝ラベル付きGT としてチューニングに還流できる）。
public struct WallOverlay: Codable, Equatable {
    /// 追加した壁の時刻（1秒スパンの中心として扱う）
    public var added: [Double]
    /// 削除した壁（自動検出 turns の start 時刻で識別。隣接マージも境界壁の削除）
    public var removed: [Double]

    public init(added: [Double] = [], removed: [Double] = []) {
        self.added = added
        self.removed = removed
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }

    /// removed と turns の突き合わせ許容（検出器更新で壁時刻が微動しても追随）
    public static let matchTol = 0.75

    /// 自動検出結果へオーバーレイを適用した WallDetection を返す。
    public func apply(to d: WallDetection) -> WallDetection {
        var turns = d.turns.filter { t in
            !removed.contains { abs($0 - t.start) < Self.matchTol }
        }
        for a in added {
            let s = Span(a - 0.5, a + 0.5)
            if !turns.contains(s) { turns.append(s) }
        }
        turns.sort()
        return WallDetection(gz: d.gz, turns: turns, rests: d.rests, bigs: d.bigs,
                             taps: d.taps, triples: d.triples,
                             recovered: d.recovered.filter { turns.contains($0) },
                             blockStarts: d.blockStarts, blockEnds: d.blockEnds)
    }
}
