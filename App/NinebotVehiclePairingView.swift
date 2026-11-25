import SwiftUI
import UIKit

struct NinebotVehiclePairingView: View {
    @ObservedObject var connection: NinebotVehicleConnection
    let locked: Bool
    @Environment(\.openURL) private var openURL
    @State private var vehicleToForget: NinebotVehicle?
    @State private var confirmsRemoval = false
    @State private var deviceToConfirm: NinebotVehicleConnection.Device?
    @State private var confirmsConnection = false
    @State private var pairingToConfirm: NinebotPairingTarget?
    @State private var confirmsPairing = false
    @State private var vehicleToRename: NinebotVehicle?
    @State private var showsRename = false
    @State private var editedName = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            content(now: ProcessInfo.processInfo.systemUptime)
        }
        .onDisappear { if !locked { connection.cancelPairing() } }
        .confirmationDialog("删除本机配对记录？", isPresented: $confirmsRemoval, titleVisibility: .visible,
                            presenting: vehicleToForget) { vehicle in
            Button("删除 \(vehicle.title)", role: .destructive) { connection.forgetVehicle(vehicle.id) }
        } message: { _ in
            Text("仅删除这台设备上的车辆记录和蓝牙密钥，不删除车辆官方账号绑定；其他车辆的记录保留。")
        }
        .alert("核对连接目标", isPresented: $confirmsConnection, presenting: deviceToConfirm) { device in
            Button("确认并连接") { if !locked { connection.connectForPairing(device) } }
            Button("取消", role: .cancel) {}
        } message: { device in
            Text("蓝牙名称：\(device.name)\n本机识别码：\(device.shortID)\n请先与自己的车辆核对。名称、信号和广播识别只能辅助判断；识别码不是车架号或蓝牙 MAC 地址。")
        }
        .alert("向这台车发送配对请求？", isPresented: $confirmsPairing, presenting: pairingToConfirm) { target in
            Button("发送请求") { if !locked { connection.beginPairing(confirmedTarget: target) } }
            Button("取消", role: .cancel) {}
        } message: { target in
            Text("蓝牙名称：\(target.bluetoothName)\n本机识别码：\(target.id.uuidString.suffix(6))\n确认后只按自己车辆上的 P 键，再等待身份认证完成。")
        }
        .alert("车辆显示名称", isPresented: $showsRename) {
            TextField("最多 40 字，留空恢复蓝牙名称", text: $editedName)
            Button("保存") {
                if !locked, let vehicle = vehicleToRename { connection.renameVehicle(vehicle.id, to: editedName) }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("仅修改本机显示名称，原蓝牙名称继续用于车辆认证。") }

    }

    private func content(now: TimeInterval) -> some View {
        Form {
            statusSection
            progressSection
            finderSection
            successSection
            pairingControls(now: now)
            savedVehiclesSection
        }
    }

    private var statusSection: some View {
        Section {
            Label(connection.presentation.title, systemImage: stateSymbol)
                .font(.headline)
                .foregroundStyle(connection.phase == .failed || connection.phase == .unavailable ? Color.orange : Color.primary)
            if let name = connection.attemptName { Text("当前操作：" + name).font(.subheadline) }
            Text(connection.status).font(.subheadline).foregroundStyle(.secondary)
            if connection.isDisconnecting {
                Text("正在释放上一条蓝牙连接，请稍候…").font(.footnote).foregroundStyle(.secondary)
            }
            if locked {
                Label("CarPlay 连接期间保留当前车辆；停止后可添加、更换或检查配对。", systemImage: "lock.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if connection.presentation.isWorking { ProgressView().accessibilityLabel("车辆连接正在进行") }
            if connection.needsBluetoothSettings {
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        }
    }

    @ViewBuilder private var progressSection: some View {
        if !locked, let current = connection.presentation.step {
            Section("配对进度") {
                Text("第 \(current.rawValue + 1) / 5 步 · " + current.title)
                    .font(.subheadline.weight(.medium))
                ProgressView(value: Double(current.rawValue + (current == .complete ? 1 : 0)), total: 5)
                    .accessibilityLabel("配对步骤")
                    .accessibilityValue(current.title)
                DisclosureGroup("查看完整步骤") {
                    ForEach(NinebotPairingPresentation.Step.allCases, id: \.rawValue) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: stepSymbol(step, current: current)).accessibilityHidden(true)
                            Text(step.title)
                            Spacer(minLength: 8)
                            if step == .confirm, current.rawValue > step.rawValue,
                               !connection.hasPairingAcknowledgement {
                                Text("沿用已存配对").font(.caption).foregroundStyle(.secondary)
                            } else if step == current { Text("当前").font(.caption).foregroundStyle(.secondary) }
                        }
                        .font(.subheadline)
                        .foregroundStyle(step.rawValue > current.rawValue ? Color.secondary : Color.primary)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    @ViewBuilder private var successSection: some View {
        if !locked, connection.phase == .paired, let vehicle = connection.pairedVehicle {
            Section {
                Label(vehicle.title, systemImage: "checkmark.shield.fill")
                if connection.garage.selected?.id == vehicle.id {
                    Text("这台车已用于当前车辆配置。")
                } else {
                    Button("用于当前车辆") { connection.selectVehicle(vehicle.id) }
                        .disabled(!connection.canChooseVehicle)
                }
                if !connection.canChooseVehicle {
                    Text("正在结束配对连接，请稍候…").font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("认证成功")
            } footer: { Text("已保存本机身份；配对成功不代表仪表已出画。返回首页启动 CarPlay 后再确认投屏。") }
        }
    }

    @ViewBuilder private func pairingControls(now: TimeInterval) -> some View {
        if !locked {
            Section {
                if connection.canBeginPairing {
                    Button("发送配对请求") {
                        pairingToConfirm = connection.pairingTarget
                        confirmsPairing = pairingToConfirm != nil
                    }
                        .buttonStyle(.borderedProminent)
                    Text("点击后再按一下车上的 P 键，等待车辆确认。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let window = connection.confirmationWindow {
                    let remaining = window.remaining(at: now)
                    Text(remaining > 0 ? "等待 P 键确认 · 还剩 \(remaining) 秒" : "确认窗口已结束，正在处理结果…")
                        .font(.headline).monospacedDigit()
                        .accessibilityLabel("等待 P 键确认，剩余 \(remaining) 秒")
                }
                if connection.canRetryPairing {
                    Button("重试这台车") { connection.retryPairing() }
                    if let name = connection.retryTargetName {
                        Text("重试目标：" + name).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if connection.isPairing {
                    Button(connection.isScanning ? "停止扫描" : "取消配对", role: .cancel) { connection.cancelPairing() }
                } else {
                    Button(connection.devices.isEmpty ? "扫描附近车辆（30 秒）" : "重新扫描（30 秒）") { connection.startScan() }
                        .disabled(!connection.canScan || connection.finder.stage != .idle)
                }
            } header: {
                Text("添加与检查")
            } footer: { Text("给车辆通电并靠近设备。首次配对需按 P 键确认；若其他 App 正占用蓝牙，请先结束其车辆连接后重试。") }

            if connection.canScan {
                Section {
                    if let window = connection.scanWindow {
                        Text("扫描剩余 \(window.remaining(at: now)) 秒 · 已发现 \(connection.devices.count) 台")
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if connection.devices.isEmpty {
                        Text(connection.isScanning ? "正在等待已验证的九号车辆广播…" : "尚无扫描结果，点击上方按钮开始查找。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(connection.devices) { device in
                        nearbyRow(device, now: now)
                    }
                } header: {
                    Text("附近车辆")
                } footer: { Text("仅显示通过九号广播校验的设备。相同名称可按本机识别码区分；信号强弱仅供参考，列表不会自动选车。") }
            }
        }
    }

    @ViewBuilder private var finderSection: some View {
        if !locked, connection.canScan {
            Section {
                switch connection.finder.stage {
                case .idle:
                    Button("帮我找自己的车") { connection.beginFindingVehicle() }
                    Text("先核对九号出行中的蓝牙名称；仍分不清时，用断电与通电两轮扫描找候选设备。")
                        .font(.footnote).foregroundStyle(.secondary)
                case .prepareOff:
                    Text("1 · 先给自己的车辆断电")
                    Text("车辆静止后操作，等附近广播稳定，再开始第一轮扫描。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("已断电，开始第一轮扫描") { connection.scanFinderRound() }
                case .scanningOff:
                    Text("1 · 正在记录断电时的附近设备")
                    Text("请保持自己的车辆断电，等待这一轮 30 秒扫描结束。")
                        .font(.footnote).foregroundStyle(.secondary)
                case .prepareOn:
                    Text("2 · 给自己的车辆通电")
                    Text("第一轮已完成。保持位置不变，等车辆启动后再扫描。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("已通电，开始第二轮扫描") { connection.scanFinderRound() }
                case .scanningOn:
                    Text("2 · 正在记录通电后的附近设备")
                    Text("请保持车辆通电，等待这一轮扫描结束。")
                        .font(.footnote).foregroundStyle(.secondary)
                case .results:
                    Text(connection.finder.suggestions.isEmpty ? "没有找到明显新增的候选设备" : "发现 \(connection.finder.suggestions.count) 个新增候选，请在下方核对")
                    Text("有些车断电后仍广播；其他车辆靠近也会新增。请对照名称和信号，选中后继续 P 键确认与身份认证。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("重新做两轮对比") { connection.beginFindingVehicle() }
                }
                if connection.finder.stage != .idle {
                    Button("结束找车引导", role: .cancel) { connection.cancelFindingVehicle() }
                }
            } header: {
                Text("确认自己的车辆")
            } footer: {
                Text("找车结果只用于辅助核对，不自动连接或证明车辆归属。")
            }
        }
    }

    private var savedVehiclesSection: some View {
        Section {
            vehicleRow("不启用车辆蓝牙自动连接", detail: "保留已有配对，启动时不自动连接车辆蓝牙。",
                       selected: connection.garage.selected == nil) { connection.selectVehicle(nil) }
            ForEach(connection.garage.vehicles) { vehicle in
                VStack(alignment: .leading, spacing: 8) {
                    vehicleRow(vehicle.title, detail: "蓝牙名称 " + vehicle.name + " · 本机识别码 " + String(vehicle.id.uuidString.suffix(6)),
                               selected: vehicle.id == connection.garage.selected?.id) { connection.selectVehicle(vehicle.id) }
                    if !locked {
                        Button { connection.checkPairedVehicle(vehicle.id) } label: {
                            Label("检查蓝牙连接", systemImage: "arrow.clockwise")
                                .font(.subheadline).frame(minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        Button("修改显示名称") {
                            vehicleToRename = vehicle; editedName = vehicle.displayName ?? ""; showsRename = true
                        }
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                    }
                }
                .swipeActions(allowsFullSwipe: false) {
                    Button("删除", role: .destructive) {
                        vehicleToForget = vehicle; confirmsRemoval = true
                    }
                }
            }
        } header: {
            Text("已配对车辆")
        } footer: {
            Text("选择的车辆跟随当前车辆配置保存。「检查蓝牙连接」只验证已存身份，不开启仪表导航；需要重新配对时仍由你发送请求并按 P 键确认。")
        }
        .disabled(locked || !connection.canChooseVehicle)
    }

    private func nearbyRow(_ device: NinebotVehicleConnection.Device, now: TimeInterval) -> some View {
        let fresh = connection.isFresh(device, at: now)
        return Button {
            deviceToConfirm = device; confirmsConnection = true
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(connection.garage.vehicles.first(where: { $0.id == device.id })?.title ?? device.name).foregroundStyle(.primary)
                if connection.finder.suggestions.contains(device.id) {
                    Label("通电后新发现 · 建议核对", systemImage: "magnifyingglass")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("本机识别码 \(device.shortID) · \(NinebotPairingWindow.signal(device.rssi))")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(fresh ? device.detail : "广播已过期，请重新扫描。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(connection.garage.vehicles.contains(where: { $0.id == device.id })
                     ? "已在本机配对 · 连接后验证身份" : "尚未验证车辆身份")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(!connection.canConnect(device, at: now))
    }

    private var stateSymbol: String {
        if connection.phase == .failed || connection.phase == .unavailable { return "exclamationmark.circle" }
        if connection.phase == .paired { return "checkmark.shield.fill" }
        return "scooter"
    }

    private func stepSymbol(_ step: NinebotPairingPresentation.Step, current: NinebotPairingPresentation.Step) -> String {
        if step == .confirm, current.rawValue > step.rawValue, !connection.hasPairingAcknowledgement { return "arrow.right.circle" }
        return step.rawValue < current.rawValue || current == .complete ? "checkmark.circle.fill"
            : step == current ? "circle.inset.filled" : "circle"
    }

    private func vehicleRow(_ title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
