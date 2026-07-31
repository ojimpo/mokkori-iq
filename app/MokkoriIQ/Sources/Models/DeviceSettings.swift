import Foundation
import Observation

/// デバイス（Mokkori IQ 本体）の設定。**アプリ側に保存し、BLE がつながったときに
/// 本体へ送る**。BLE(Phase D) はまだ無いので、いまは保存だけが動く。
///
/// 振動フィードバックの設計上の注意（CLAUDE.md「距離ベース振動フィードバック」）:
/// 距離で鳴らすには**デバイス上のコーザルな壁カウンタ**が要る。解析側の
/// リズムリカバリ／デフラグ／min() クロスチェックは非コーザル（セッション全体の
/// 中央値や「次の壁」を見る）なので、そのままでは実機のリアルタイムに使えない。
/// リアルタイムで効くのは精度ではなく**ドリフトしないこと**（1回落とすと以降ずっとズレる）。
@Observable
final class DeviceSettings {

    /// 振動パターンは**3種類に固定**し、それぞれに「何 m ごとに鳴らすか」を割り当てる。
    /// 未設定にすればそのパターンは鳴らない。
    ///
    /// この形にした理由（ユーザー判断 2026-07-28）: 「1000m 連続で泳ぐ」以外の使い方
    /// （100m ごとに知らせつつ 500m で区切りを知らせる、等）にも同じ仕組みで対応できる。
    /// 逆に「距離ひとつ + パターンひとつ」だと使い方が変わるたびに作り直しになる。
    ///
    /// **パターンは股間装着＋水着越しで判別できることが要件**なので、強さではなく
    /// **回数と長さ**で分けている（水中で強弱を聞き分けるのは難しい）。
    /// 実際の値は実機で叩いて詰める（現在は未検証の初期値）。
    enum HapticPattern: Int, Codable, CaseIterable, Identifiable {
        case one = 1
        case two = 2
        case three = 3

        public var id: Int { rawValue }
        var label: String { "振動パターン\(rawValue)" }
        /// 体感の説明。ピッカーの副題に出す
        var shape: String {
            switch self {
            case .one:   return "短く1回"
            case .two:   return "短く2回"
            case .three: return "長く1回"
            }
        }
        /// ON/OFF のミリ秒列（そのままファームへ渡せる形。`VIB [ms] [pct]` 相当）
        var pulsesMs: [Int] {
            switch self {
            case .one:   return [180]
            case .two:   return [180, 140, 180]
            case .three: return [700]
            }
        }
    }

    struct Haptic: Codable, Equatable {
        /// パターン1..3 の発動距離（m）。nil = 未設定 = 鳴らさない
        var triggers: [Int?] = [nil, nil, nil]
        var strengthPercent = 100

        func trigger(_ p: HapticPattern) -> Int? {
            let i = p.rawValue - 1
            return triggers.indices.contains(i) ? triggers[i] : nil
        }
        mutating func setTrigger(_ p: HapticPattern, _ meters: Int?) {
            let i = p.rawValue - 1
            while triggers.count <= i { triggers.append(nil) }
            triggers[i] = meters
        }
        var isActive: Bool { triggers.contains { $0 != nil } }
        /// 同じ距離を2つのパターンに割り当てると両方鳴って区別できない
        var hasDuplicateDistance: Bool {
            let set = triggers.compactMap { $0 }
            return Set(set).count != set.count
        }
    }

    /// 選ばせる距離。25m プールのラップ単位に乗るものだけ。
    static let distanceChoices = [25, 50, 100, 200, 500, 1000]

    var haptic: Haptic {
        didSet { if haptic != oldValue { save() } }
    }

    private let defaults: UserDefaults
    private static let key = "device.haptic"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let v = try? JSONDecoder().decode(Haptic.self, from: data) {
            haptic = v
        } else {
            haptic = Haptic()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(haptic) {
            defaults.set(data, forKey: Self.key)
        }
    }

    /// 設定を人が読める1行に（画面のフッタと、将来の送信ログ用）。
    var hapticSummary: String {
        let on = HapticPattern.allCases.compactMap { p -> String? in
            guard let m = haptic.trigger(p) else { return nil }
            return "\(p.label)=\(m)m"
        }
        return on.isEmpty ? "すべて未設定" : on.joined(separator: " / ")
            + "・強さ \(haptic.strengthPercent)%"
    }
}

/// 本体から読んだ状態（バッテリー・メモリー）。未接続のあいだは全部 nil。
/// BLE の状態 characteristic (…0003) が返す 36 B のブロブをそのまま写したもので、
/// USB の `INFO` が出す値と同じ並び（`tools/flash_dump.py --info`）。
struct DeviceStatus: Equatable {
    var batteryPercent: Int?
    var batteryMillivolts: Int?
    var charging: Bool?
    /// 記録済みサンプル数と、フラッシュに入る上限
    var samples: Int?
    var capacitySamples: Int?
    /// 記録のサンプルレート（残り時間の計算に使う）
    var sampleRate: Double = 52.0
    /// 本体のいまの様子。記録中はスマホが繋がっていないときなので、繋いでいる
    /// あいだ isLogging は落ちる（本体はセントラル接続中は記録を止める）
    var isLogging = false
    var isFull = false
    var isErasing = false
    /// 最後に打った時刻アンカー（「サンプル K = この時刻」）。未設定なら nil
    var lastAnchor: Date?
    var lastAnchorIndex: Int?

    var isKnown: Bool { batteryPercent != nil || samples != nil }

    /// アンカーとサンプルレートから、記録の先頭（サンプル0）の絶対時刻を逆算する。
    /// Strava へ出すときの「泳ぎ始め」の手入力がこれで要らなくなる。
    var startEpoch: Date? {
        guard let a = lastAnchor, let k = lastAnchorIndex, sampleRate > 0 else { return nil }
        return a.addingTimeInterval(-Double(k) / sampleRate)
    }

    var usedFraction: Double? {
        guard let s = samples, let c = capacitySamples, c > 0 else { return nil }
        return min(1.0, Double(s) / Double(c))
    }
    /// あと何秒記録できるか
    var remainingSeconds: Double? {
        guard let s = samples, let c = capacitySamples, sampleRate > 0 else { return nil }
        return max(0, Double(c - s)) / sampleRate
    }
    var recordedSeconds: Double? {
        guard let s = samples, sampleRate > 0 else { return nil }
        return Double(s) / sampleRate
    }
}
