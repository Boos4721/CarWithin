import Foundation

/// Presentation uses explicit events and confirmed network observations, never translated log matching.
public enum InstrumentChannelPhase: Equatable {
    case idle, preparing, waitingForPorts, ready, responding, sending, recovering, failed
    public var title: String {
        switch self {
        case .idle: "尚未启动"
        case .preparing: "正在准备通道"
        case .waitingForPorts: "投屏端口被占用，等待释放"
        case .ready: "通道已准备，等待仪表回应"
        case .responding: "已收到仪表回应，等待视频传输"
        case .sending: "正在发送视频，仪表出画待确认"
        case .recovering: "正在恢复投屏通道"
        case .failed: "仪表通道异常"
        }
    }
}

public struct ConnectionOverview: Equatable {
    public enum Phase: Equatable { case idle, checkingWiFi, starting, controlConnected, displaying, stopped, failed }
    public let wifi: String
    public let carPlay: String
    public let needsNetworkAction: Bool
    public init(phase: Phase, expectedSSID: String, actualSSID: String?, hasWiFiAddress: Bool,
                hasIdentity: Bool, failure: String? = nil) {
        if phase == .checkingWiFi {
            wifi = "正在检查并连接车辆 Wi-Fi"
            needsNetworkAction = false
        } else if let actualSSID, !actualSSID.isEmpty, hasWiFiAddress {
            let matches = expectedSSID.isEmpty || actualSSID == expectedSSID
            wifi = matches ? "已连接 · \(actualSSID)" : "当前 \(actualSSID) · 与预设不一致"
            needsNetworkAction = !matches
        } else if hasWiFiAddress {
            wifi = "Wi-Fi 地址可用，网络名称未确认"
            needsNetworkAction = false
        } else {
            wifi = expectedSSID.isEmpty ? "尚未确认 Wi-Fi 连接" : "等待连接 · \(expectedSSID)"
            needsNetworkAction = true
        }
        if let failure { carPlay = failure }
        else if !hasIdentity { carPlay = "缺少本机 CarPlay 身份" }
        else {
            switch phase {
            case .idle: carPlay = "准备就绪"
            case .checkingWiFi: carPlay = "网络就绪后启动"
            case .starting: carPlay = "正在建立 CarPlay 会话"
            case .controlConnected: carPlay = "控制连接已建立，等待视频"
            case .displaying: carPlay = "本机 CarPlay 已出画"
            case .stopped: carPlay = "已停止"
            case .failed: carPlay = "连接未完成，请重试"
            }
        }
    }
}
