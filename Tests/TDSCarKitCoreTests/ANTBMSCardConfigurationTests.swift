import CoreGraphics
import XCTest
@testable import TDSCarKitCore

final class ANTBMSCardConfigurationTests: XCTestCase {
    private func reading(cells: [Double?] = [4.1, nil, 4.106], temperatures: [Double?] = [nil, 14],
                         protection: UInt64 = 0) -> ANTBMSReading {
        ANTBMSReading(voltage: 82.78, current: -12.3, power: -1018, stateOfCharge: 78,
            stateOfHealth: 100, stateCode: 4, capacityAh: 170, remainingAh: 131.92,
            cells: cells, temperatures: temperatures, mosTemperature: 15,
            protectionBits: protection, warningBits: 0)
    }

    func testExistingUsersKeepAllSixMetricsInTwoLines() {
        let card = ANTBMSCardConfiguration()
        XCTAssertEqual(card.size, .medium)
        XCTAssertEqual(card.lines(for: reading()), ["蚂蚁  78%  82.78V  14°C", "-12.3A  -1018W  压差 6mV"])
    }

    func testCompactCardKeepsVoltageAndSpreadOnOneLine() {
        let card = ANTBMSCardConfiguration(savedFields: ANTBMSCardConfiguration.compactFields.map(\.rawValue))
        XCTAssertEqual(card.lines(for: reading()), ["蚂蚁  78%  82.78V  压差 6mV"])
    }

    func testSavedFieldsNormalizeDuplicatesAndUnknownValues() {
        let card = ANTBMSCardConfiguration(savedFields: ["cellDelta", "unknown", "voltage", "cellDelta"], sizeRawValue: 99)
        XCTAssertEqual(card.fields, [.cellDelta, .voltage])
        XCTAssertEqual(card.size, .medium)
        XCTAssertEqual(ANTBMSCardConfiguration(savedFields: []).fields, ANTBMSCardConfiguration.Field.allCases)
        XCTAssertEqual(ANTBMSCardConfiguration(savedFields: ["unknown"]).fields, ANTBMSCardConfiguration.Field.allCases)
    }

    func testLastMetricCannotBeHiddenAndSelectionCanBeSavedAndRestored() {
        var card = ANTBMSCardConfiguration(savedFields: ["cellDelta"], sizeRawValue: 2)
        XCTAssertFalse(card.set(.cellDelta, visible: false))
        XCTAssertTrue(card.set(.voltage, visible: true))
        XCTAssertTrue(card.set(.cellDelta, visible: false))
        let restored = ANTBMSCardConfiguration(savedFields: card.fields.map(\.rawValue), sizeRawValue: card.size.rawValue)
        XCTAssertEqual(restored, card)
        XCTAssertEqual(restored.fields, [.voltage])
    }

    func testMissingSensorsAreUnknownAndAlarmSurvivesFieldSelection() {
        let card = ANTBMSCardConfiguration(savedFields: ["temperature", "cellDelta"])
        XCTAssertEqual(card.lines(for: reading(cells: [nil, nil], temperatures: [], protection: 1)),
            ["蚂蚁  --°C  压差 --mV · 告警"])
    }

    func testCustomOrderIsRenderedAndSurvivesTogglingAndRestoring() {
        var card = ANTBMSCardConfiguration(savedFields: ["cellDelta", "voltage", "charge"])
        XCTAssertEqual(card.lines(for: reading()), ["蚂蚁  压差 6mV  82.78V  78%"])
        card.move(.charge, to: 0)
        XCTAssertEqual(card.fields, [.charge, .cellDelta, .voltage])
        card.set(.current, visible: true)
        XCTAssertEqual(card.fields, [.charge, .cellDelta, .voltage, .current])
        card.set(.voltage, visible: false)
        XCTAssertEqual(card.fields, [.charge, .cellDelta, .current])
        let restored = ANTBMSCardConfiguration(savedFields: card.fields.map(\.rawValue),
            sizeRawValue: card.size.rawValue, positionRawValue: card.position.rawValue,
            backgroundRawValue: card.background.rawValue)
        XCTAssertEqual(restored, card)
        let previous = card
        card.move(.temperature, to: 0)
        card.move(.charge, to: -1)
        card.move(.charge, to: 99)
        XCTAssertEqual(card, previous)
    }

    func testExistingPositionsAndBackgroundSurviveUpgrade() {
        XCTAssertEqual(ANTBMSCardConfiguration(positionRawValue: 0).position, .topRight)
        XCTAssertEqual(ANTBMSCardConfiguration(positionRawValue: 1).position, .bottomRight)
        let card = ANTBMSCardConfiguration(positionRawValue: 2, backgroundRawValue: 0)
        XCTAssertEqual(card.position, .topLeft)
        XCTAssertTrue(card.position.isAtTop)
        XCTAssertFalse(card.position.isAtRight)
        XCTAssertEqual(card.background.opacity, 0.45)
        let fallback = ANTBMSCardConfiguration(positionRawValue: 99, backgroundRawValue: 99)
        XCTAssertEqual(fallback.position, .topRight)
        XCTAssertEqual(fallback.background.opacity, 0.86)
        XCTAssertFalse(ANTBMSCardConfiguration.Position.bottomLeft.isAtTop)
        XCTAssertFalse(ANTBMSCardConfiguration.Position.bottomLeft.isAtRight)
    }

