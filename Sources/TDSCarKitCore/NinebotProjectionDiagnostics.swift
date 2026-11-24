import Foundation

/// Evidence from the companion injected into Ninebot. It never certifies instrument activation.
public struct NinebotProjectionDiagnostics: Codable, Equatable {
    public struct Event: Codable, Equatable {
        public let elapsed: Double
        public let kind: String
        public let detail: String
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
        return report
    }

    public var summary: String {
        let hookCount = hooks.values.filter { $0 }.count
        let started = events.contains { $0.kind == "recordingStarted" }
        let actions = events.filter { $0.kind == "action" }.count
        return "九号出行 \(appVersion)（\(appBuild)）· iOS \(systemVersion)\n"
            + "已挂钩 \(hookCount) 项 · 相关控件操作 \(actions) 次\n"
            + "官方录制入口：\(started ? "已观察到调用" : "本次尚未观察到")\n"
            + "官方图像转换：\(frameCount) 次\n"
            + "这些是 App 内调用证据，不能证明仪表已激活或已经出画。"
    }
}
