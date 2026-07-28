import SwiftUI
import UniformTypeIdentifiers
import MokkoriCore

/// デバイスタブ: Mokkori IQ 本体まわりを1画面にまとめる。
///
/// **BLE (Phase D) がまだ無い**ので、いま実際に動くのは
///   - ログの取り込み（「ファイル」アプリ経由。タブレットで吸い出した CSV）
///   - 振動フィードバックの設定（アプリに保存。接続時に本体へ送る）
/// の2つだけ。バッテリー・メモリー・時刻合わせ・メモリー消去は本体と話す必要があるので、
/// **未接続であることを画面に出したうえで**操作を無効にしてある（黙って空欄にしない）。
struct DeviceView: View {
    @Environment(SessionStore.self) private var store
    @Environment(DeviceSettings.self) private var settings

    @State private var showImporter = false
    @State private var importing = false
    @State private var importError: String?
    @State private var importedName: String?
    /// 本体から読んだ値。BLE が入るまでは常に空。
    @State private var status = DeviceStatus()

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                recordingSection
                bodySection
                hapticSection
            }
            .navigationTitle("Mokkori IQ")
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText]) { res in
                guard case .success(let url) = res else { return }
                importing = true
                Task {
                    do {
                        let meta = try await store.importCSV(from: url)
                        importedName = meta.sourceFilename
                    } catch {
                        importError = error.localizedDescription
                    }
                    importing = false
                }
            }
            .alert("インポート失敗", isPresented: .init(
                get: { importError != nil },
                set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }

    // MARK: - 接続

    private var connectionSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "sensor.tag.radiowaves.forward")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("未接続")
                        .font(.headline)
                    Text("BLE 接続は未実装です（Phase D）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 2)
        } footer: {
            Text("いまは水から上がったあと、タブレットで吸い出した CSV を取り込みます。BLE が入ると、この画面から直接吸い出し・時刻合わせ・消去ができます。")
        }
    }

    // MARK: - 記録データ（本体メモリーの中身）

    /// メモリーの「中身の量」と「中身に対する操作（取り込む・消す）」は同じものの
    /// 話なので1つの節にまとめる。分けると、消したら容量がどうなるのかが見えない。
    private var recordingSection: some View {
        Section {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    MetricTile(label: "記録時間",
                               value: status.recordedSeconds.map(fmtClock) ?? "—",
                               color: status.recordedSeconds == nil ? .secondary : Metric.time)
                    MetricTile(label: "記録可能時間",
                               value: status.remainingSeconds.map(fmtClock) ?? "—",
                               color: status.remainingSeconds == nil ? .secondary : Metric.time)
                }
                .padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("メモリー使用量").font(.subheadline)
                        Spacer()
                        Text(status.usedFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(status.usedFraction == nil
                                             ? .secondary : Metric.distance)
                    }
                    ProgressView(value: status.usedFraction ?? 0)
                        .tint(Metric.distance)
                }
                .padding(.bottom, 8)
            }

            Button {
                showImporter = true
            } label: {
                HStack {
                    Label("ログを取り込む", systemImage: "square.and.arrow.down")
                    Spacer()
                    if importing { ProgressView() }
                }
            }
            .disabled(importing)

            Button {
            } label: {
                Label("本体から吸い出す（BLE）", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(true)

            Button(role: .destructive) {
            } label: {
                Label("メモリーを消去", systemImage: "trash")
            }
            .disabled(true)
        } header: {
            Text("記録データ")
        } footer: {
            if let name = importedName {
                Text("「\(name)」を取り込みました。ログタブで開けます")
            } else {
                Text("取り込んだログはログタブに並びます（\(store.sessions.count) 件）。フラッシュは 2MB で、52Hz なら約52分ぶん記録できます。消去は明示的に行ったときだけで、USB を抜いても消えません。")
            }
        }
        .headerProminence(.increased)
    }

    // MARK: - 本体

    private var bodySection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                MetricTile(label: "バッテリー",
                           value: status.batteryPercent.map { "\($0)" } ?? "—",
                           unit: status.batteryPercent == nil ? "" : "%",
                           color: status.batteryPercent == nil ? .secondary : Metric.stroke)
                MetricTile(label: "電圧",
                           value: status.batteryMillivolts.map {
                               String(format: "%.2f", Double($0) / 1000) } ?? "—",
                           unit: status.batteryMillivolts == nil ? "" : "V",
                           color: status.batteryMillivolts == nil ? .secondary : Metric.stroke)
            }
            .padding(.vertical, 8)

            Button {
            } label: {
                Label("時刻を合わせる",
                      systemImage: "clock.arrow.trianglehead.2.counterclockwise.rotate.90")
            }
            .disabled(true)
        } header: {
            Text("本体")
        } footer: {
            Text(status.isKnown
                 ? "本体の INFO から読んだ値です"
                 : "未接続なので読めていません。時刻合わせが入ると、ログのアップロード時に時刻を手で入れる必要がなくなります。")
        }
        .headerProminence(.increased)
    }

    // MARK: - 振動フィードバック

    private var hapticSection: some View {
        @Bindable var settings = settings
        return Section {
            ForEach(DeviceSettings.HapticPattern.allCases) { p in
                Picker(selection: .init(
                    get: { settings.haptic.trigger(p) ?? 0 },
                    set: { settings.haptic.setTrigger(p, $0 == 0 ? nil : $0) })) {
                    Text("未設定").tag(0)
                    ForEach(DeviceSettings.distanceChoices, id: \.self) { m in
                        Text("\(m)m ごと").tag(m)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.label)
                        Text(p.shape)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("強さ")
                    Spacer()
                    Text("\(settings.haptic.strengthPercent)%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: .init(
                    get: { Double(settings.haptic.strengthPercent) },
                    set: { settings.haptic.strengthPercent = Int($0.rounded()) }),
                       in: 20...100, step: 10)
            }

            Button {
            } label: {
                Label("試しに振動させる", systemImage: "waveform")
            }
            .disabled(true)

            if settings.haptic.hasDuplicateDistance {
                Label("同じ距離を2つのパターンに割り当てています。両方鳴るので区別できません",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("振動フィードバック")
        } footer: {
            Text("いまの設定: \(settings.hapticSummary)\n\nパターンは3種類に固定して、それぞれに「何mごとに鳴らすか」を割り当てます（未設定なら鳴りません）。強さではなく回数と長さで分けているのは、水中・水着越しでは強弱を聞き分けにくいためです。\n\n**まだ鳴りません**: 実機に振動モーターがまだ載っていない（配線が未実装）のと、BLE で設定を送る仕組みが未実装のためです。設定はアプリに保存され、両方そろったら送ります。")
        }
        .headerProminence(.increased)
    }
}
