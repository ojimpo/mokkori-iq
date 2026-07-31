import SwiftUI
import UniformTypeIdentifiers
import MokkoriCore

/// デバイスタブ: Mokkori IQ 本体まわりを1画面にまとめる。
///
/// BLE (Phase D) が入ったので、この画面はすべて本体と話す:
///   - 記録の吸い出し（水から上がってその場で。タブレットが要らない）
///   - バッテリー・メモリーの残り
///   - 時刻合わせ（本体は電源 OFF 中に時計を保持できないのでスマホが渡す）
///   - メモリー消去
///   - 振動フィードバックの設定と、パターンの体感テスト
/// 「ファイル」からの CSV 取り込みは、タブレットで吸い出した過去ぶんのために残す。
struct DeviceView: View {
    @Environment(SessionStore.self) private var store
    @Environment(DeviceSettings.self) private var settings
    @Environment(BLEManager.self) private var ble

    @State private var showImporter = false
    @State private var importing = false
    @State private var importError: String?
    @State private var importedName: String?
    @State private var confirmErase = false

    private var status: DeviceStatus { ble.status }

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                recordingSection
                bodySection
                hapticSection
            }
            .navigationTitle("Mokkori IQ")
            .task { ble.start() }
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
            .alert("エラー", isPresented: .init(
                get: { ble.lastError != nil },
                set: { if !$0 { ble.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(ble.lastError ?? "")
            }
            .confirmationDialog("本体のメモリーを消去しますか？",
                                isPresented: $confirmErase, titleVisibility: .visible) {
                Button("消去する", role: .destructive) { ble.erase() }
                Button("やめる", role: .cancel) {}
            } message: {
                Text(status.recordedSeconds.map {
                    "記録 \(fmtClock($0)) ぶんが消えます。取り消せません。"
                } ?? "記録が消えます。取り消せません。")
            }
        }
    }

    // MARK: - 接続

    /// 本体は電源が入っている間ずっとアドバタイズしているので、この画面を開けば
    /// 勝手に繋がる。繋がっていないときは**理由を出す**（黙って空欄にしない）。
    private var connectionSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: ble.isConnected
                      ? "sensor.tag.radiowaves.forward.fill"
                      : "sensor.tag.radiowaves.forward")
                    .font(.title2)
                    .foregroundStyle(ble.isConnected ? Metric.stroke : .secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connectionTitle).font(.headline)
                    Text(connectionDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if ble.connection == .scanning || ble.connection == .connecting {
                    ProgressView()
                }
            }
            .padding(.vertical, 2)
        } footer: {
            if let action = ble.lastAction {
                Text(action)
            } else {
                Text("本体の電源が入っていれば自動で繋がります。水中では電波が届かないので、上がってから操作してください。")
            }
        }
    }

    private var connectionTitle: String {
        switch ble.connection {
        case .connected:    return ble.deviceName ?? "Mokkori IQ"
        case .connecting:   return "接続中…"
        case .scanning:     return "本体をさがしています"
        case .poweredOff:   return "Bluetooth がオフです"
        case .unauthorized: return "Bluetooth の使用が許可されていません"
        case .unsupported:  return "この端末は Bluetooth LE に対応していません"
        case .idle:         return "未接続"
        }
    }

    private var connectionDetail: String {
        switch ble.connection {
        case .connected:
            if status.isErasing { return "メモリーを消去しています…" }
            if status.isFull { return "メモリーが満杯です。吸い出してから消去してください" }
            return "接続済み（記録は一時停止しています）"
        case .scanning:     return "本体のスイッチが入っているか確認してください"
        case .poweredOff:   return "設定 → Bluetooth をオンにしてください"
        case .unauthorized: return "設定 → Mokkori IQ → Bluetooth を許可してください"
        default:            return "—"
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

            if let t = ble.transfer {
                transferRow(t)
            } else {
                Button {
                    pull()
                } label: {
                    HStack {
                        Label("本体から吸い出す", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        if importing { ProgressView() }
                    }
                }
                .disabled(!ble.isConnected || (status.samples ?? 0) == 0 || importing)
            }

            Button {
                showImporter = true
            } label: {
                Label("CSV から取り込む", systemImage: "square.and.arrow.down")
            }
            .disabled(importing || ble.transfer != nil)

            Button(role: .destructive) {
                confirmErase = true
            } label: {
                Label("メモリーを消去", systemImage: "trash")
            }
            .disabled(!ble.isConnected || status.isErasing || ble.transfer != nil)
        } header: {
            Text("記録データ")
        } footer: {
            if let name = importedName {
                Text("「\(name)」を取り込みました。ログタブで開けます。本体のメモリーは消していないので、確認してから消去してください")
            } else {
                Text("取り込んだログはログタブに並びます（\(store.sessions.count) 件）。消去は明示的に行ったときだけで、吸い出しただけでは消えません。")
            }
        }
        .headerProminence(.increased)
    }

    /// 吸い出しは 2MB 近くを BLE で流すので分単位でかかる。何 % かだけでなく
    /// **実測スループットから出した残り時間**を出す（見積もりを勘で盛らない）。
    private func transferRow(_ t: BLEManager.Transfer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("吸い出し中").font(.subheadline)
                Spacer()
                Text("\(Int((t.fraction * 100).rounded()))%")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Metric.distance)
            }
            ProgressView(value: t.fraction).tint(Metric.distance)
            HStack {
                // 受信量は常に出す。残り時間は実測が溜まってから足す
                // （プレースホルダを出すくらいなら実数を出す）
                Text(fmtClock(Double(t.received) / max(1, status.sampleRate))
                     + " / " + fmtClock(Double(t.total) / max(1, status.sampleRate))
                     + (t.remainingSeconds.map { "・残り約 \(fmtClock($0))" } ?? ""))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("中止") { ble.cancelPull() }
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func pull() {
        importing = true
        ble.pullLog { result in
            switch result {
            case .failure(let e):
                importing = false
                importError = e.localizedDescription
            case .success(let rec):
                let stamp = fileStamp(status.startEpoch ?? Date())
                Task {
                    do {
                        let meta = try await store.importRaw(
                            rec, name: "swim_\(stamp).ble", startEpoch: status.startEpoch)
                        importedName = meta.sourceFilename
                    } catch {
                        importError = error.localizedDescription
                    }
                    importing = false
                }
            }
        }
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

            // 自動で合うので普段は押さなくていい。手動は「いま合わせ直したい」用に残す。
            Button {
                ble.syncTime()
            } label: {
                Label("いま合わせ直す",
                      systemImage: "clock.arrow.trianglehead.2.counterclockwise.rotate.90")
            }
            .disabled(!ble.isConnected)
        } header: {
            Text("本体")
        } footer: {
            if !ble.isConnected {
                Text("未接続なので読めていません。")
            } else if let a = status.lastAnchor {
                Text("時刻は接続したときに自動で合わせています（最後に合わせたのは \(fmtDayTime(a))）。泳ぎ始めの時刻が自動で入るので、Strava へ出すときに手で入れる必要はありません。")
            } else {
                Text("時刻を合わせています…（本体は電源を切ると時計を忘れるので、繋いだときに毎回合わせ直します）")
            }
        }
        .headerProminence(.increased)
    }

    // MARK: - 振動フィードバック

    private var hapticSection: some View {
        @Bindable var settings = settings
        return Section {
            ForEach(DeviceSettings.HapticPattern.allCases) { p in
                HStack {
                    Picker(selection: .init(
                        get: { settings.haptic.trigger(p) ?? 0 },
                        set: {
                            settings.haptic.setTrigger(p, $0 == 0 ? nil : $0)
                            ble.sendHaptics(settings.haptic)
                        })) {
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
                    // パターンは体感で選ぶものなので、その場で鳴らせるようにする
                    Button {
                        ble.testVibrate(p, strengthPercent: settings.haptic.strengthPercent)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!ble.isConnected)
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
                    .onChange(of: settings.haptic) { _, h in ble.sendHaptics(h) }
            }

            if settings.haptic.hasDuplicateDistance {
                Label("同じ距離を2つのパターンに割り当てています。両方鳴るので区別できません",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("振動フィードバック")
        } footer: {
            Text("いまの設定: \(settings.hapticSummary)\n\nパターンは3種類に固定して、それぞれに「何mごとに鳴らすか」を割り当てます（未設定なら鳴りません）。強さではなく回数と長さで分けているのは、水中・水着越しでは強弱を聞き分けにくいためです。\n\n**泳いでいる最中はまだ鳴りません**: 実機に振動モーターが載っておらず（配線が未実装）、距離を数えるコーザルな壁カウンタも本体側に入っていないためです。設定の送信と体感テストはここから動きます。")
        }
        .headerProminence(.increased)
    }
}

/// 吸い出したセッションのファイル名に使う日時。CSV 経由と同じ `swim_YYYYMMDD_HHMMSS`
/// の形にそろえる（一覧の日付推定がファイル名を見るため）。
private func fileStamp(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd_HHmmss"
    return f.string(from: d)
}
