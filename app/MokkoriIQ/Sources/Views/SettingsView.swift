import SwiftUI

/// 設定画面。Strava の API アプリ資格情報（mokkori-iq 専用に登録したもの）を
/// 入力して連携する。secret を含むので Keychain 保存（UserDefaults には置かない）。
struct SettingsView: View {
    @Environment(StravaService.self) private var strava
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var connecting = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                if strava.isConnected {
                    LabeledContent("連携中", value: strava.athleteName ?? "Strava")
                    Button("連携を解除", role: .destructive) { strava.disconnect() }
                } else {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            if connecting { ProgressView().padding(.trailing, 6) }
                            Text("Strava と連携")
                        }
                    }
                    .disabled(connecting || clientId.isEmpty || clientSecret.isEmpty)
                }
            } header: {
                Text("Strava")
            } footer: {
                Text("投稿は手動アクティビティ（sport_type=Swim）。scope は activity:write のみです")
            }

            Section {
                TextField("Client ID", text: $clientId)
                    .keyboardType(.numberPad)
                    .onChange(of: clientId) { _, v in strava.clientId = v }
                SecureField("Client Secret", text: $clientSecret)
                    .onChange(of: clientSecret) { _, v in strava.clientSecret = v }
            } header: {
                Text("API アプリ資格情報")
            } footer: {
                Text("strava.com/settings/api で登録したアプリの値です。Authorization Callback Domain は `localhost` にしてください（アプリのリダイレクトは \(StravaService.redirectURI)）。Keychain に保存されます")
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            clientId = strava.clientId
            clientSecret = strava.clientSecret
        }
        .alert("連携失敗", isPresented: .init(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func connect() async {
        connecting = true
        defer { connecting = false }
        do {
            try await strava.connect()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