    func testNewPreferencesPreserveLegacyDefaultsAndInvalidValues() {
        let legacy = ANTBMSCardConfiguration()
        XCTAssertEqual(legacy.style, .classic); XCTAssertEqual(legacy.lossDisplay, .compact)
        XCTAssertNil(legacy.customAnchor)
        let invalid = ANTBMSCardConfiguration(styleRawValue: 99, lossDisplayRawValue: 99, anchorX: .nan, anchorY: 0.5)
        XCTAssertEqual(invalid, legacy)
        XCTAssertNil(ANTBMSCardConfiguration(anchorX: 0.4).customAnchor)
    }
    func testScenesAreExplicitStableAndKeepPlacementAndAppearance() {
        for scene in ANTBMSCardConfiguration.Scene.allCases {
            var card = ANTBMSCardConfiguration(sizeRawValue: 2, positionRawValue: 3, backgroundRawValue: 0,
                lossDisplayRawValue: 1, anchorX: 0.2, anchorY: 0.6)
            card.apply(scene)
            XCTAssertEqual(card.fields, scene.fields); XCTAssertEqual(card.fields.first, .charge)
            XCTAssertEqual(card.style, .prominent); XCTAssertEqual(card.mode, .custom)
            XCTAssertEqual(card.size, .large); XCTAssertEqual(card.background, .light); XCTAssertEqual(card.lossDisplay, .hidden)
            XCTAssertEqual(card.customAnchor, .init(x: 0.2, y: 0.6))
            let before = card
            _ = card.lines(for: reading()); _ = card.lines(for: reading(cells: [], temperatures: []))
            XCTAssertEqual(card, before)
        }
    }
    func testCustomPositionClampsAndCornerSelectionResetsIt() {
        var card = ANTBMSCardConfiguration(anchorX: -9, anchorY: 10)
        XCTAssertEqual(card.anchor, .init(x: 0, y: 1))
        card.snap(to: .topRight)
        XCTAssertNil(card.customAnchor); XCTAssertEqual(card.anchor, .init(x: 1, y: 0))
        XCTAssertEqual(ANTBMSCardConfiguration.Anchor(x: .infinity, y: .nan), .init(x: 0.5, y: 0.5))
    }
    func testPlacementStaysInsideEveryCanvasWithTallCardsAndPortraitOutput() {
        for size in ANTBMSCardConfiguration.Size.allCases {
            for position in ANTBMSCardConfiguration.Position.allCases {
                var card = ANTBMSCardConfiguration(sizeRawValue: size.rawValue, positionRawValue: position.rawValue)
                for dimensions in [(480,272),(848,480),(1024,600),(800,480),(1600,770),(1024,484),(2048,968),(480,800),(20,12)] {
                    let bounds = CGRect(x: 13, y: 17, width: dimensions.0, height: dimensions.1)
                    for height in [64,72,122,176,252,1800] {
                        let image = CGSize(width: 640, height: height)
                        let rect = card.overlayFrame(in: bounds, imageSize: image)
                        XCTAssertTrue(bounds.contains(rect), "\(bounds) \(rect)")
                        XCTAssertEqual(rect.width / rect.height, image.width / image.height, accuracy: 0.0001)
                    }
                    card.customAnchor = .init(x: 0.3, y: 0.7)
                    let rect = card.overlayFrame(in: bounds, imageSize: CGSize(width: 640, height: 252))
                    XCTAssertTrue(bounds.contains(rect))
                    card.customAnchor = nil
                }
            }
        }
    }
    func testNormalizedTravelRemainsStableAcrossResolutions() {
        let card = ANTBMSCardConfiguration(anchorX: 0.3, anchorY: 0.7)
        for dimensions in [(480,272),(848,480),(1024,600),(2048,968)] {
            let bounds = CGRect(x: 0, y: 0, width: dimensions.0, height: dimensions.1)
            let frame = card.overlayFrame(in: bounds, imageSize: CGSize(width: 640, height: 186))
            let margin = max(6, bounds.width * 0.007)
            XCTAssertEqual((frame.minX - margin) / (bounds.width - margin * 2 - frame.width), 0.3, accuracy: 0.0001)
            XCTAssertEqual((frame.minY - margin) / (bounds.height - margin * 2 - frame.height), 0.7, accuracy: 0.0001)
        }
        XCTAssertEqual(card.overlayFrame(in: .zero, imageSize: CGSize(width: 640, height: 176)), .zero)
    }
    func testProminentFieldsCanBeReorderedWithoutLosingPlacement() {
        var card = ANTBMSCardConfiguration(anchorX: 0.2, anchorY: 0.4)
        card.apply(.monitoring); card.move(.cellDelta, to: 0)
        XCTAssertEqual(card.fields.first, .cellDelta)
        XCTAssertEqual(card.style, .prominent); XCTAssertEqual(card.anchor, .init(x: 0.2, y: 0.4))
        let restored = ANTBMSCardConfiguration(savedFields: card.fields.map(\.rawValue), sizeRawValue: card.size.rawValue,
            positionRawValue: card.position.rawValue, backgroundRawValue: card.background.rawValue, modeRawValue: card.mode.rawValue,
            styleRawValue: card.style.rawValue, lossDisplayRawValue: card.lossDisplay.rawValue, anchorX: card.anchor.x, anchorY: card.anchor.y)
        XCTAssertEqual(restored, card)
    }

}
