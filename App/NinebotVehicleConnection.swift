import Foundation
import Combine
import CoreBluetooth
#if canImport(UIKit)
import UIKit
#endif

/// Manages owner-confirmed Ninebot pairing and the projection navigation session.
@MainActor
final class NinebotVehicleConnection: NSObject, ObservableObject {
    typealias Phase = NinebotPairingPhase

    struct Device: Identifiable, Equatable {
        let id: UUID
        var name: String
        var isConnectable: Bool
        var detail: String
        var rssi: Int?
        var lastSeen: TimeInterval
        var shortID: String { String(id.uuidString.suffix(6)) }
    }

    @Published private(set) var finder = NinebotVehicleFinder()
    @Published private(set) var scanReport = NinebotScanDiagnostics()
    private var scanInventory = NinebotScanDiagnostics()
    private var lastScanReportUptime = -Double.infinity
    var scanDiagnosticsJSON: String { scanInventory.json }

    private func publishScanReport(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if force || now - lastScanReportUptime >= 1 {
            scanReport = scanInventory
            lastScanReportUptime = now
        }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "请扫描并选择车辆。"
    @Published private(set) var devices: [Device] = []
    @Published private(set) var isScanning = false
    @Published private(set) var garage: NinebotVehicleSelection
    @Published private(set) var attemptName: String?
    @Published private(set) var pairedVehicle: NinebotVehicle?
    @Published private(set) var hasPairingAcknowledgement = false
    @Published private(set) var scanWindow: NinebotPairingWindow?
    @Published private(set) var confirmationWindow: NinebotPairingWindow?
    private var lastPairingVehicle: NinebotVehicle?
    private var discoveryOrder: [UUID: Int] = [:]
    private var discoveryLastSeen: [UUID: TimeInterval] = [:]
    private var scanTimeoutTask: DispatchWorkItem?
    private var scanEpoch = UUID()
    @Published private(set) var readyForButtonPress = false
    @Published private(set) var debugLogs: [String] = []
    var canQuickRePair: Bool { canChooseVehicle && garage.selected != nil && finder.stage == .idle }
    var onLog: ((String) -> Void)?
    var onSelectionChanged: (() -> Void)?

    /// Includes the short hotspot bring-up period after the navigation ACK.
    var isPreparingProjection: Bool { purpose == .projection && wantsSession && !disconnecting }

    var canBeginPairing: Bool {
        purpose == .pairing && phase == .needsPairing && peripheral?.state == .connected
    }
    var canScan: Bool { purpose == nil && pendingProjection == nil && peripheral == nil }
    var canChooseVehicle: Bool { canScan && !scanRequested }
    var isPairing: Bool { purpose == .pairing || scanRequested }
    var presentation: NinebotPairingPresentation { .init(phase: phase, isPairing: isPairing, readyForButtonPress: readyForButtonPress) }
    var canRetryPairing: Bool { phase == .failed && canChooseVehicle && lastPairingVehicle != nil }
    var needsBluetoothSettings: Bool { central?.state == .poweredOff || central?.state == .unauthorized }
    var isDisconnecting: Bool { disconnecting }
    var retryTargetName: String? { lastPairingVehicle?.name }

    func canConnect(_ device: Device, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard canScan, finder.stage == .idle || finder.stage == .results,
              let current = devices.first(where: { $0.id == device.id }) else { return false }
        return current.isConnectable && isFresh(current, at: now)
    }

    func isFresh(_ device: Device, at now: TimeInterval) -> Bool {
        guard let lastSeen = discoveryLastSeen[device.id] else { return false }
        return NinebotPairingWindow.isFresh(lastSeen: lastSeen, now: now)
    }

    private enum Purpose { case pairing, projection }

    private struct Outgoing {
        let data: Data
        var offset: Int = 0
    }

    private static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let writeID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let notifyID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let garageKey = "ninebot.vehicle.selection"

    private var central: CBCentralManager!
    private let defaults: UserDefaults
    private let keyStore = NinebotVehicleKeyStore()
    private var purpose: Purpose?
    private var attemptVehicle: NinebotVehicle?
    private var pendingProjection: NinebotVehicle?
    // Retained only for this explicitly authorized vehicle pairing operation.
    // Transport recovery reuses its write-ahead key instead of generating another.
    private var pairingAuthorizedVehicleID: UUID?
    private var pairingReadiness: VehiclePairingReadiness?
    private var peripheralDelegate: SessionPeripheralDelegate?
    private var disconnectFallbackTask: DispatchWorkItem?
    private var reconnectAfterCentralReset = false
    private var wantsSession = false
    private var scanRequested = false
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var scanDetails: [UUID: DiscoveryEvidence] = [:]
    @Published private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var crypto = V2Crypto()
    private var assembler = VehicleBLEFrameAssembler(encrypted: true, maxBufferedBytes: 1024)
    private var authParameter: Data?
    private var serialNumber: Data?
    private var nameBytes = Data()
    private var candidateKeys: [Data] = []
    // Retained across transport attempts so an uncommitted pending key cannot
    // starve the original confirmed key when a wrong key yields only bad MACs.
    private var authenticationAttempts = VehicleAuthenticationAttempts()
    private var currentKey: Data?
    private var authenticated = false
    private var outgoing: [Outgoing] = []
    private var queuedBytes = 0
    private var lastWriteProgress = DispatchTime.now().uptimeNanoseconds
    private var epoch: UInt64 = 0
    private var deadlineTask: DispatchWorkItem?
    private var retryTask: DispatchWorkItem?
    private var reconnectTask: DispatchWorkItem?
    private var writeWatchdog: DispatchWorkItem?
    private var retries = 0
    private var reconnectCount = 0
    private var disconnecting = false
    private var reconnectAfterDisconnect = false
    private var invalidPacketCount = 0
    private var dashboardExitHandled = false
    private var endingAfterExitReply = false
    private var endingAfterStopWrite = false
    private var stopWriteSubmitted = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        garage = defaults.data(forKey: Self.garageKey)
            .flatMap { try? JSONDecoder().decode(NinebotVehicleSelection.self, from: $0) }
            ?? NinebotVehicleSelection()
        super.init()
        if garage.selected != nil { status = "启动投屏时将自动连接车辆。" }
    }

