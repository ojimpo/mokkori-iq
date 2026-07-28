import Foundation

/// 生セッションのデバイス単位表現: 6軸 int16 インターリーブ (ax,ay,az,gx,gy,gz) + ODR。
/// flash_logger のフラッシュ上の形式と同じ量子化なので、9.6MB CSV が約 2MB になる。
/// CSV ↔ int16 は完全ラウンドトリップ（インポート時に検証し、失敗したら投げる）:
///   CSV 値 = round(raw * 感度, 小数5桁) / t = round(i / odr, 小数4桁)
/// なので decode は flash_dump→load_swim_csv と同一の数値列を再現し、
/// 解析結果（パリティテストの期待値）もバイナリ経由で不変になる。
public struct RawRecording {
    /// LSM6DS3 感度: accel ±8g = fs/32768 g/LSB, gyro ±2000dps = 70 mdps/LSB
    public static let accSens = 8.0 / 32768.0
    public static let gyroSens = 70e-3

    public let samples: [Int16]   // interleaved、count*6 個
    public let odr: Double        // サンプルレート (Hz、整数値)

    public var count: Int { samples.count / 6 }

    public init(samples: [Int16], odr: Double) {
        self.samples = samples
        self.odr = odr
    }

    public enum CodecError: Error, LocalizedError {
        case quantization(row: Int, column: Int)
        case timeGrid(row: Int)

        public var errorDescription: String? {
            switch self {
            case .quantization(let r, let c):
                return "CSVの\(r)行目 列\(c) が int16 量子化にラウンドトリップしません"
            case .timeGrid(let r):
                return "CSVの\(r)行目の t が等間隔グリッド (i/odr) に乗っていません"
            }
        }
    }

    static func roundDec(_ x: Double, _ scale: Double) -> Double {
        (x * scale).rounded(.toNearestOrEven) / scale
    }

    /// flash_dump CSV → int16。各値が round5(raw*感度) に戻ることを検証する
    /// （戻らない CSV は形式が違うので呼び出し側が CSV のまま保存する）。
    public static func encode(csvText: String) throws -> RawRecording {
        var samples = [Int16]()
        var odr = 0.0
        var row = -1               // データ行番号 (0-based)
        var err: CodecError?
        var t1 = Double.nan
        csvText.enumerateLines { line, stop in
            if row < 0 && line.hasPrefix("idx") { row = 0; return }
            if line.isEmpty { return }
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count == 8 else { err = .timeGrid(row: row); stop = true; return }
            let tv = Double(f[1]) ?? .nan
            if row == 1 {
                t1 = tv
                odr = (1.0 / t1).rounded()
            }
            if row >= 1 {
                // t = round4(i / odr) の検証（0.5e-4 は %.4f 丸め幅）
                if abs(tv - Double(row) / odr) > 0.51e-4 {
                    err = .timeGrid(row: row); stop = true; return
                }
            }
            for c in 0..<6 {
                let sens = c < 3 ? accSens : gyroSens
                guard let v = Double(f[c + 2]) else {
                    err = .quantization(row: row, column: c); stop = true; return
                }
                let raw = (v / sens).rounded()
                guard raw >= -32768, raw <= 32767,
                      abs(roundDec(raw * sens, 1e5) - v) < 1e-9 else {
                    err = .quantization(row: row, column: c); stop = true; return
                }
                samples.append(Int16(raw))
            }
            row += 1
        }
        if let err { throw err }
        if samples.count / 6 == 1 { odr = 52.0 }   // 1行だけ: t1 が無い
        return RawRecording(samples: samples, odr: odr)
    }

    /// flash_dump save_csv → dataio.load_swim_csv と同一の数値列で SwimSession を復元。
    public func decode() -> SwimSession {
        let n = count
        var t = [Double](repeating: 0, count: n)
        var ax = [Double](repeating: 0, count: n), ay = ax, az = ax
        var gx = ax, gy = ax, gz = ax
        for i in 0..<n {
            t[i] = Self.roundDec(Double(i) / odr, 1e4)
            let b = i * 6
            ax[i] = Self.roundDec(Double(samples[b]) * Self.accSens, 1e5) * SwimSession.g0
            ay[i] = Self.roundDec(Double(samples[b + 1]) * Self.accSens, 1e5) * SwimSession.g0
            az[i] = Self.roundDec(Double(samples[b + 2]) * Self.accSens, 1e5) * SwimSession.g0
            gx[i] = Self.roundDec(Double(samples[b + 3]) * Self.gyroSens, 1e5) * SwimSession.deg2rad
            gy[i] = Self.roundDec(Double(samples[b + 4]) * Self.gyroSens, 1e5) * SwimSession.deg2rad
            gz[i] = Self.roundDec(Double(samples[b + 5]) * Self.gyroSens, 1e5) * SwimSession.deg2rad
        }
        var fs = 52.0
        if n > 1 {
            var dt = [Double]()
            dt.reserveCapacity(n - 1)
            for i in 1..<n { dt.append(t[i] - t[i - 1]) }
            let med = Stats.median(dt)
            if med > 0 { fs = 1.0 / med }
        }
        return SwimSession(t: t, ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz, fs: fs)
    }

    /// little-endian int16 列としてシリアライズ（ヘッダ無し。odr/件数はメタ側で持つ）。
    public func binaryData() -> Data {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public init(binaryData: Data, odr: Double) {
        var samples = [Int16](repeating: 0, count: binaryData.count / 2)
        binaryData.withUnsafeBytes { buf in
            let src = buf.bindMemory(to: Int16.self)
            for i in 0..<samples.count { samples[i] = Int16(littleEndian: src[i]) }
        }
        self.init(samples: samples, odr: odr)
    }
}
