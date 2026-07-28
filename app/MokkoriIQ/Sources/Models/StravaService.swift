import Foundation
import AuthenticationServices
import Observation

/// Strava 連携。mokkori-iq 専用の API アプリ（サブアカウントで登録）の
/// client_id/secret を設定画面から受け取り、本アカウントで認可する。
/// - 認可: ASWebAuthenticationSession + **web の** oauth/authorize。
///   `oauth/mobile/authorize` は Strava アプリへ app-to-app で飛ばす経路で、
///   コールバックが認証セッションの外に戻って取りこぼす。セッション内で完結する
///   web 版を使う（Strava アプリの有無に関わらず同じ挙動になる）。
///   redirect はカスタムスキーム `mokkoriiq://localhost/callback`
///   （Strava は localhost をコールバックドメイン設定に関係なくホワイトリスト）。
/// - トークン: Keychain 保存。期限切れは自前の refresh_token でリフレッシュ
///   （専用 client なので autopilot と競合しない）。
/// - 投稿規約は CLAUDE.md「Strava 投稿の規約」: 手動アクティビティ POST、
///   elapsed_time = moving（泳ぎのみ）、start_date_local = 泳ぎ始め。
@Observable
final class StravaService: NSObject {

    static let redirectScheme = "mokkoriiq"
    static let redirectURI = "mokkoriiq://localhost/callback"

    private struct Token: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: TimeInterval
    }

    private(set) var isConnected = false
    private(set) var athleteName: String?

    var clientId: String {
        get { Keychain.get("strava_client_id") ?? "" }
        set { Keychain.set(newValue, for: "strava_client_id") }
    }
    var clientSecret: String {
        get { Keychain.get("strava_client_secret") ?? "" }
        set { Keychain.set(newValue, for: "strava_client_secret") }
    }
    var hasCredentials: Bool { !clientId.isEmpty && !clientSecret.isEmpty }

    override init() {
        super.init()
        isConnected = loadToken() != nil
        athleteName = Keychain.get("strava_athlete_name")
    }

    enum StravaError: LocalizedError {
        case noCredentials
        case notConnected
        case authFailed(String)
        case api(Int, String)

        var errorDescription: String? {
            switch self {
            case .noCredentials: return "client_id / client_secret が未設定です（設定画面から）"
            case .notConnected: return "Strava 未連携です（設定画面から連携）"
            case .authFailed(let m): return "認可に失敗しました: \(m)"
            case .api(let c, let m): return "Strava API エラー (\(c)): \(m)"
            }
        }
    }

    // MARK: - 認可フロー

    private var authSession: ASWebAuthenticationSession?

    @MainActor
    func connect() async throws {
        guard hasCredentials else { throw StravaError.noCredentials }
        var comps = URLComponents(string: "https://www.strava.com/oauth/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "approval_prompt", value: "auto"),
            .init(name: "scope", value: "activity:write"),
        ]
        let code: String = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: comps.url!, callbackURLScheme: Self.redirectScheme) { url, err in
                if let err {
                    cont.resume(throwing: StravaError.authFailed(err.localizedDescription))
                    return
                }
                guard let url,
                      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                          .queryItems,
                      let code = items.first(where: { $0.name == "code" })?.value else {
                    cont.resume(throwing: StravaError.authFailed("コールバックに code がありません"))
                    return
                }
                cont.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            session.start()
        }
        try await exchangeToken(code: code)
    }

    func disconnect() {
        Keychain.delete("strava_token")
        Keychain.delete("strava_athlete_name")
        isConnected = false
        athleteName = nil
    }

    private func exchangeToken(code: String) async throws {
        let data = try await tokenRequest([
            "client_id": clientId,
            "client_secret": clientSecret,
            "code": code,
            "grant_type": "authorization_code",
        ])
        if let athlete = data["athlete"] as? [String: Any] {
            let name = [athlete["firstname"], athlete["lastname"]]
                .compactMap { $0 as? String }.joined(separator: " ")
            Keychain.set(name, for: "strava_athlete_name")
            await MainActor.run { athleteName = name }
        }
        await MainActor.run { isConnected = true }
    }

    private func tokenRequest(_ params: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)"
        }.joined(separator: "&").data(using: .utf8)
        let (body, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let expires = json["expires_at"] as? TimeInterval else {
            throw StravaError.api(status, String(data: body, encoding: .utf8) ?? "")
        }
        saveToken(Token(accessToken: access, refreshToken: refresh, expiresAt: expires))
        return json
    }

    private func loadToken() -> Token? {
        guard let s = Keychain.get("strava_token"),
              let t = try? JSONDecoder().decode(Token.self, from: Data(s.utf8)) else {
            return nil
        }
        return t
    }

    private func saveToken(_ t: Token) {
        if let data = try? JSONEncoder().encode(t),
           let s = String(data: data, encoding: .utf8) {
            Keychain.set(s, for: "strava_token")
        }
    }

    /// 有効なアクセストークン（5分バッファで自前リフレッシュ）。
    private func validAccessToken() async throws -> String {
        guard let token = loadToken() else { throw StravaError.notConnected }
        if Date().timeIntervalSince1970 < token.expiresAt - 300 {
            return token.accessToken
        }
        let data = try await tokenRequest([
            "client_id": clientId,
            "client_secret": clientSecret,
            "grant_type": "refresh_token",
            "refresh_token": token.refreshToken,
        ])
        guard let access = data["access_token"] as? String else {
            throw StravaError.notConnected
        }
        return access
    }

    // MARK: - 手動アクティビティ作成

    struct UploadResult {
        let activityId: Int
        var url: URL { URL(string: "https://www.strava.com/activities/\(activityId)")! }
    }

    /// 規約どおりの手動アクティビティ POST。elapsed は moving（泳ぎのみ）を渡す。
    func createSwimActivity(name: String, startLocal: Date, movingSeconds: Int,
                            distanceMeters: Double, description: String)
    async throws -> UploadResult {
        let token = try await validAccessToken()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = .current
        let params: [String: String] = [
            "name": name,
            "sport_type": "Swim",
            "start_date_local": fmt.string(from: startLocal),
            "elapsed_time": String(movingSeconds),
            "distance": String(format: "%.0f", distanceMeters),
            "description": description,
        ]
        var req = URLRequest(url: URL(string: "https://www.strava.com/api/v3/activities")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+="))) ?? $0.value)"
        }.joined(separator: "&").data(using: .utf8)
        let (body, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = json["id"] as? Int else {
            throw StravaError.api(status, String(data: body, encoding: .utf8) ?? "")
        }
        return UploadResult(activityId: id)
    }
}

extension StravaService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}
