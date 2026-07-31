import CoreBluetooth
import Foundation
import Observation
import MokkoriCore

/// Mokkori IQ 本体との BLE 接続（CoreBluetooth セントラル）。
///
/// GATT は `docs/ble_time_sync_design.md` のとおり。本体は**電源が入っている間ずっと
/// アドバタイズ**しているので、この画面を開いたらスキャンして自動で繋ぐ。
/// タップで起こす方式（設計書の当初案）は、しきい値を実際の泳ぎデータで詰めるまで
/// 「起こしたいのに起きない」が起こりうるので後回しにした。
///
/// 本体側は**セントラルが繋がっている間は記録を止める**。話すのは必ず水から
/// 上がったあとなので実運用に影響は無く、吸い出し中にフラッシュへ書き込まれない。
///
/// CoreBluetooth のコールバックはメインキューで受ける。吸い出しの1フレームは
/// 244B の memcpy で、最速でも毎秒 200 回程度なのでメインで捌いて問題無い
/// （重いのは取り込み後の解析で、そちらは SessionStore が別スレッドへ逃がす）。
@Observable
final class BLEManager: NSObject {

    enum Connection: Equatable {
        case idle                  // まだ始めていない
        case unauthorized          // Bluetooth の使用を許可されていない
        case poweredOff            // Bluetooth が切られている
        case unsupported
        case scanning
        case connecting
        case connected
    }

    /// 吸い出しの進行状況。nil のときは吸い出していない。
    struct Transfer: Equatable {
        var received: Int          // 受信済みサンプル数
        var total: Int             // 本体が持っているサンプル数
        var startedAt: Date
        var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
        /// 実測スループットから出す残り時間。マージンを勘で盛らない。
        var remainingSeconds: Double? {
            let elapsed = Date().timeIntervalSince(startedAt)
            guard elapsed > 2, received > 0, received < total else { return nil }
            return Double(total - received) * elapsed / Double(received)
        }
    }

    private(set) var connection: Connection = .idle
    private(set) var status = DeviceStatus()
    private(set) var deviceName: String?
    private(set) var transfer: Transfer?
    /// 最後に成功した操作の一言（時刻を合わせた・消去した など）。画面に出す
    private(set) var lastAction: String?
    var lastError: String?

    var isConnected: Bool { connection == .connected }

    // MARK: - GATT

    private static func uuid(_ n: UInt8) -> CBUUID {
        CBUUID(string: String(format: "6D6B6F69-A55A-4000-8000-0000000000%02X", n))
    }
    static let serviceUUID = uuid(1)
    private static let timeUUID = uuid(2)
    private static let statusUUID = uuid(3)
    private static let dataUUID = uuid(4)
    private static let controlUUID = uuid(5)

    private enum Op: UInt8 {
        case erase = 0x01
        case vibrate = 0x02
        case setHaptic = 0x03
        case dumpStart = 0x10
        case dumpStop = 0x11
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var timeChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?
    private var dataChar: CBCharacteristic?
    private var controlChar: CBCharacteristic?

    // 吸い出しの組み立て。フレームは絶対サンプル番号つきで届くので、
    // 順序が崩れても穴が空いても検出できる（黙って短いCSVを作らない）。
    private var dumpBuffer: [Int16] = []
    private var dumpExpected = 0
    private var dumpNextIndex = 0
    private var dumpGap = false
    private var dumpCompletion: ((Result<RawRecording, Error>) -> Void)?
    private var lastProgressPublish = Date.distantPast

    enum BLEError: LocalizedError {
        case notConnected
        case dumpGap(at: Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .notConnected: return "本体に接続していません"
            case .dumpGap(let i): return "受信データが \(i) サンプル目で欠けています。もう一度お試しください"
            case .empty: return "本体に記録がありません"
            }
        }
    }

    // MARK: - 接続

