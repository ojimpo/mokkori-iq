import SwiftUI
import MokkoriCore

/// Strava アップ画面。壁インターバルで確認した結果をそのまま投稿する。
/// 規約（CLAUDE.md）どおり: 表示時間 = 泳ぎのみ / 開始 = 泳ぎ始め / 距離 = 最良推定。
/// 時刻アンカーは BLE 時刻同期が入るまで手動入力（デバイスに RTC が無いため）。
struct StravaUploadView: View {
    @Bindable var model: SessionAnalysisModel
    @Environment(StravaService.self) private var strava
    @Environment(\.dismiss) private var dismiss

    @State private var anchorMode: AnchorMode = .swimStart
    @State private var anchorInput = Date()
    @State private var name = ""
    @State private var uploading = false
    @State private var errorText: String?
    @State private var uploadedURL: URL?

    /// 手動アンカーの入力方法。7/28 は「退館時刻」から逆算して実証した経路なので、
    /// 記録の任意の1点を指定できるようにしてある。
    enum AnchorMode: String, CaseIterable {
        case swimStart = "泳ぎ始め"
        case recordEnd = "記録終了"

        var help: String {
            switch self {
            case .swimStart: return "1ラップ目を泳ぎ出した時刻"
            case .recordEnd: return "記録が終わった（スイッチOFF/満杯）時刻"
            }
        }
    }

    var body: some View {
        Form {
            if let url = uploadedURL {
                Section {
                    Label("アップロードしました", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Link("Strava で開く", destination: url)
                }
            }

            Section {
                Picker("基準にする時刻", selection: $anchorMode) {
                    ForEach(AnchorMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                DatePicker(anchorMode.rawValue, selection: $anchorInput)
                    .datePickerStyle(.compact)
            } header: {
                Text("時刻アンカー")
            } footer: {
                Text("\(anchorMode.help)を入れると、記録全体の絶対時刻が逆算されます（デバイスに時計が無いため。BLE 時刻同期が入るまでの手動入力）")
            }

            if let summary = previewSummary {
                Section {
                    TextField("アクティビティ名", text: $name)
                    LabeledContent("開始時刻", value: summary.startLocal
                        .formatted(date: .abbreviated, time: .standard))
                    LabeledContent("距離", value: fmtMeters(summary.distanceMeters))
                    LabeledContent("表示時間", value: fmtTime(Double(summary.movingSeconds)))
                    Text(summary.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("投稿内容")
                } footer: {
                    Text("表示時間は泳ぎのみ（moving time）。休憩を含む実経過は説明文に併記されます")
                }

                Section {
                    Button {
                        Task { await upload(summary) }
                    } label: {
                        HStack {
                            if uploading { ProgressView().padding(.trailing, 6) }
                            Text(uploadedURL == nil ? "Strava へアップ" : "もう一度アップ")
                        }
                    }
                    .disabled(uploading || !strava.isConnected)
                } footer: {
                    if !strava.isConnected {
                        Text("設定画面でゲートウェイの接続を確認してください")
                    }
                }
            }
        }
        .navigationTitle("Strava へアップ")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let anchor = model.meta.startEpoch {
                anchorMode = .swimStart
                anchorInput = model.swimStartDate ?? anchor
            }
            if name.isEmpty, let s = previewSummary { name = s.name }
        }
        .onChange(of: anchorInput) { _, _ in
            if let s = previewSummary, name.isEmpty { name = s.name }
        }
        .alert("アップロード失敗", isPresented: .init(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    /// 入力した1点から sample0 の絶対時刻を逆算する
    private var computedStartEpoch: Date? {
        guard let report = model.report else { return nil }
        switch anchorMode {
        case .swimStart:
            guard let first = report.intervals.first else { return nil }
            return anchorInput.addingTimeInterval(-first.span.start)
        case .recordEnd:
            return anchorInput.addingTimeInterval(-report.elapsed)
        }
    }

    private var previewSummary: StravaSummary? {
        guard let report = model.report, let epoch = computedStartEpoch else { return nil }
        return StravaSummary(report: report, startEpoch: epoch)
    }

    private func upload(_ summary: StravaSummary) async {
        uploading = true
        defer { uploading = false }
        do {
            let result = try await strava.createSwimActivity(
                name: name.isEmpty ? summary.name : name,
                startLocal: summary.startLocal,
                movingSeconds: summary.movingSeconds,
                distanceMeters: summary.distanceMeters,
                description: summary.description)
            model.setStartEpoch(computedStartEpoch)
            model.setStravaActivityId(result.activityId)
            uploadedURL = result.url
        } catch {
            errorText = error.localizedDescription
        }
    }
}
