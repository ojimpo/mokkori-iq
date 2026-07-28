import SwiftUI

/// 設定画面。Strava へは自宅の strava-autopilot（= Strava ゲートウェイ）経由で
/// 投稿するので、ここで設定するのは **ゲートウェイの URL と API キー**だけ。
/// Strava の client_secret やトークンはスマホには置かない（理由は StravaService）。
struct SettingsView: View {
    @Environment(StravaService.self) private var strava
    @State private var gatewayURL = ""
    @State private var apiKey = ""
    @State private var checking = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                if strava.isConnected {
                    Label("接続確認済み", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button {
                    Task { await verify() }
                } label: {
                    HStack {
                        if checking { ProgressView().padding(.trailing, 6) }
                        Text("接続を確認")
                    }
                }
                .disabled(checking || apiKey.isEmpty || gatewayURL.isEmpty)
                if strava.isConnected {
                    Button("API キーを消す", role: .destructive) {
                        strava.disconnect()
                        apiKey = ""
                    }
                }
            } header: {
                Text("Strava ゲートウェイ")
            } footer: {
                Text("投稿は strava-autopilot 経由で行います（Strava は 1 アカウント 1 API アプリ・サブスク必須のため、トークンを持つのは NAS 側だけにしています）")
            }

            Section {
                TextField("ゲートウェイ URL", text: $gatewayURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: gatewayURL) { _, v in strava.gatewayURL = v }
                SecureField("API キー", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: apiKey) { _, v in strava.apiKey = v }
            } header: {
                Text("接続先")
            } footer: {
                Text("API キーは NAS の `~/dev/strava-autopilot/.env` の `GATEWAY_API_KEY` と同じ値です。Keychain に保存されます")
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            gatewayURL = strava.gatewayURL
            apiKey = strava.apiKey
        }
        .alert("接続できません", isPresented: .init(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func verify() async {
        checking = true
        defer { checking = false }
        do {
            try await strava.verify()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