    /// 画面が出たら呼ぶ。CBCentralManager はここで初めて作る
    /// （init で作ると、画面を見てもいないのに Bluetooth の許可を聞かれる）。
    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            scanIfReady()
        }
    }

    func disconnect() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        connection = central?.state == .poweredOn ? .idle : connection
    }

    private func scanIfReady() {
        guard let central, central.state == .poweredOn else { return }
        guard connection != .connected, connection != .connecting else { return }
        connection = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID])
    }

    // MARK: - 操作

    /// 本体に「いまが何時か」を教える。本体は電源 OFF 中に時計を保持できないので、
    /// サンプル番号と epoch の対応（アンカー）をフラッシュに追記させる。
    func syncTime() {
        guard let p = peripheral, let c = timeChar else { lastError = BLEError.notConnected.localizedDescription; return }
        var ms = UInt64((Date().timeIntervalSince1970 * 1000).rounded())
        let data = Data(bytes: &ms, count: 8)
        p.writeValue(data, for: c, type: .withResponse)
        lastAction = "時刻を合わせました"
        readStatusSoon()
    }

    func erase() {
        write(.erase)
        lastAction = "メモリーを消去しています"
        readStatusSoon(after: 1.0)
    }

    /// 振動を1回試す。パターンは ON/OFF の ms 列としてそのまま本体へ渡し、
    /// 本体側のタイミングで鳴らす（BLE の往復ゆらぎでパターンが崩れないように）。
    func testVibrate(_ pattern: DeviceSettings.HapticPattern, strengthPercent: Int) {
        var payload = Data([Op.vibrate.rawValue,
                            UInt8(clamping: strengthPercent),
                            UInt8(clamping: pattern.pulsesMs.count)])
        for ms in pattern.pulsesMs {
            var v = UInt16(clamping: ms)
            payload.append(Data(bytes: &v, count: 2))
        }
        writeRaw(payload)
        lastAction = "\(pattern.label)を鳴らしました"
    }

    /// 振動フィードバックの設定を本体へ送る。本体は RAM に持つだけなので、
    /// 繋いだときに毎回送り直す（電源を切ると消える）。
    func sendHaptics(_ h: DeviceSettings.Haptic) {
        guard isConnected else { return }
        var payload = Data([Op.setHaptic.rawValue, UInt8(clamping: h.strengthPercent)])
        for i in 0..<3 {
            var m = UInt16(clamping: h.triggers.indices.contains(i) ? (h.triggers[i] ?? 0) : 0)
            payload.append(Data(bytes: &m, count: 2))
        }
        writeRaw(payload)
    }

    /// 本体の記録をまるごと受け取る。返るのは raw.bin と同じ int16 の並びなので、
    /// そのまま SessionStore に渡せば CSV 経由と同じ解析結果になる。
    func pullLog(completion: @escaping (Result<RawRecording, Error>) -> Void) {
        guard let p = peripheral, let c = controlChar, let d = dataChar else {
            completion(.failure(BLEError.notConnected)); return
        }
        guard let total = status.samples, total > 0 else {
            completion(.failure(BLEError.empty)); return
        }
        dumpBuffer = [Int16](repeating: 0, count: total * 6)
        dumpExpected = total
        dumpNextIndex = 0
        dumpGap = false
        dumpCompletion = completion
        transfer = Transfer(received: 0, total: total, startedAt: Date())

        p.setNotifyValue(true, for: d)
        var payload = Data([Op.dumpStart.rawValue])
        var from = UInt32(0)
        payload.append(Data(bytes: &from, count: 4))
        p.writeValue(payload, for: c, type: .withResponse)
    }

    func cancelPull() {
        write(.dumpStop)
        transfer = nil
        dumpCompletion = nil
        dumpBuffer = []
    }

    private func write(_ op: Op) { writeRaw(Data([op.rawValue])) }

    private func writeRaw(_ data: Data) {
        guard let p = peripheral, let c = controlChar else {
            lastError = BLEError.notConnected.localizedDescription; return
        }
        p.writeValue(data, for: c, type: .withResponse)
    }

    private func readStatusSoon(after: TimeInterval = 0.3) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.statusChar else { return }
            p.readValue(for: c)
        }
    }

    // MARK: - 受信

    /// 36 B の状態ブロブ。**先頭のバージョンだけ見て、知らない後ろは読み飛ばす**
    /// （ファームは後ろに足すだけにしてあるので、本体とアプリの更新がずれても動く）。
    private func applyStatus(_ data: Data) {
        guard data.count >= 36 else { return }
        func u8(_ o: Int) -> Int { Int(data[data.startIndex + o]) }
        func le<T: FixedWidthInteger>(_ o: Int, _: T.Type) -> T {
            var v: T = 0
            _ = withUnsafeMutableBytes(of: &v) { dst in
                data.copyBytes(to: dst, from: (data.startIndex + o)..<(data.startIndex + o + MemoryLayout<T>.size))
            }
            return T(littleEndian: v)
        }
        let flags = u8(1)
        var s = DeviceStatus()
        s.sampleRate = Double(le(2, UInt16.self))
        s.samples = Int(le(4, UInt32.self))
        s.capacitySamples = Int(le(8, UInt32.self))
        s.batteryMillivolts = Int(le(12, UInt16.self))
        s.batteryPercent = u8(14)
        s.charging = flags & 0x04 != 0
        s.isLogging = flags & 0x01 != 0
        s.isFull = flags & 0x08 != 0
        s.isErasing = flags & 0x10 != 0
        let epoch = le(16, UInt64.self)
        if epoch > 0 {
            s.lastAnchor = Date(timeIntervalSince1970: Double(epoch) / 1000)
            s.lastAnchorIndex = Int(le(24, UInt32.self))
        }
        if s.sampleRate <= 0 { s.sampleRate = 52 }
        status = s
    }

    /// 吸い出しフレーム: 先頭 4 B が絶対サンプル番号、残りが 12 B/サンプル。
    /// 番号 0xFFFFFFFF だけのフレームが終端。
    private func applyDumpFrame(_ data: Data) {
        guard data.count >= 4 else { return }
        var idx: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &idx) { dst in
            data.copyBytes(to: dst, from: data.startIndex..<(data.startIndex + 4))
        }
        if idx == 0xFFFF_FFFF { finishDump(); return }

        let body = data.dropFirst(4)
        let n = body.count / 12
        guard n > 0, let completion = dumpCompletion else { return }

        let first = Int(idx)
        if first != dumpNextIndex { dumpGap = true }
        guard first + n <= dumpExpected else { return }   // 本体が伸びた: 無視

        body.withUnsafeBytes { src in
            let s = src.bindMemory(to: Int16.self)
            for i in 0..<(n * 6) {
                dumpBuffer[first * 6 + i] = Int16(littleEndian: s[i])
            }
        }
        dumpNextIndex = max(dumpNextIndex, first + n)

        // 進捗の更新は SwiftUI の再描画を呼ぶので、毎フレームは出さない
        let now = Date()
        if now.timeIntervalSince(lastProgressPublish) > 0.2 || dumpNextIndex >= dumpExpected {
            lastProgressPublish = now
            transfer?.received = dumpNextIndex
        }
        _ = completion
    }

    private func finishDump() {
        guard let completion = dumpCompletion else { return }
        dumpCompletion = nil
        if let d = dataChar, let p = peripheral { p.setNotifyValue(false, for: d) }
        transfer = nil
        if dumpGap || dumpNextIndex < dumpExpected {
            dumpBuffer = []
            completion(.failure(BLEError.dumpGap(at: dumpNextIndex)))
            return
        }
        let rec = RawRecording(samples: dumpBuffer, odr: status.sampleRate)
        dumpBuffer = []
        completion(.success(rec))
    }
}