    private func prepareCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    private func logBLE(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        debugLogs.append("\(formatter.string(from: Date())) \(message)")
        if debugLogs.count > 80 { debugLogs.removeFirst(debugLogs.count - 80) }
        onLog?("九号 BLE：" + message)
    }

    func clearDebugLogs() { debugLogs.removeAll() }

    /// Explicit user action. The target UUID remains fixed across bounded retries.
    func rePairSelectedVehicle() {
        guard canQuickRePair, let vehicle = garage.selected else { return }
        stopScan()
        lastPairingVehicle = vehicle
        begin(.pairing, vehicle: vehicle)
        pairingAuthorizedVehicleID = vehicle.id
        logBLE("已请求重新配对所选车辆；等待车机就绪后再按 P 键")
        prepareCentral()
        if central.state == .poweredOn { reconnectVehicle() }
        else { reportBluetoothState() }
    }

    func startScan(preservingFinder: Bool = false) {
        guard canScan else { return }
        if !preservingFinder { finder.cancel() }
        scanRequested = true
        prepareCentral()
        guard central.state == .poweredOn else {
            reportBluetoothState()
            return
        }
        central.stopScan()
        scanDetails.removeAll()
        scanInventory = NinebotScanDiagnostics()
        scanReport = scanInventory
        lastScanReportUptime = -Double.infinity
        devices.removeAll()
        peripherals.removeAll()
        discoveryOrder.removeAll()
        discoveryLastSeen.removeAll()
        pairedVehicle = nil
        lastPairingVehicle = nil
        scanWindow = NinebotPairingWindow(startedAt: ProcessInfo.processInfo.systemUptime, duration: 30)
        let scanID = UUID(); scanEpoch = scanID
        scanTimeoutTask?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.scanEpoch == scanID, self.isScanning else { return }
            let ids = Set(self.devices.filter { $0.isConnectable && self.isFresh($0, at: ProcessInfo.processInfo.systemUptime) }.map(\.id))
            self.finder.completeRound(ids: ids)
            self.stopScan()
            self.onLog?("车辆扫描摘要：" + self.scanReport.summary)
            self.transition(.idle, self.devices.isEmpty
                ? (self.scanReport.packetCount == 0
                    ? "本轮没有收到蓝牙广播。请在前台扫描，确认蓝牙权限、给车辆通电并靠近后重试。"
                    : "已收到附近蓝牙广播，但尚未识别出九号车辆。请查看附近其他蓝牙并复制扫描诊断。")
                : "扫描已结束，可选择仍在附近的车辆；广播过期后请重新扫描。")
        }
        scanTimeoutTask = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        // Some supported vehicles omit the UART service from their advertisement.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        // These devices may be connected by another app and no longer advertise.
        // Listing them does not establish pairing eligibility or take ownership.
        for item in central.retrieveConnectedPeripherals(withServices: [Self.service]) {
            scanInventory.observe(id: item.identifier, name: item.name, rssi: nil,
                services: [Self.service.uuidString], manufacturerData: nil,
                evidence: DiscoveryEvidence(), now: ProcessInfo.processInfo.systemUptime,
                systemConnected: true)
        }
        publishScanReport(force: true)
        transition(.scanning, "正在扫描九号车辆…")
    }

    func beginFindingVehicle() {
        guard canScan else { return }
        stopScan()
        finder.begin()
    }

    func scanFinderRound() {
        guard canChooseVehicle, finder.startRound() else { return }
        startScan(preservingFinder: true)
    }

    func cancelFindingVehicle() {
        guard finder.stage != .idle else { return }
        stopScan(); finder.cancel()
    }

    func renameVehicle(_ id: UUID, to name: String) {
        guard canChooseVehicle else { return }
        updateGarage { $0.rename(id, to: name) }
        onSelectionChanged?()
    }

    var pairingTarget: NinebotPairingTarget? {
        guard canBeginPairing, let vehicle = attemptVehicle else { return nil }
        return NinebotPairingTarget(id: vehicle.id, bluetoothName: vehicle.name, epoch: epoch)
    }

    func stopScan() {
        publishScanReport(force: true)
        scanEpoch = UUID()
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        scanWindow = nil
        scanRequested = false
        if central?.isScanning == true { central.stopScan() }
        isScanning = false
        if phase == .scanning { transition(.idle, "扫描已停止。") }
    }

    func connectForPairing(_ device: Device) {
        guard canScan else { return }
        guard canConnect(device), central?.state == .poweredOn, let evidence = scanDetails[device.id], evidence.isEligible, evidence.localName == device.name,
              let advertisement = evidence.advertisement, let found = peripherals[device.id] else {
            transition(.failed, "尚未收到可连接的车辆广播，请重新扫描。")
            return
        }
        let vehicle = NinebotVehicle(id: device.id, name: evidence.localName,
                                     protocolVersion: advertisement.protocolVersion,
                                     serialLength: advertisement.serialNumberLength)
        stopScan()
        finder.cancel()
        lastPairingVehicle = vehicle
        begin(.pairing, vehicle: vehicle)
        connectPeripheral(found)
    }

    func checkPairedVehicle(_ id: UUID) {
        guard canChooseVehicle, let vehicle = garage.vehicles.first(where: { $0.id == id }) else { return }
        lastPairingVehicle = vehicle
        begin(.pairing, vehicle: vehicle)
        prepareCentral()
        if central.state == .poweredOn { reconnectVehicle() }
        else { reportBluetoothState() }
    }

    func retryPairing() {
        guard canRetryPairing, let vehicle = lastPairingVehicle else { return }
        begin(.pairing, vehicle: vehicle)
        prepareCentral()
        if central.state == .poweredOn { reconnectVehicle() }
        else { reportBluetoothState() }
    }

    private func begin(_ purpose: Purpose, vehicle: NinebotVehicle) {
        finder.cancel()
        self.purpose = purpose
        attemptVehicle = vehicle
        attemptName = vehicle.title
        hasPairingAcknowledgement = false
        pairedVehicle = nil
        confirmationWindow = nil
        wantsSession = true
        reconnectCount = 0
        authenticationAttempts = VehicleAuthenticationAttempts()
        pairingAuthorizedVehicleID = nil
    }

    /// Explicit UI action only. Neither state restoration nor authentication failure
    /// is permitted to call SET_PWD or generate a replacement key automatically.
    func beginPairing(confirmedTarget: NinebotPairingTarget) {
        guard pairingTarget == confirmedTarget, canBeginPairing, let selection = attemptVehicle else { return }
        pairingAuthorizedVehicleID = selection.id
        startAuthorizedPairing()
    }

    private func startAuthorizedPairing() {
        guard canBeginPairing, let selection = attemptVehicle,
              pairingAuthorizedVehicleID == selection.id, let authParameter else { return }
        do {
            let key = try keyStore.prepareCandidate(for: selection.id)
            authenticationAttempts = VehicleAuthenticationAttempts()
            candidateKeys.removeAll()
            currentKey = key
            wantsSession = true
            try crypto.setKey(nameBytes, authParameter)
            pairingReadiness = VehiclePairingReadiness(startedAt: ProcessInfo.processInfo.systemUptime)
            readyForButtonPress = false
            confirmationWindow = nil
            transition(.pairing, CWL("正在等待车机进入配对状态（约 5–8 秒），请先不要按 P 键…"))
            try send(command: 0x5c, destination: 0x04, payload: key)
            pairingReadiness?.didSendRequest()
            schedulePairingRetry()
        } catch {
            fail("无法开始配对：\(error.localizedDescription)", retryable: false)
        }
    }

    func selectVehicle(_ id: UUID?) {
        guard canChooseVehicle else { return }
        updateGarage { $0.select(id) }
        onSelectionChanged?()
        transition(.idle, garage.selected == nil ? "已关闭自动连接。" : "启动投屏时将自动连接车辆。")
    }

    func restoreSelection(_ id: UUID?) {
        guard canChooseVehicle else { return }
        updateGarage { $0.restore(id) }
        transition(.idle, garage.selected == nil ? "未绑定可用的九号车辆，可手动开启投屏或重新选择配对车辆。" : "启动投屏时将自动连接车辆。")
    }

    func forgetVehicle(_ id: UUID) {
        guard canChooseVehicle, garage.vehicles.contains(where: { $0.id == id }) else { return }
        do {
            try keyStore.remove(for: id)
            updateGarage { $0.remove(id) }
            onSelectionChanged?()
            transition(.idle, "已删除本机配对记录。")
        } catch {
            transition(.failed, "删除配对记录失败（\(error.localizedDescription)）。")
        }
    }

    private func updateGarage(_ update: (inout NinebotVehicleSelection) -> Void) {
        var changed = garage
        update(&changed)
        garage = changed
        defaults.set(try? JSONEncoder().encode(changed), forKey: Self.garageKey)
    }

    func cancelPairing() {
        finder.cancel()
        stopScan()
        guard purpose == .pairing else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        if disconnecting { finishAttempt() }
        else { finishDisconnect(message: "已结束车辆配对连接。") }
    }

    func startProjection() {
        guard let vehicle = garage.selected, pendingProjection == nil else { return }
        if purpose == .projection && wantsSession { return }
        pendingProjection = vehicle
        cancelPairing()
        startPendingProjection()
    }

    private func startPendingProjection() {
        guard peripheral == nil, let vehicle = pendingProjection else { return }
        pendingProjection = nil
        begin(.projection, vehicle: vehicle)
        prepareCentral()
        if central.state == .poweredOn { reconnectVehicle() }
        else { reportBluetoothState() }
    }

    func stopProjection() {
        pendingProjection = nil
        guard purpose == .projection, wantsSession else { return }
        wantsSession = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAfterDisconnect = false
        retryTask?.cancel()
        deadlineTask?.cancel()
        if disconnecting {
            finishAttempt()
            return
        }
        guard let peripheral, peripheral.state == .connected, authenticated,
              phase == .starting || phase == .active else {
            finishDisconnect(message: "车辆导航连接已停止。")
            return
        }
        // Complete a partially submitted frame before sending STOP on the byte stream.
        retainOnlyPartialWrite()
        transition(.stopping, "正在通知仪表停止导航…")
        endingAfterStopWrite = true
        stopWriteSubmitted = false
        armDeadline(seconds: 2) { connection in
            connection.finishDisconnect(message: connection.stopWriteSubmitted
                ? "停止指令已发送，会话已断开。" : "会话已断开；停止指令未完整发送。")
        }
        do {
            try send(command: 0x71, destination: 0x23, payload: Data([0]))
        } catch { finishDisconnect(message: "已断开；停止指令未能发送。") }
    }

    private func transition(_ next: Phase, _ message: String) {
        let changed = phase != next || status != message
        phase = next
        status = message
        if changed { logBLE(message) }
    }

    private func upsert(_ device: Device) {
        discoveryLastSeen[device.id] = device.lastSeen
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            let previous = devices[index]
            let sameSignal = previous.rssi == device.rssi || previous.rssi.flatMap { old in
                device.rssi.map { abs(old - $0) < 5 }
            } == true
            // Keep actual freshness on every packet without rebuilding rows for each duplicate.
            if previous.name == device.name, previous.isConnectable == device.isConnectable,
               previous.detail == device.detail, sameSignal, device.lastSeen - previous.lastSeen < 1 { return }
            devices[index] = device
        }
        else if devices.count < 100 {
            discoveryOrder[device.id] = discoveryOrder.count
            devices.append(device)
        }
        let known = Set(garage.vehicles.map(\.id))
        devices.sort {
            if known.contains($0.id) != known.contains($1.id) { return known.contains($0.id) }
            return (discoveryOrder[$0.id] ?? 100) < (discoveryOrder[$1.id] ?? 100)
        }
    }

    private func connectPeripheral(_ item: CBPeripheral) {
        guard central.state == .poweredOn, wantsSession, let selection = attemptVehicle,
              item.identifier == selection.id, Advertisement.canAttemptLocalAuthentication(version: selection.protocolVersion) else { return }
        resetAttempt()
        peripheral = item
        peripherals[item.identifier] = item
        let delegate = SessionPeripheralDelegate(owner: self, epoch: epoch)
        peripheralDelegate = delegate
        item.delegate = delegate
        nameBytes = Data(selection.name.utf8.suffix(16))
        transition(.connecting, "正在连接 \(selection.name)…")
        if item.state == .disconnecting {
            disconnecting = true
            reconnectAfterDisconnect = true
            transition(.reconnecting, "等待上一条蓝牙连接完全断开后再恢复会话。")
            scheduleDisconnectFallback()
        } else {
            // A system-connected peripheral may belong only to another app.
            // Claim it through this central before using its GATT services.
            central.connect(item)
            armDeadline(seconds: 15) { $0.fail("蓝牙连接超时。", retryable: true) }
        }
    }

    private func discover(_ item: CBPeripheral) {
        guard isCurrent(item), !disconnecting, wantsSession else { return }
        deadlineTask?.cancel()
        logBLE("蓝牙已连接，正在发现九号指令通道")
        transition(.discovering, "正在查找指令服务和通知通道…")
        item.discoverServices([Self.service])
        armDeadline(seconds: 12) { $0.fail("蓝牙服务发现或通知启用超时。", retryable: true) }
    }

    private func beginPrecommunication() {
        guard wantsSession, !disconnecting, let selection = attemptVehicle else { return }
        do {
            deadlineTask?.cancel()
            assembler.reset()
            crypto = V2Crypto()
            crypto.resetSerial()
            try crypto.setKey(nameBytes, nil)
            // Read before proceeding: a locked/unavailable Keychain must not look
            // like an unpaired vehicle and trigger accidental key replacement.
            let record = try keyStore.load(for: selection.id)
            candidateKeys = pairingAuthorizedVehicleID == selection.id ? []
                : authenticationAttempts.remaining(from: record.authenticationCandidates)
            logBLE("开始 0x5B；已存确认密钥=\(record.confirmedKey != nil)，待确认密钥=\(record.pendingKey != nil)")
            retries = 0
            transition(.preparing, "正在读取车辆认证参数…")
            try send(command: 0x5b, destination: 0x04)
            scheduleHandshakeRetry(for: .preparing)
        } catch { fail("读取认证参数失败：\(error.localizedDescription)", retryable: false) }
    }

    private func beginAuthentication(with key: Data) {
        guard let authParameter, let serialNumber else { return }
        do {
            retryTask?.cancel()
            retries = 0
            currentKey = key
            try crypto.setKey(key, authParameter)
            transition(.authenticating, "正在用本机保存的密钥认证…")
            try send(command: 0x5d, destination: 0x04, payload: serialNumber)
            scheduleHandshakeRetry(for: .authenticating)
        } catch { fail("认证指令发送失败：\(error.localizedDescription)", retryable: false) }
    }

    private func requestNavigation() {
        do {
            retries = 0
            transition(.starting, "认证成功，正在等待仪表确认开启导航…")
            try send(command: 0x71, destination: 0x23, payload: Data([1]))
            scheduleHandshakeRetry(for: .starting)
        } catch { fail("开启导航失败：\(error.localizedDescription)", retryable: true) }
    }

    private func handle(_ frame: VehicleBLEFrame) {
        logBLE(String(format: "RX src=%02X dst=%02X cmd=%02X idx=%02X len=%d", Int(frame.src),
                      Int(frame.dst), Int(frame.command), Int(frame.index), frame.payload.count))
        guard frame.dst == 0x3e, !disconnecting else { return }
        if frame.src == 0x23, frame.command == 0x71 {
            if frame.index == 0xff, frame.payload == Data([0]), authenticated, purpose == .projection {
                handleDashboardExit()
            } else if frame.index == 0x30, authenticated, wantsSession, purpose == .projection {
                // An asynchronous inquiry, never a start ACK and never a timer.
                do {
                    try send(command: 0x71, destination: 0x23, index: 0x30, payload: Data([1]))
                } catch { fail("回复仪表导航状态失败。", retryable: true) }
            } else if VehicleNavigationPolicy.isNavigationStartAcknowledgement(frame) {
                if phase == .starting, authenticated, wantsSession {
                    retryTask?.cancel()
                    reconnectCount = 0
                    transition(.active, "仪表已确认导航开启。")
                }
                // STOP has the same empty ACK as START. An older START ACK can
                // arrive here, so it must never clear a still-queued STOP or be
                // described as a confirmed stop. STOP uses a bounded flush below.
            }
            return
        }
        guard frame.src == 0x04 else { return }
        do {
            switch (phase, frame.command) {
            case (.preparing, 0x5b):
                guard let serialLength = VehiclePrecommunication.serialLength(
                    payloadCount: frame.payload.count, advertisedLength: attemptVehicle?.serialLength) else {
                    fail("车辆返回的认证信息长度无效。", retryable: false)
                    return
                }
                retryTask?.cancel()
                authParameter = Data(frame.payload.prefix(16))
                serialNumber = Data(frame.payload.dropFirst(16).prefix(serialLength))
                try crypto.setAuthParam(authParameter!)
                crypto.startSerial()
                if frame.index != 0, !candidateKeys.isEmpty {
                    beginAuthentication(with: candidateKeys.removeFirst())
                } else {
                    guard purpose == .pairing else {
                        fail("此车需要重新配对。请停止投屏，再打开「车辆配对」。", retryable: false)
                        return
                    }
                    if pairingAuthorizedVehicleID == attemptVehicle?.id {
                        transition(.needsPairing, CWL("正在下发配对请求…"))
                        startAuthorizedPairing()
                    } else {
                        wantsSession = false
                        transition(.needsPairing, "点击「发送配对请求」，等提示「车机已就绪」后再按 P 键。")
                    }
                }
            case (.pairing, 0x5c):
                if frame.index == 1, let key = currentKey, let selection = attemptVehicle {
                    retryTask?.cancel()
                    confirmationWindow = nil
                    readyForButtonPress = false
                    hasPairingAcknowledgement = true
                    try keyStore.acknowledgeWrite(key, for: selection.id)
                    candidateKeys.removeAll()
                    beginAuthentication(with: key)
                } else if pairingReadiness?.acceptReady(frame, at: ProcessInfo.processInfo.systemUptime) == true {
                    confirmationWindow = pairingReadiness?.confirmationWindow
                    readyForButtonPress = true
                    transition(.pairing, CWL("车机已就绪！请现在短按一下车上的 P 键确认配对。"))
                    #if canImport(UIKit)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    #endif
                }
                // Repeated readiness replies never extend the physical confirmation window.
            case (.authenticating, 0x5d):
                retryTask?.cancel()
                if frame.index == 1, let key = currentKey, let selection = attemptVehicle {
                    try keyStore.confirmAuthentication(key, for: selection.id)
                    authenticated = true
                    authenticationAttempts = VehicleAuthenticationAttempts()
                    candidateKeys.removeAll()
                    if purpose == .pairing {
                        updateGarage { $0.save(selection) }
                        pairedVehicle = selection
                        finishDisconnect(message: "车辆身份认证已通过并保存。可选择「用于当前车辆」，也可保留原来的车辆选择。", finalPhase: .paired)
                    } else if purpose == .projection && wantsSession {
                        requestNavigation()
                    }
                } else {
                    authenticationFailed("车辆未接受保存的密钥。")
                }
            default: break
            }
        } catch { fail("认证处理失败：\(error.localizedDescription)", retryable: false) }
    }

    private func send(command: UInt8, destination: UInt8, index: UInt8 = 0, payload: Data = Data()) throws {
        guard let peripheral, peripheral.state == .connected, writeCharacteristic != nil else {
            throw SessionError.message("蓝牙发送通道尚未就绪。")
        }
        let frame = VehicleBLEFrame(src: 0x3e, dst: destination, command: command, index: index, payload: payload)
        guard VehicleNavigationPolicy.permits(frame, pairing: purpose == .pairing && phase == .pairing,
                                             authenticated: authenticated,
                                             wantsNavigation: purpose == .projection && wantsSession) else {
            throw SessionError.message("当前车辆会话不允许发送该命令。")
        }
        let plain = try frame.encode()
        let wire = try crypto.encrypt(plain)
        logBLE(String(format: "TX dst=%02X cmd=%02X idx=%02X len=%d", Int(destination),
                      Int(command), Int(index), payload.count))
        guard outgoing.count < 16, queuedBytes + wire.count <= 4096 else {
            throw SessionError.message("蓝牙发送队列拥塞。")
        }
        let wasEmpty = outgoing.isEmpty
        outgoing.append(Outgoing(data: wire))
        queuedBytes += wire.count
        if wasEmpty { lastWriteProgress = DispatchTime.now().uptimeNanoseconds }
        pumpWrites()
    }

    private func pumpWrites() {
        guard let peripheral, peripheral.state == .connected, let characteristic = writeCharacteristic,
              !disconnecting else { return }
        let maximum = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard maximum > 0 else { fail("蓝牙协商的写入长度无效。", retryable: false); return }
        while peripheral.canSendWriteWithoutResponse && !outgoing.isEmpty {
            var first = outgoing[0]
            let end = min(first.data.count, first.offset + maximum)
            let chunk = first.data.subdata(in: first.offset..<end)
            peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
            first.offset = end
            queuedBytes -= chunk.count
            lastWriteProgress = DispatchTime.now().uptimeNanoseconds
            if first.offset == first.data.count { outgoing.removeFirst() }
            else { outgoing[0] = first }
        }
        writeWatchdog?.cancel()
        writeWatchdog = nil
        if !outgoing.isEmpty { scheduleWriteWatchdog() }
        else if endingAfterExitReply {
            // writeNR has no protocol ACK. Give the controller a bounded flush
            // window, then release BLE without ever setting navigation to 1 again.
            endingAfterExitReply = false
            armDeadline(seconds: 0.5) { $0.finishDisconnect(message: "仪表已主动结束导航，会话已停止。") }
        } else if endingAfterStopWrite {
            endingAfterStopWrite = false
            stopWriteSubmitted = true
            armDeadline(seconds: 0.5) { $0.finishDisconnect(message: "停止指令已发送，会话已断开。") }
        }
    }

    private func retainOnlyPartialWrite() {
        if let first = outgoing.first, first.offset > 0 {
            outgoing = [first]
            queuedBytes = first.data.count - first.offset
        } else {
            outgoing.removeAll()
            queuedBytes = 0
        }
    }

    private func handleDashboardExit() {
        // Firmware sends this report three times. Clearing intent immediately and
        // handling it once also prevents late start ACKs or reconnects reviving it.
        guard !dashboardExitHandled else { return }
        dashboardExitHandled = true
        wantsSession = false
        reconnectAfterDisconnect = false
        reconnectTask?.cancel()
        retryTask?.cancel()
        retainOnlyPartialWrite()
        transition(.stopping, "仪表已主动结束导航，正在确认退出；不会自动重新开启。")
        endingAfterExitReply = true
        armDeadline(seconds: 2) { $0.finishDisconnect(message: "仪表已主动结束导航，会话已停止。") }
        do {
            // M5 setNaviExit is writeNR, command 71/index FF with absent data.
            try send(command: 0x71, destination: 0x23, index: 0xff)
        } catch { finishDisconnect(message: "仪表已主动结束导航，会话已停止。") }
    }

    private func scheduleWriteWatchdog() {
        let captured = epoch
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.epoch == captured, !self.outgoing.isEmpty else { return }
            if DispatchTime.now().uptimeNanoseconds - self.lastWriteProgress >= 8_000_000_000 {
                self.fail("蓝牙写入长时间受阻，将重新建立会话。", retryable: true)
            } else { self.pumpWrites() }
        }
        writeWatchdog = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: task)
    }

    private func scheduleHandshakeRetry(for expected: Phase) {
        retryTask?.cancel()
        let captured = epoch
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.epoch == captured, self.phase == expected,
                  self.wantsSession, !self.disconnecting else { return }
            guard self.outgoing.isEmpty else { self.scheduleHandshakeRetry(for: expected); return }
            guard self.retries < (expected == .starting ? 4 : 2) else {
                if expected == .authenticating { self.authenticationFailed("车辆密钥认证超时。") }
                else { self.fail("\(expected == .starting ? "仪表开启导航确认" : "读取车辆认证参数")超时。", retryable: true) }
                return
            }
            self.retries += 1
            do {
                switch expected {
                case .preparing: try self.send(command: 0x5b, destination: 0x04)
                case .authenticating:
                    guard let serial = self.serialNumber else { return }
                    try self.send(command: 0x5d, destination: 0x04, payload: serial)
                case .starting: try self.send(command: 0x71, destination: 0x23, payload: Data([1]))
                default: return
                }
                self.scheduleHandshakeRetry(for: expected)
            } catch { self.fail("蓝牙重试发送失败。", retryable: true) }
        }
        retryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (expected == .starting ? 1 : 3), execute: task)
    }

    private func schedulePairingRetry() {
        retryTask?.cancel()
        let captured = epoch
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.epoch == captured, self.phase == .pairing, self.wantsSession else { return }
            guard !self.disconnecting, let readiness = self.pairingReadiness else { return }
            if readiness.needsReadinessRecovery || (readiness.readyAt == nil && readiness.hasExpired(at: ProcessInfo.processInfo.systemUptime)) {
                self.fail("车机尚未进入配对状态，正在恢复本次配对；请先不要按 P 键。", retryable: true)
                return
            }
            if readiness.hasExpired(at: ProcessInfo.processInfo.systemUptime) {
                self.readyForButtonPress = false
                self.currentKey = nil
                self.confirmationWindow = nil
                self.wantsSession = false
                self.pairingAuthorizedVehicleID = nil
                self.transition(.needsPairing, "等待 P 键确认超时。可重新发送配对请求，等提示「车机已就绪」后再按 P 键；待确认密钥已保留。")
                return
            }
            do {
                if self.outgoing.isEmpty, let key = self.currentKey {
                    try self.send(command: 0x5c, destination: 0x04, payload: key)
                    self.pairingReadiness?.didSendRequest()
                }
                self.schedulePairingRetry()
            } catch { self.fail("配对发送失败，待确认密钥仍已保存。", retryable: false) }
        }
        retryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: task)
    }

    private func armDeadline(seconds: Double, action: @escaping (NinebotVehicleConnection) -> Void) {
        deadlineTask?.cancel()
        let captured = epoch
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.epoch == captured else { return }
            action(self)
        }
        deadlineTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    private func resetAttempt() {
        epoch &+= 1
        readyForButtonPress = false
        pairingReadiness = nil
        peripheralDelegate = nil
        disconnectFallbackTask?.cancel(); disconnectFallbackTask = nil
        confirmationWindow = nil
        deadlineTask?.cancel()
        retryTask?.cancel()
        writeWatchdog?.cancel()
        deadlineTask = nil
        retryTask = nil
        writeWatchdog = nil
        outgoing.removeAll()
        queuedBytes = 0
        assembler.reset()
        crypto = V2Crypto()
        authenticated = false
        authParameter = nil
        serialNumber = nil
        currentKey = nil
        candidateKeys.removeAll()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        invalidPacketCount = 0
        dashboardExitHandled = false
        endingAfterExitReply = false
        endingAfterStopWrite = false
        stopWriteSubmitted = false
        disconnecting = false
    }

    /// A missing disconnect callback must not let old delegate events act on a new
    /// session. Replace the central and bind peripheral callbacks to their epoch.
    private func scheduleDisconnectFallback() {
        disconnectFallbackTask?.cancel()
        let captured = epoch
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.epoch == captured, self.disconnecting else { return }
            let retry = self.wantsSession && self.reconnectAfterDisconnect
            self.logBLE("断开回调超时，重建本机蓝牙管理器；保留待确认密钥")
            if let item = self.peripheral {
                item.delegate = nil
                self.central.cancelPeripheralConnection(item)
            }
            self.central.delegate = nil
            self.central = nil
            self.peripheral = nil
            self.peripherals.removeAll()
            self.resetAttempt()
            self.reconnectAfterDisconnect = false
            if retry {
                // Wait for the new central's state callback before reconnecting.
                self.reconnectAfterCentralReset = true
                self.prepareCentral()
            } else {
                if self.purpose != nil { self.finishAttempt() }
                self.startPendingProjection()
            }
        }
        disconnectFallbackTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: task)
    }

    private func authenticationFailed(_ reason: String) {
        if let currentKey { authenticationAttempts.reject(currentKey) }
        if !authenticationAttempts.remaining(from: candidateKeys).isEmpty {
            fail(reason + " 将重新握手尝试另一份已保存密钥。", retryable: true)
        } else {
            fail(reason + " 已停止自动重试。可在「车辆配对」重新扫描，或删除旧记录后重新配对。", retryable: false)
        }
    }

    private func fail(_ message: String, retryable: Bool) {
        reconnectTask?.cancel()
        reconnectTask = nil
        let shouldReconnect = retryable && wantsSession && reconnectCount < 5
        transition(shouldReconnect ? .reconnecting : .failed, message)
        if !shouldReconnect { finishAttempt() }
        resetAttempt()
        reconnectAfterDisconnect = shouldReconnect
        if let peripheral, peripheral.state != .disconnected {
            disconnecting = true
            central.cancelPeripheralConnection(peripheral)
            scheduleDisconnectFallback()
            // Never start another attempt on the same CBPeripheral until its old
            // connection has actually ended: delegates do not carry our epoch.
        } else {
            peripheral = nil
            if shouldReconnect { scheduleReconnect() }
            else { startPendingProjection() }
        }
    }

    private func finishDisconnect(message: String, finalPhase: Phase = .idle) {
        finishAttempt()
        resetAttempt()
        reconnectAfterDisconnect = false
        transition(finalPhase, message)
        if let peripheral, peripheral.state != .disconnected {
            disconnecting = true
            central.cancelPeripheralConnection(peripheral)
            scheduleDisconnectFallback()
        } else {
            peripheral = nil
            startPendingProjection()
        }
    }

    private func finishAttempt() {
        wantsSession = false
        purpose = nil
        attemptVehicle = nil
        attemptName = nil
        pairingAuthorizedVehicleID = nil
        reconnectAfterCentralReset = false
    }

    private func scheduleReconnect() {
        guard wantsSession, central.state == .poweredOn, !disconnecting else { return }
        guard reconnectCount < 5 else {
            finishAttempt()
            transition(.failed, "连续重连失败。请重新发起连接。")
            return
        }
        reconnectTask?.cancel()
        reconnectCount += 1
        let delay = min(20.0, pow(2.0, Double(reconnectCount)))
        transition(.reconnecting, pairingAuthorizedVehicleID == attemptVehicle?.id
            ? "正在恢复本次配对，\(Int(delay)) 秒后重连（\(reconnectCount)/5）；请等待车机就绪提示。"
            : "连接中断，\(Int(delay)) 秒后重连（\(reconnectCount)/5）；不会自动重新配对。")
        let captured = epoch
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.epoch == captured, self.wantsSession else { return }
            self.reconnectVehicle()
        }
        reconnectTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func reconnectVehicle() {
        guard central.state == .poweredOn, let selection = attemptVehicle,
              Advertisement.canAttemptLocalAuthentication(version: selection.protocolVersion), wantsSession, peripheral == nil else { return }
        if let item = peripherals[selection.id] ?? central.retrievePeripherals(withIdentifiers: [selection.id]).first {
            connectPeripheral(item)
        } else {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            isScanning = true
            transition(.scanning, "正在查找已保存车辆，请保持车辆通电并结束其他 App 的蓝牙连接。")
            armDeadline(seconds: 15) { connection in
                connection.central.stopScan()
                connection.isScanning = false
                connection.fail("未找到已保存车辆，请重新扫描核对车辆。", retryable: false)
            }
        }
    }

    private func isCurrent(_ item: CBPeripheral) -> Bool { peripheral === item }

    private func reportBluetoothState() {
        switch central.state {
        case .poweredOff: transition(.unavailable, "蓝牙已关闭，请在系统设置开启。")
        case .unauthorized: transition(.unavailable, "未获蓝牙权限，请在系统设置允许此 App 使用蓝牙。")
        case .unsupported: transition(.unavailable, "此设备不支持低功耗蓝牙。")
        case .resetting: transition(.unavailable, "系统蓝牙正在重置，等待恢复。")
        case .unknown: transition(.unavailable, "正在等待系统蓝牙就绪。")
        case .poweredOn: break
        @unknown default: transition(.unavailable, "系统蓝牙暂不可用。")
        }
    }

    @MainActor
    private final class SessionPeripheralDelegate: NSObject, @preconcurrency CBPeripheralDelegate {
        weak var owner: NinebotVehicleConnection?
        let epoch: UInt64
        init(owner: NinebotVehicleConnection, epoch: UInt64) { self.owner = owner; self.epoch = epoch }
        private func current(_ item: CBPeripheral) -> NinebotVehicleConnection? {
            guard let owner, owner.epoch == epoch, owner.isCurrent(item) else { return nil }
            return owner
        }
        func peripheral(_ item: CBPeripheral, didDiscoverServices error: Error?) {
            current(item)?.peripheral(item, didDiscoverServices: error)
        }
        func peripheral(_ item: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
            current(item)?.peripheral(item, didDiscoverCharacteristicsFor: service, error: error)
        }
        func peripheral(_ item: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
            current(item)?.peripheral(item, didUpdateNotificationStateFor: characteristic, error: error)
        }
        func peripheral(_ item: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
            current(item)?.peripheral(item, didUpdateValueFor: characteristic, error: error)
        }
        func peripheralIsReady(toSendWriteWithoutResponse item: CBPeripheral) {
            current(item)?.peripheralIsReady(toSendWriteWithoutResponse: item)
        }
        func peripheral(_ item: CBPeripheral, didModifyServices services: [CBService]) {
            current(item)?.peripheral(item, didModifyServices: services)
        }
    }

    private enum SessionError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}

