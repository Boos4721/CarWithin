import XCTest
@testable import TDSCarKitCore

final class ConnectionTimelineTests: XCTestCase {
    func testReportKeepsFirstVideoTimingAndTerminalFailure() throws {
        var timeline = ConnectionTimeline(output: "九号五寸", uptime: 100)
        timeline.record(.wifi, detail: "已连接", uptime: 101)
        timeline.record(.video, detail: "关键帧", uptime: 103.5)
        timeline.record(.video, detail: "另一个关键帧", uptime: 104)
        timeline.record(.failed, detail: "协商失败", uptime: 110)
        timeline.record(.stopped, detail: "清理会话", uptime: 111)
        XCTAssertEqual(timeline.firstVideoSeconds, 3.5)
        XCTAssertEqual(timeline.events.last?.stage, .failed)
        XCTAssertTrue(timeline.ended)
        let restored = try JSONDecoder().decode(ConnectionTimeline.self, from: JSONEncoder().encode(timeline))
        XCTAssertEqual(restored.events, timeline.events)
        XCTAssertEqual(restored.firstVideoSeconds, timeline.firstVideoSeconds)
    }

    func testDuplicateStatusAndClockReversalDoNotDistortTimeline() {
        var timeline = ConnectionTimeline(output: "七寸", uptime: 100)
        timeline.record(.wifi, detail: "等待网络", uptime: 101)
        timeline.record(.wifi, detail: "等待网络", uptime: 102)
        timeline.record(.control, detail: "等待控制", uptime: 99)
        XCTAssertEqual(timeline.events.count, 2)
        XCTAssertEqual(timeline.events.map(\.elapsed), [1, 1])
    }

    func testLongSessionReportRemainsBoundedAndRetainsVideoResult() {
        var timeline = ConnectionTimeline(output: "五寸", uptime: 100)
        timeline.record(.video, detail: "视频", uptime: 102)
        for index in 0..<100 { timeline.record(.instrument, detail: String(repeating: "a", count: 400) + "\(index)", uptime: Double(index + 103)) }
        // The bounded detail is identical, so repeated heartbeat messages collapse.
        XCTAssertEqual(timeline.events.count, 2)
        for index in 0..<100 { timeline.record(.instrument, detail: "事件 \(index)", uptime: Double(index + 203)) }
        XCTAssertEqual(timeline.events.count, 64)
        XCTAssertTrue(timeline.events.allSatisfy { $0.detail.count <= 300 })
        XCTAssertEqual(timeline.firstVideoSeconds, 2)
    }
}
