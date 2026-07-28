import Foundation

/// 数値だけの固定列 CSV（flash_dump の出力）をバイト列のまま読む。
///
/// String 経由（`enumerateLines` → `split` → `Double(Substring)`）だと 1 セッション
/// 16 万行の取込に Mac でも 2.3 秒かかり、iPhone ではその数倍待たされる。行ごとの
/// String と Substring 配列を作らず `strtod` で直接読むと桁違いに速い。
///
/// `strtod` は Swift の `Double(String)` と同じく正しく丸められるので、**数値は
/// 完全に同一**（バイナリ往復テストがビット単位で検証している）。
enum FastCSV {

    /// 各行の数値を `onRow` に渡す。1 行でも壊れていたら false を返して中断する。
    /// - Parameters:
    ///   - columns: 1 行あたりの列数（不足していたら不正扱い）
    ///   - skipHeader: 先頭行が数値で始まらなければ読み飛ばす
    ///   - onRow: 行番号（0 始まり・ヘッダ除く）と値。false を返すと中断
    static func scan(_ data: Data, columns: Int, skipHeader: Bool = true,
                     onRow: (Int, UnsafeBufferPointer<Double>) -> Bool) -> Bool {
        guard !data.isEmpty else { return true }
        var bytes = [UInt8](data)
        bytes.append(0)            // NUL 終端: strtod が末尾を越えて読まないように
        var values = [Double](repeating: 0, count: columns)

        return bytes.withUnsafeMutableBufferPointer { buf -> Bool in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { base in
                values.withUnsafeMutableBufferPointer { out -> Bool in
                    var p = base
                    let end = base + buf.count - 1      // NUL の位置

                    func skipLine() {
                        while p < end && p.pointee != 0x0A { p += 1 }
                        if p < end { p += 1 }
                    }

                    if skipHeader {
                        let c = p.pointee
                        let numeric = (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E
                        if !numeric { skipLine() }
                    }

                    var rowIndex = 0
                    while p < end {
                        if p.pointee == 0x0A || p.pointee == 0x0D {   // 空行は飛ばす
                            p += 1
                            continue
                        }
                        for c in 0..<columns {
                            var next: UnsafeMutablePointer<CChar>?
                            let v = strtod(p, &next)
                            guard let np = next, np != p else { return false }
                            out[c] = v
                            p = np
                            if c < columns - 1 {
                                guard p < end, p.pointee == 0x2C else { return false }  // ','
                                p += 1
                            }
                        }
                        if !onRow(rowIndex, UnsafeBufferPointer(out)) { return false }
                        rowIndex += 1
                        skipLine()
                    }
                    return true
                }
            }
        }
    }
}
