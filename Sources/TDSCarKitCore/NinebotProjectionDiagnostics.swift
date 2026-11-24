import Foundation

/// Evidence from the companion injected into Ninebot. It never certifies instrument activation.
public struct NinebotProjectionDiagnostics: Codable, Equatable {
    public struct Event: Codable, Equatable {
        public let elapsed: Double
        public let kind: String
        public let detail: String
    }
    public struct Observation: Codable, Equatable {
        public let status: String
        public let encoding: String
    }
    public let schema: Int
    public let producer: String
    public let sessionID: UUID
    public let generatedAt: Date
    public let appVersion: String
    public let appBuild: String
    public let systemVersion: String
    public let hooks: [String: Bool]
    public let frameCount: Int
    public let events: [Event]
    /// Optional additions in companion 0.2; schema 1 reports from 0.1 remain readable.
    public let pluginVersion: String?
    public let counters: [String: Int]?
    public let observations: [String: Observation]?
    public let methodInventory: [String]?
    /// 0.3 retains process totals across manual capture resets and checks current method implementations.
    public let processCounters: [String: Int]?
    public let hookChecks: [String: String]?
    public let activationInventory: [String]?

    public enum Failure: Error, LocalizedError {
        case tooLarge, unsupported, malformed
        public var errorDescription: String? {
            switch self {
            case .tooLarge: "诊断报告超过 128 KB。"
            case .unsupported: "不是受支持的九号投屏助手报告。"
            case .malformed: "诊断报告字段无效或超出限制。"
            }
        }
    }

    public static let maximumBytes = 128 * 1024
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report: Self
        do { report = try decoder.decode(Self.self, from: data) }
        catch { throw Failure.malformed }
        guard report.schema == 1, report.producer == "CarWithinNinebotProbe" else { throw Failure.unsupported }
        let allowedHooks: Set<String> = ["recordVideo", "stop", "pixelBufferClass", "pixelBufferInstance", "controlAction"]
        let allowedEvents: Set<String> = ["loaded", "foreground", "hook", "action", "recordingStarted", "recordingStopped", "firstFrame", "mark"]
        guard report.events.count <= 80, report.hooks.count <= allowedHooks.count,
              report.hooks.keys.allSatisfy({ allowedHooks.contains($0) }),
              report.frameCount >= 0, report.frameCount <= Int(Int32.max),
              [report.appVersion, report.appBuild, report.systemVersion].allSatisfy({ $0.utf8.count <= 64 }),
              report.events.allSatisfy({ $0.elapsed.isFinite && $0.elapsed >= 0 && $0.elapsed <= 31_536_000
                  && allowedEvents.contains($0.kind) && $0.detail.utf8.count <= 512 }) else { throw Failure.malformed }
        let allowedCounters: Set<String> = ["recordCalls", "stopCalls", "pixelCalls", "mjpegCalls", "encodedCallbacks", "pixelNilOutputs", "mjpegNilOutputs", "h264Callbacks", "mjpegEncodedCallbacks"]
        let allowedObservations = allowedHooks.union(["mjpegClass", "mjpegInstance", "encodedCallback", "h264Callback", "mjpegEncodedCallback"])
        let allowedStates: Set<String> = ["hooked", "classMissing", "methodMissing", "signatureMismatch"]
        let allowedChecks: Set<String> = ["active", "replaced", "notInstalled"]
        func validCounters(_ counters: [String: Int]) -> Bool {
            counters.count <= allowedCounters.count && counters.allSatisfy {
                allowedCounters.contains($0.key) && $0.value >= 0 && $0.value <= Int(Int32.max)
            }
        }
        guard report.pluginVersion.map({ $0.utf8.count <= 16 }) ?? true,
              report.counters.map(validCounters) ?? true,
              report.processCounters.map(validCounters) ?? true,
              report.hookChecks.map({ $0.count <= allowedObservations.count && $0.allSatisfy {
                  allowedObservations.contains($0.key) && allowedChecks.contains($0.value)
              } }) ?? true,
              report.observations.map({ $0.count <= allowedObservations.count && $0.allSatisfy {
                  allowedObservations.contains($0.key) && allowedStates.contains($0.value.status)
                      && $0.value.encoding.utf8.count <= 512
              } }) ?? true,
              report.methodInventory.map({ $0.count <= 32 && $0.allSatisfy { $0.utf8.count <= 512 } }) ?? true,
              report.activationInventory.map({ $0.count <= 64 && $0.allSatisfy { $0.utf8.count <= 512 } }) ?? true
        else { throw Failure.malformed }
        return report
    }

    public var summary: String {
        let hookCount = hooks.values.filter { $0 }.count
        let started = counters.map { ($0["recordCalls"] ?? 0) > 0 }
            ?? events.contains { $0.kind == "recordingStarted" }
        let actions = events.filter { $0.kind == "action" }.count
        let detailed: String
        if let counters {
            detailed = "普通转换 \(counters["pixelCalls"] ?? 0) 次 · MJPEG 转换 \(counters["mjpegCalls"] ?? 0) 次\n"
                + "编码回调 \(counters["encodedCallbacks"] ?? 0) 次\n"
                + (pluginVersion == "0.3" || counters["h264Callbacks"] != nil || counters["mjpegEncodedCallbacks"] != nil
                   ? "H.264 回调 \(counters["h264Callbacks"] ?? 0) 次 · MJPEG 回调 \(counters["mjpegEncodedCallbacks"] ?? 0) 次\n" : "")
        } else { detailed = "" }
        let process = processCounters.map { "进程累计录制：\($0["recordCalls"] ?? 0) 次（包含本轮清零前）\n" } ?? ""
        let checks = hookChecks.map { "挂钩后被替换：\($0.values.filter { $0 == "replaced" }.count) 项（仅比较当前方法实现）\n" } ?? ""
        return "九号出行 \(appVersion)（\(appBuild)）· iOS \(systemVersion)\n"
            + "已挂钩 \(hookCount) 项 · 相关控件操作 \(actions) 次\n"
            + "官方录制入口：\(started ? "已观察到调用" : "本次尚未观察到")\n"
            + "非空图像转换输出：\(frameCount) 次\n" + detailed + process + checks
            + "这些是 App 内调用证据，不能证明仪表已激活或已经出画。"
    }
}