extension NinebotVehicleConnection: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        guard central.state == .poweredOn else {
            if central.state != .unknown, (finder.stage == .scanningOff || finder.stage == .scanningOn) {
                finder.cancel()
                scanRequested = false
            }
            isScanning = false
            scanTimeoutTask?.cancel(); scanTimeoutTask = nil
            scanWindow = nil
            scanEpoch = UUID()
            reconnectTask?.cancel()
            resetAttempt()
            peripheral = nil
            if (purpose == .pairing && !wantsSession) || phase == .stopping { finishAttempt() }
            reportBluetoothState()
            return
        }
        if scanRequested { startScan(preservingFinder: true) }
        else if wantsSession, peripheral == nil {
            if reconnectAfterCentralReset {
                reconnectAfterCentralReset = false
                scheduleReconnect()
            } else { reconnectVehicle() }
        }
        else if pendingProjection != nil { startPendingProjection() }
        else if phase == .unavailable { transition(.idle, "蓝牙已就绪。") }
    }

    func centralManager(_ central: CBCentralManager, didDiscover item: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard central === self.central, isScanning else { return }
        if wantsSession, let target = attemptVehicle, target.id == item.identifier {
            central.stopScan()
            isScanning = false
            deadlineTask?.cancel()
            connectPeripheral(item)
            return
        }
        guard scanRequested else { return }
        var evidence = scanDetails[item.identifier] ?? DiscoveryEvidence()
        let identified = evidence.merge(
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
            localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            isConnectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        )
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflowServices = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let services = (advertisedServices + overflowServices + Array(serviceData.keys)).map(\.uuidString)
        scanInventory.observe(id: item.identifier,
            name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? item.name,
            rssi: rssi.intValue, services: services,
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
            evidence: evidence, now: ProcessInfo.processInfo.systemUptime)
        publishScanReport()
        guard identified, let advertisement = evidence.advertisement else {
            // Retain bounded name-first/connectability-first packets, without
            // displaying an unverified peripheral as supported or selectable.
            guard !evidence.localName.isEmpty || evidence.hasConnectableAdvertisement,
                  scanDetails[item.identifier] != nil || scanDetails.count < 100 else { return }
            scanDetails[item.identifier] = evidence
            return
        }
        if scanDetails[item.identifier] == nil && scanDetails.count >= 100 {
            guard let unverified = scanDetails.first(where: { $0.value.advertisement == nil })?.key else { return }
            scanDetails.removeValue(forKey: unverified)
        }
        if peripherals[item.identifier] == nil && peripherals.count >= 100 {
            guard let unverified = peripherals.keys.first(where: {
                $0 != peripheral?.identifier && scanDetails[$0]?.advertisement == nil
            }) else { return }
            peripherals.removeValue(forKey: unverified)
            devices.removeAll { $0.id == unverified }
            discoveryLastSeen.removeValue(forKey: unverified)
        }
        peripherals[item.identifier] = item
        scanDetails[item.identifier] = evidence
        let detail: String
        if !advertisement.canAttemptLocalAuthentication { detail = "尚未实现广播版本 v\(advertisement.protocolVersion) 的握手。" }
        else if evidence.localName.isEmpty { detail = "已识别，等待设备广播名称。" }
        else if !evidence.hasConnectableAdvertisement { detail = "已识别，等待可连接的广播。" }
        else { detail = "已识别，可连接（广播 v\(advertisement.protocolVersion)）。" }
        let displayName = evidence.localName.isEmpty ? (item.name ?? "未命名设备") : evidence.localName
        upsert(Device(id: item.identifier, name: displayName,
                      isConnectable: evidence.isEligible, detail: detail,
                      rssi: (-127 ... -1).contains(rssi.intValue) ? rssi.intValue : nil,
                      lastSeen: ProcessInfo.processInfo.systemUptime))
    }

    func centralManager(_ central: CBCentralManager, didConnect item: CBPeripheral) {
        guard central === self.central else { return }
        guard isCurrent(item), !disconnecting, wantsSession else {
            central.cancelPeripheralConnection(item)
            return
        }
        discover(item)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect item: CBPeripheral, error: Error?) {
        guard central === self.central, isCurrent(item) else { return }
        resetAttempt()
        peripheral = nil
        if wantsSession { scheduleReconnect() }
        else if purpose != nil { finishDisconnect(message: "车辆蓝牙连接已断开。") }
        else { startPendingProjection() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral item: CBPeripheral, error: Error?) {
        guard central === self.central, isCurrent(item) else { return }
        if !disconnecting && phase == .authenticating {
            authenticationFailed("认证期间连接中断。")
            return
        }
        if !disconnecting && phase == .pairing {
            fail("配对连接已中断，已停止自动重试；待确认密钥已保留。", retryable: false)
            return
        }
        let retry = wantsSession && (reconnectAfterDisconnect || phase != .stopping)
        resetAttempt()
        peripheral = nil
        reconnectAfterDisconnect = false
        if retry { scheduleReconnect() }
        else if purpose != nil { finishDisconnect(message: "车辆蓝牙连接已断开。") }
        else { startPendingProjection() }
    }
}