// MARK: - CoreBluetooth

extension BLEManager: CBCentralManagerDelegate, CBPeripheralDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:    scanIfReady()
        case .poweredOff:   connection = .poweredOff
        case .unauthorized: connection = .unauthorized
        case .unsupported:  connection = .unsupported
        default:            connection = .idle
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        deviceName = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        connection = .connecting
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        lastError = error?.localizedDescription ?? "接続できませんでした"
        connection = .scanning
        scanIfReady()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // 吸い出し中に切れたら黙って終わらせない（途中までのデータを本物に見せない）
        if let completion = dumpCompletion {
            dumpCompletion = nil
            dumpBuffer = []
            transfer = nil
            completion(.failure(BLEError.dumpGap(at: dumpNextIndex)))
        }
        self.peripheral = nil
        timeChar = nil; statusChar = nil; dataChar = nil; controlChar = nil
        status = DeviceStatus()
        connection = .scanning
        scanIfReady()                       // 電源が入っていればすぐ繋ぎ直る
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID })
        else { lastError = "本体のサービスが見つかりません"; return }
        peripheral.discoverCharacteristics(
            [Self.timeUUID, Self.statusUUID, Self.dataUUID, Self.controlUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.timeUUID:    timeChar = c
            case Self.statusUUID:  statusChar = c
            case Self.dataUUID:    dataChar = c
            case Self.controlUUID: controlChar = c
            default: break
            }
        }
        guard let s = statusChar else { lastError = "本体の状態を読めません"; return }
        connection = .connected
        peripheral.setNotifyValue(true, for: s)   // 記録量・電池は本体から流れてくる
        peripheral.readValue(for: s)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.statusUUID: applyStatus(data)
        case Self.dataUUID:   applyDumpFrame(data)
        default: break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error { lastError = error.localizedDescription }
    }
}
