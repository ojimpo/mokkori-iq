import Foundation

/// ラップ表の1行 = 1ラップ（ターンイベントからその前の泳ぎ区間を見る）。
/// ハイライト規則は解析側の知見を流用（docs/phase2_app_plan.md）:
///   ラップタイムがセット中央値の ≳1.6倍 = ターン見逃し疑い / ≲0.6倍 = 余計なターン疑い。
///   リズムリカバリで補完した壁は明示。
public struct WallInterval: Identifiable, Equatable {
    public enum Kind: String {
        case turn      // 途中のターン
        case rest      // インターバル境界（水中立ちレスト / ベンチ）
        case blockEnd  // セット終端（big-rest または記録終了）
    }
    public enum Flag: String {
        case ok
        case missedSuspect   // ギャップ長すぎ → 壁見逃し疑い
        case falseSuspect    // ギャップ短すぎ → 偽壁疑い
    }

    public let id: Int             // 全体での通し行番号
    public let blockIndex: Int     // 1-based セット番号（泳ぎのあるブロックだけ）
    public let wall: Span?         // この行の終端イベント（blockEnd 終端では nil あり）
    public let kind: Kind
    public let gap: Double         // 泳ぎギャップ: 前の立ち終わり → この立ち始まり
    public let isRecovered: Bool   // リズムリカバリ由来の壁
    public let flag: Flag

    public var time: Double { wall?.start ?? 0 }
}

public enum WallIntervalTable {

    /// 検出結果（オーバーレイ適用後）から確認画面の行を作る。
    /// ギャップの基準（中央値）はブロックごとに取る（リズムリカバリと同じ流儀）。
    public static func rows(for d: WallDetection) -> [WallInterval] {
        var out = [WallInterval]()
        var id = 0
        let recovered = Set(d.recovered)
        // セット番号は行が出るブロックだけを 1 から数える（入水前やシャワーの
        // 泳ぎゼロのブロックに番号を食わせない）。レポートの「セット」と揃える。
        var bi = 0
        for (bs, be) in zip(d.blockStarts, d.blockEnds) {
            var events: [(Span, WallInterval.Kind)] =
                d.turns.filter { bs <= $0.start && $0.start <= be }.map { ($0, .turn) }
                + d.rests.filter { bs <= $0.start && $0.start <= be }.map { ($0, .rest) }
            events.sort { $0.0 < $1.0 }
            guard !events.isEmpty else { continue }
            bi += 1

            var gaps = [Double]()
            var prevEnd = bs
            for (span, _) in events {
                gaps.append(span.start - prevEnd)
                prevEnd = span.end
            }
            // 中央値は壁間ギャップ（2本目以降）で取る。先頭ギャップは入水・壁出発
            // 込みで長さの意味が違うため基準から除外（行の判定対象には含める）。
            let interWall = Array(gaps.dropFirst())
            let med = interWall.isEmpty ? gaps[0] : Stats.median(interWall)

            for (k, (span, kind)) in events.enumerated() {
                let g = gaps[k]
                var flag = WallInterval.Flag.ok
                if med > 0 {
                    if g >= 1.6 * med { flag = .missedSuspect }
                    else if g <= 0.6 * med { flag = .falseSuspect }
                }
                out.append(WallInterval(id: id, blockIndex: bi, wall: span,
                                        kind: kind, gap: g,
                                        isRecovered: recovered.contains(span),
                                        flag: flag))
                id += 1
            }
            // ブロック終端行（最後の壁 → ブロック終わりの泳ぎ）
            let lastEnd = events[events.count - 1].0.end
            out.append(WallInterval(id: id, blockIndex: bi,
                                    wall: Span(be, be), kind: .blockEnd,
                                    gap: be - lastEnd, isRecovered: false,
                                    flag: .ok))
            id += 1
        }
        return out
    }
}
