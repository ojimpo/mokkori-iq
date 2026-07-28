import Foundation
import Observation

/// Strava への投稿。**直接 Strava を叩かず、自宅の strava-autopilot が兼ねる
/// 「Strava ゲートウェイ」経由で投稿する**（`POST /api/gateway/activities`）。
///
/// なぜ経由するか（2026-07-28 の方針。CLAUDE.md「Strava 投稿の規約」の認証節）:
///   - Strava は **1 アカウントにつき API アプリ 1 個**で、その枠は既に
///     strava-autopilot が使っている。
///   - 2026-06 以降、Standard Tier の API 利用に **Strava サブスクが必須**に
///     なったため、「API 登録用の無料サブアカウントを作る」回避策は使えない。
///   - 同じ client を2箇所で認可するとトークン系統が枝分かれし、autopilot 側が
///     壊れうる。**トークンを持つのはゲートウェイだけ**にすればその心配がない。
///   - おまけに client_secret をスマホに配らずに済む（持つのは API キーのみ）。
///
/// ゲートウェイは公開 URL（既定 https://strava.ojimpo.com）にあるので、
/// Tailscale や自宅 LAN でなくても投稿できる。
@Observable
final class StravaService {

    static let defaultGatewayURL = "https://strava.ojimpo.com"

    private(set) var isConnected = false
    private(set) var lastCheckError: String?

    var gatewayURL: String {
        get { Keychain.get("gateway_url") ?? Self.defaultGatewayURL }
        set { Keychain.set(newValue, for: "gateway_url") }
    }
    var apiKey: String {
        get { Keychain.get("gateway_api_key") ?? "" }
        set { Keychain.set(newValue, for: "gateway_api_key") }
    }
    var hasCredentials: Bool { !apiKey.isEmpty && !gatewayURL.isEmpty }

    init() {
        isConnected = UserDefaults.standard.bool(forKey: "gateway_verified") && hasCredentials
    }

    enum StravaError: LocalizedError {
        case noCredentials
        case badURL
        case unauthorized
        case gateway(Int, String)

        var errorDescription: String? {
            switch self {
            case .noCredentials: return "ゲートウェイの URL / API キーが未設定です（設定画面から）"
            case .badURL: return "ゲートウェイ URL が不正です"
            case .unauthorized: return "API キーが違います（NAS の .env の GATEWAY_API_KEY と一致させてください）"
            case .gateway(let c, let m): return "ゲートウェイ エラー (\(c)): \(m)"
            }
        }
    }

    private func request(path: String, method: String, body: Data?) async throws -> Data {
        guard hasCredentials else { throw StravaError.noCredentials }
        guard let url = URL(string: gatewayURL + path), url.host != nil else {
            throw StravaError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw StravaError.unauthorized
        default:
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
                .flatMap { $0["detail"] as? String }
                ?? String(data: data, encoding: .utf8) ?? ""
            throw StravaError.gateway(status, detail)
        }
    }

    /// 疎通 + API キー確認。
    @MainActor
    func verify() async throws {
        _ = try await request(path: "/api/gateway/ping", method: "GET", body: nil)
        isConnected = true
        lastCheckError = nil
        UserDefaults.standard.set(true, forKey: "gateway_verified")
    }

    @MainActor
    func disconnect() {
        Keychain.delete("gateway_api_key")
        isConnected = false
        UserDefaults.standard.set(false, forKey: "gateway_verified")
    }

    // MARK: - 手動アクティビティ作成

    struct UploadResult {
        let activityId: Int
        let url: URL
    }

    private struct CreateRequest: Encodable {
        let name: String
        let sport_type: String
        let start_date_local: String
        let elapsed_time: Int
        let distance: Double
        let description: String
    }

    private struct CreateResponse: Decodable {
        let activity_id: Int
        let url: String
    }

    /// 規約どおりの手動アクティビティ作成。elapsed には moving（泳ぎのみ）を渡す。
    func createSwimActivity(name: String, startLocal: Date, movingSeconds: Int,
                            distanceMeters: Double, description: String)
    async throws -> UploadResult {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = .current
        let payload = CreateRequest(
            name: name, sport_type: "Swim",
            start_date_local: fmt.string(from: startLocal),
            elapsed_time: movingSeconds, distance: distanceMeters,
            description: description)
        let data = try await request(path: "/api/gateway/activities", method: "POST",
                                     body: try JSONEncoder().encode(payload))
        let res = try JSONDecoder().decode(CreateResponse.self, from: data)
        return UploadResult(activityId: res.activity_id,
                            url: URL(string: res.url)
                                ?? URL(string: "https://www.strava.com/activities/\(res.activity_id)")!)
    }
}
