import Foundation

enum NinebotPairingPhase: String {
    case idle, scanning, connecting, discovering, preparing, needsPairing
    case pairing, authenticating, paired, starting, active, reconnecting, stopping
    case unavailable, failed
}

/// UI stages describe protocol evidence; they never certify dashboard video.
struct NinebotPairingPresentation {
    enum Step: Int, CaseIterable {
        case choose, prepare, confirm, authenticate, complete
        var title: String {
            switch self {
            case .choose: "选择车辆"
            case .prepare: "连接准备"
            case .confirm: "P 键确认"
            case .authenticate: "认证保存"
            case .complete: "完成"
            }
        }
    }
    let title: String
    let step: Step?
    let isWorking: Bool
    init(phase: NinebotPairingPhase, isPairing: Bool) {
        switch phase {
        case .idle: title = "添加或管理你的车辆"; step = nil; isWorking = false
        case .scanning: title = "正在查找附近车辆"; step = .choose; isWorking = true
        case .connecting, .discovering, .preparing:
            title = isPairing ? "正在连接并准备配对" : "正在连接车辆"; step = isPairing ? .prepare : nil; isWorking = true
        case .needsPairing: title = "可以发送本机配对请求"; step = .confirm; isWorking = false
        case .pairing: title = "请按一下车上的 P 键"; step = .confirm; isWorking = true
        case .authenticating: title = "正在验证车辆身份"; step = isPairing ? .authenticate : nil; isWorking = true
        case .paired: title = "车辆身份已验证"; step = .complete; isWorking = false
        case .starting: title = "正在等待仪表导航确认"; step = nil; isWorking = true
        case .active: title = "仪表已回应导航请求"; step = nil; isWorking = false
        case .reconnecting: title = "正在恢复蓝牙连接"; step = isPairing ? .prepare : nil; isWorking = true
        case .stopping: title = "正在结束车辆连接"; step = nil; isWorking = true
        case .unavailable: title = "蓝牙暂不可用"; step = nil; isWorking = false
        case .failed: title = "本次连接未完成"; step = nil; isWorking = false
        }
    }
}

struct NinebotPairingWindow: Equatable {
    let startedAt: TimeInterval
    let duration: TimeInterval
    func remaining(at uptime: TimeInterval) -> Int {
        guard uptime.isFinite, startedAt.isFinite, duration.isFinite, duration > 0, duration <= 3600 else { return 0 }
        return Int(ceil(min(duration, max(0, startedAt + duration - uptime))))
    }
    static func isFresh(lastSeen: TimeInterval, now: TimeInterval) -> Bool {
        lastSeen.isFinite && now.isFinite && now >= lastSeen && now - lastSeen <= 10
    }
    static func signal(_ rssi: Int?) -> String {
        guard let rssi, (-127 ... -1).contains(rssi) else { return "信号未知" }
        if rssi >= -60 { return "信号较强" }
        if rssi >= -80 { return "信号一般" }
        return "信号较弱"
    }
}