extension NinebotVehicleConnection: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ item: CBPeripheral, didDiscoverServices error: Error?) {
        guard isCurrent(item), !disconnecting, phase == .discovering else { return }
        guard error == nil, let service = item.services?.first(where: { $0.uuid == Self.service }) else {
            fail("未发现九号指令服务。", retryable: false)
            return
        }
        item.discoverCharacteristics([Self.writeID, Self.notifyID], for: service)
    }

    func peripheral(_ item: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isCurrent(item), !disconnecting, phase == .discovering, service.uuid == Self.service else { return }
        guard error == nil,
              let write = service.characteristics?.first(where: { $0.uuid == Self.writeID }),
              write.properties.contains(.writeWithoutResponse),
              let notify = service.characteristics?.first(where: { $0.uuid == Self.notifyID }),
              notify.properties.contains(.notify) || notify.properties.contains(.indicate) else {
            fail("指令服务缺少写入或通知能力。", retryable: false)
            return
        }
        writeCharacteristic = write
        notifyCharacteristic = notify
        if notify.isNotifying { beginPrecommunication() }
        else { item.setNotifyValue(true, for: notify) }
    }

    func peripheral(_ item: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(item), !disconnecting, characteristic === notifyCharacteristic else { return }
        guard error == nil, characteristic.isNotifying else {
            fail("蓝牙通知已关闭或启用失败。", retryable: true)
            return
        }
        if phase == .discovering { beginPrecommunication() }
    }

    func peripheral(_ item: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(item), !disconnecting, characteristic === notifyCharacteristic else { return }
        guard error == nil, let data = characteristic.value else {
            fail("读取蓝牙通知失败。", retryable: true)
            return
        }
        let captured = epoch
        for wire in assembler.append(data) {
            guard epoch == captured, !disconnecting else { return }
            do {
                let plain = try crypto.decrypt(wire)
                let frame = try VehicleBLEFrame.decode(plain)
                invalidPacketCount = 0
                handle(frame)
            } catch {
                invalidPacketCount += 1
                if invalidPacketCount == 1 || invalidPacketCount == 8 {
                    logBLE("收到无法验证的蓝牙帧；阶段=\(phase.rawValue)，长度=\(wire.count)，次数=\(invalidPacketCount)")
                }
                let serial = wire.count >= 2 ? UInt16(wire[wire.count - 2]) << 8 | UInt16(wire[wire.count - 1]) : 0
                if phase == .pairing, !readyForButtonPress, wire.count == 13, serial == 2 {
                    fail("车机就绪前收到旧会话回复，正在恢复本次配对；请先不要按 P 键。", retryable: true)
                    return
                }
                if invalidPacketCount >= 8 {
                    if phase == .authenticating { authenticationFailed("保存的密钥无法验证车辆回复。") }
                    else { fail("连续收到无法验证的蓝牙数据，将重新认证。", retryable: wantsSession) }
                    return
                }
            }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse item: CBPeripheral) {
        guard isCurrent(item), !disconnecting else { return }
        pumpWrites()
    }

    func peripheral(_ item: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard isCurrent(item), !disconnecting, invalidatedServices.contains(where: { $0.uuid == Self.service }) else { return }
        fail("车辆指令服务已变化，将重新连接。", retryable: true)
    }
}
