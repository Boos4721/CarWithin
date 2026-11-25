import Foundation

public struct BMSOverviewPresentation {
    public let primaryFields: [ANTBMSCardConfiguration.Field]
    public let healthFields: [ANTBMSCardConfiguration.Field]
    public init(capabilities: BMSFieldCapabilities) {
        let fields = capabilities.observed.isEmpty
            ? Set(capabilities.recommendedFields) : capabilities.observed
        primaryFields = [.charge, .voltage, .current, .power].filter { fields.contains($0) }
        healthFields = [.temperature, .cellDelta].filter { fields.contains($0) }
    }
}

/// Snapshot text only uses recorded statistics. It never estimates capacity, distance or missing sensors.
public struct BMSRecordSummary: Equatable {
    public let hasSamples: Bool
    public let duration: String
    public let charge: String
    public let coverage: String
    public let details: String
    public init(statistics: ANTBMSSessionStatistics) {
        hasSamples = statistics.sampleCount > 0
        if let seconds = statistics.coverage?.recordingSeconds {
            let value = Int(max(0, min(seconds, 31_536_000)))
            duration = "\(value / 60) 分 \(value % 60) 秒"
        } else { duration = "时长未保存" }
        charge = statistics.firstCharge.flatMap { first in
            statistics.lastCharge.map { "\(first)% → \($0)%" }
        } ?? "电量未提供"
        coverage = statistics.coverageRatio.map { String(format: "有效数据覆盖 %.0f%%", $0 * 100) }
            ?? (statistics.coverage == nil ? "完整度未保存" : "有效数据覆盖 --")
        var lines: [String] = []
        if let low = statistics.minimumVoltage, let high = statistics.maximumVoltage {
            lines.append(String(format: "全程电压 %.2f–%.2f V", low, high))
        }
        if let power = statistics.peakAbsolutePower { lines.append("峰值功率 |P| \(power) W") }
        if let delta = statistics.maximumCellDelta { lines.append(String(format: "最大压差 %.0f mV", delta * 1000)) }
        if let temperature = statistics.maximumTemperature { lines.append(String(format: "最高温度 %.0f°C", temperature)) }
        details = lines.joined(separator: "\n")
    }
}
