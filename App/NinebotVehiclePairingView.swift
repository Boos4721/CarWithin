import SwiftUI
import UIKit

struct NinebotVehiclePairingView: View {
    @ObservedObject var connection: NinebotVehicleConnection
    let locked: Bool
    @Environment(\.openURL) private var openURL
    @State private var vehicleToForget: NinebotVehicle?
    @State private var confirmsRemoval = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            content(now: ProcessInfo.processInfo.systemUptime)
        }
        .onDisappear { if !locked { connection.cancelPairing() } }
        .confirmationDialog("删除本机配对记录？", isPresented: $confirmsRemoval, titleVisibility: .visible,
                            presenting: vehicleToForget) { vehicle in
            Button("删除 \(vehicle.name)", role: .destructive) { connection.forgetVehicle(vehicle.id) }
        } message: { _ in
            Text("仅删除这台设备上的车辆记录和蓝牙密钥，不删除车辆官方账号绑定；其他车辆的记录保留。")
        }
    }

    private func content(now: TimeInterval) -> some View {
        Form {
            statusSection
            progressSection
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
                Label(vehicle.name, systemImage: "checkmark.shield.fill")
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
                    Button("发送配对请求") { connection.beginPairing() }
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
                        .disabled(!connection.canScan)
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

    private var savedVehiclesSection: some View {
        Section {
            vehicleRow("不启用车辆蓝牙自动连接", detail: "保留已有配对，启动时不自动连接车辆蓝牙。",
                       selected: connection.garage.selected == nil) { connection.selectVehicle(nil) }
            ForEach(connection.garage.vehicles) { vehicle in
                VStack(alignment: .leading, spacing: 8) {
                    vehicleRow(vehicle.name, detail: "本机识别码 " + String(vehicle.id.uuidString.suffix(6)),
                               selected: vehicle.id == connection.garage.selected?.id) { connection.selectVehicle(vehicle.id) }
                    if !locked {
                        Button { connection.checkPairedVehicle(vehicle.id) } label: {
                            Label("检查蓝牙连接", systemImage: "arrow.clockwise")
                                .font(.subheadline).frame(minHeight: 44)
                        }
                        .buttonStyle(.borderless)
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
        return Button { connection.connectForPairing(device) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(device.name).foregroundStyle(.primary)
                Text("本机识别码 \(device.shortID) · \(NinebotPairingWindow.signal(device.rssi))")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(fresh ? device.detail : "广播已过期，请重新扫描。")
                    .font(.footnote).foregroundStyle(.secondary)
                if connection.garage.vehicles.contains(where: { $0.id == device.id }) {
                    Text("已在本机配对").font(.caption).foregroundStyle(.secondary)
                }
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
