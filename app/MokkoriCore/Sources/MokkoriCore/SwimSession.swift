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
    /// flash_dump save_csv が書くヘッダ（`idx,t,ax,ay,az,gx,gy,gz`）
    public static let csvHeaderPrefix = "idx,t,ax"

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
        try parseCSV(try Data(contentsOf: url))
    }

    public static func parseCSV(_ text: String) throws -> SwimSession {
        try parseCSV(Data(text.utf8))
    }

    /// dataio.load_swim_csv(to_si=True) と同一: 単位変換し、fs は t の
    /// 差分中央値から推定（差分が取れなければ 52 Hz）。
    public static func parseCSV(_ data: Data) throws -> SwimSession {
        // 列数だけ合う別物の CSV を黙って読まないよう、ヘッダは必ず確かめる
        let head = String(decoding: data.prefix(64), as: UTF8.self)
        guard head.hasPrefix(csvHeaderPrefix) else {
            throw LoadError.badHeader(head.split(separator: "\n").first.map(String.init) ?? "")
        }

        var t: [Double] = []
        var ax: [Double] = [], ay: [Double] = [], az: [Double] = []
        var gx: [Double] = [], gy: [Double] = [], gz: [Double] = []

        let ok = FastCSV.scan(data, columns: 8) { _, f in
            t.append(f[1])
            ax.append(f[2] * g0); ay.append(f[3] * g0); az.append(f[4] * g0)
            gx.append(f[5] * deg2rad); gy.append(f[6] * deg2rad); gz.append(f[7] * deg2rad)
            return true
        }
        guard ok else { throw LoadError.badRow(line: t.count + 2) }  // ヘッダ + 読めた行数
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
