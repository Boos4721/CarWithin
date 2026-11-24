import XCTest
@testable import TDSCarKitCore

final class NinebotProjectionDiagnosticsTests: XCTestCase {
    private func fixture(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var report: [String: Any] = [
            "schema": 1, "producer": "CarWithinNinebotProbe", "sessionID": UUID().uuidString,
            "generatedAt": "2026-11-24T12:00:00Z", "appVersion": "6.10.13", "appBuild": "test",
            "systemVersion": "18.7.1", "hooks": ["recordVideo": true, "stop": false], "frameCount": 2,
            "events": [["elapsed": 1.0, "kind": "recordingStarted", "detail": "NBVideoManager"]]
        ]
        change(&report)
        return try JSONSerialization.data(withJSONObject: report)
    }

    func testReportedRecordingAndFramesNeverCertifyInstrumentActivation() throws {
        let report = try NinebotProjectionDiagnostics.decode(fixture())
        XCTAssertEqual(report.appVersion, "6.10.13")
        XCTAssertTrue(report.summary.contains("已观察到调用"))
        XCTAssertTrue(report.summary.contains("不能证明仪表已激活"))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(try NinebotProjectionDiagnostics.decode(encoder.encode(report)), report)
    }

    func testMissingHooksAndNoObservedRecordingAreValidDiagnostics() throws {
        let report = try NinebotProjectionDiagnostics.decode(fixture {
            $0["hooks"] = ["recordVideo": false]; $0["events"] = []; $0["frameCount"] = 0
        })
        XCTAssertTrue(report.summary.contains("本次尚未观察到"))
        XCTAssertTrue(report.summary.contains("已挂钩 0 项"))
    }

    func testRejectsOversizedUnknownSchemaAndUnknownProducer() throws {
        XCTAssertThrowsError(try NinebotProjectionDiagnostics.decode(Data(repeating: 0, count: 128 * 1024 + 1)))
        XCTAssertThrowsError(try NinebotProjectionDiagnostics.decode(fixture { $0["schema"] = 2 }))
        XCTAssertThrowsError(try NinebotProjectionDiagnostics.decode(fixture { $0["producer"] = "other" }))
    }

    func testRejectsUnboundedOrUnknownEventsAndHooks() throws {
        XCTAssertThrowsError(try NinebotProjectionDiagnostics.decode(fixture {
            $0["events"] = Array(repeating: ["elapsed": 1, "kind": "mark", "detail": "x"], count: 81)
        }))
        XCTAssertThrowsError(try NinebotProjectionDiagnostics.decode(fixture {
            $0["events"] = [["elapsed": -1, "kind": "mark", "detail": "x"]]
        }))
        XCTAssertThrowsError(try NinebotProjectionDiagnostics.decode(fixture {
            $0["events"] = [["elapsed": 1, "kind": "mark", "detail": String(repeating: "x", count: 513)]]
        }))
        XCTAssertThrowsError(try NinebotProjectionDiagnostics.decode(fixture {
            $0["events"] = [["elapsed": 1, "kind": "instrumentActivated", "detail": "x"]]
        }))
        XCTAssertThrowsError(try NinebotProjectionDiagnostics.decode(fixture { $0["hooks"] = ["unknown": true] }))
        XCTAssertThrowsError(try NinebotProjectionDiagnostics.decode(fixture { $0["frameCount"] = -1 }))
    }
}
