import Foundation

/// flash_dump CSV (idx,t,ax,ay,az,gx,gy,gz — acc は g、gyro は deg/s) を
/// dataio.load_swim_csv と同じ規約で読み込んだセッション。
/// acc は m/s^2、gyro は rad/s に変換済み（検出器の閾値の単位に合わせる）。
public struct SwimSession {
    public let t: [Double]
    public let ax: [Double], ay: [Double], az: [Double]  // m/s^2
    public let gx: [Double], gy: [Double], gz: [Double]  // rad/s
    public let fs: Double

    public var count: Int { t.count }

    public static let g0 = 9.80665
    public static let deg2rad = Double.pi / 180.0

    public init(t: [Double], ax: [Double], ay: [Double], az: [Double],
                gx: [Double], gy: [Double], gz: [Double], fs: Double) {
        self.t = t
        self.ax = ax; self.ay = ay; self.az = az
        self.gx = gx; self.gy = gy; self.gz = gz
        self.fs = fs
    }

    public enum LoadError: Error, LocalizedError {
        case badHeader(String)
        case badRow(line: Int)
        case empty

        public var errorDescription: String? {
            switch self {
            case .badHeader(let h): return "CSVヘッダが不正です: \(h)"
            case .badRow(let line): return "CSVの\(line)行目を数値として読めません"
            case .empty: return "CSVにデータ行がありません"
            }
        }
    }

    public static func loadCSV(_ url: URL) throws -> SwimSession {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parseCSV(text)
    }

    /// dataio.load_swim_csv(to_si=True) と同一: 単位変換し、fs は t の
    /// 差分中央値から推定（差分が取れなければ 52 Hz）。
    public static func parseCSV(_ text: String) throws -> SwimSession {
        var t: [Double] = []
        var ax: [Double] = [], ay: [Double] = [], az: [Double] = []
        var gx: [Double] = [], gy: [Double] = [], gz: [Double] = []

        var first = true
        var lineNo = 0
        var err: LoadError?
        text.enumerateLines { line, stop in
            lineNo += 1
            if first {
                first = false
                if !line.hasPrefix("idx,t,ax") {
                    err = .badHeader(line)
                    stop = true
                }
                return
            }
            if line.isEmpty { return }
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count == 8,
                  let tv = Double(f[1]),
                  let axv = Double(f[2]), let ayv = Double(f[3]), let azv = Double(f[4]),
                  let gxv = Double(f[5]), let gyv = Double(f[6]), let gzv = Double(f[7])
            else {
                err = .badRow(line: lineNo)
                stop = true
                return
            }
            t.append(tv)
            ax.append(axv * g0); ay.append(ayv * g0); az.append(azv * g0)
            gx.append(gxv * deg2rad); gy.append(gyv * deg2rad); gz.append(gzv * deg2rad)
        }
        if let err { throw err }
        guard !t.isEmpty else { throw LoadError.empty }

        var fs = 52.0
        if t.count > 1 {
            var dt = [Double]()
            dt.reserveCapacity(t.count - 1)
            for i in 1..<t.count { dt.append(t[i] - t[i - 1]) }
            let med = Stats.median(dt)
            if med > 0 { fs = 1.0 / med }
        }
        return SwimSession(t: t, ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz, fs: fs)
    }
}
