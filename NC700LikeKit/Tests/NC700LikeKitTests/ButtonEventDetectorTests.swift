import XCTest
@testable import NC700LikeKit

final class ButtonEventDetectorTests: XCTestCase {
    let idle: [UInt8] = [0x02, 0x06, 0x40, 0x24, 0x02, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x07, 0x00, 0x1C, 0x0F, 0x00, 0xF4, 0x04, 0x00, 0x06]
    let pressed: [UInt8] = [0x02, 0x06, 0x40, 0x24, 0x02, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x07, 0x00, 0x1C, 0x0F, 0x00, 0xF4, 0x04, 0x10, 0x0E]

    func testInitialReadDoesNotFire() {
        var detector = ButtonEventDetector()
        XCTAssertEqual(detector.process(value: pressed, at: 0, isInitial: true), .ignored)
        XCTAssertEqual(detector.lastKnownState, [0x10, 0x0E])
    }

    func testPressAfterIdleFiresOnStateChange() {
        var detector = ButtonEventDetector()
        XCTAssertEqual(detector.process(value: idle, at: 0, isInitial: true), .ignored)
        XCTAssertEqual(detector.process(value: pressed, at: 1), .press)
        XCTAssertEqual(detector.process(value: pressed, at: 2), .ignored)
    }

    func testDuplicateSameStateNotificationsAreIgnored() {
        var detector = ButtonEventDetector()
        XCTAssertEqual(detector.process(value: idle, at: 0, isInitial: true), .ignored)
        XCTAssertEqual(detector.process(value: idle, at: 1), .ignored)
        XCTAssertEqual(detector.process(value: idle, at: 2), .ignored)
    }

    func testAlternatingPressesFireEachTime() {
        var detector = ButtonEventDetector()
        XCTAssertEqual(detector.process(value: idle, at: 0, isInitial: true), .ignored)
        XCTAssertEqual(detector.process(value: pressed, at: 10), .press)
        XCTAssertEqual(detector.process(value: idle, at: 20), .press)
        XCTAssertEqual(detector.process(value: pressed, at: 30), .press)
        XCTAssertEqual(detector.process(value: idle, at: 40), .press)
    }

    func testRapidChangesWithinDebounceWindowCollapsesToSinglePress() {
        var detector = ButtonEventDetector()
        XCTAssertEqual(detector.process(value: idle, at: 0, isInitial: true), .ignored)
        XCTAssertEqual(detector.process(value: pressed, at: 1.0), .press)
        XCTAssertEqual(detector.process(value: idle, at: 1.1), .ignored)
        XCTAssertEqual(detector.process(value: pressed, at: 1.2), .ignored)
        // デバウンス(300ms)を過ぎた後の変化は、新たな押下として発火する
        XCTAssertEqual(detector.process(value: idle, at: 1.5), .press)
        XCTAssertEqual(detector.process(value: pressed, at: 2.0), .press)
    }

    func testUnknownValueDoesNotCorruptLastKnownState() {
        var detector = ButtonEventDetector()
        XCTAssertEqual(detector.process(value: idle, at: 0, isInitial: true), .ignored)
        // 未知の値をはさんでも、既知の同状態に戻ったときは重複として無視する
        let unknown: [UInt8] = Array(repeating: 0x00, count: 19)
        XCTAssertEqual(detector.process(value: unknown, at: 1), .ignored)
        XCTAssertEqual(detector.process(value: idle, at: 2), .ignored)
        XCTAssertEqual(detector.process(value: pressed, at: 3), .press)
    }

    func testShortValueIsIgnored() {
        var detector = ButtonEventDetector()
        XCTAssertEqual(detector.process(value: [0x00, 0x06], at: 0), .ignored)
        XCTAssertNil(detector.lastKnownState)
    }

    func testCustomOffsetAndStates() {
        var configuration = DeviceConfiguration.default
        configuration.stateOffsetInBytes = 0
        configuration.stateLengthInBytes = 1
        configuration.pressStates = [[0x00], [0x10]]
        var detector = ButtonEventDetector(configuration: configuration)
        XCTAssertEqual(detector.process(value: [0x00], at: 0, isInitial: true), .ignored)
        XCTAssertEqual(detector.process(value: [0x10], at: 1), .press)
    }

    func testResetClearsState() {
        var detector = ButtonEventDetector()
        XCTAssertEqual(detector.process(value: idle, at: 0, isInitial: true), .ignored)
        detector.reset()
        XCTAssertNil(detector.lastKnownState)
        // リセット後は同状態でも lastKnownState が nil なので発火する
        XCTAssertEqual(detector.process(value: idle, at: 1), .press)
    }

    func testRealisticIntervalPattern() {
        var detector = ButtonEventDetector()
        XCTAssertEqual(detector.process(value: idle, at: 0, isInitial: true), .ignored)
        XCTAssertEqual(detector.process(value: pressed, at: 1), .press)
        XCTAssertEqual(detector.process(value: idle, at: 1.05), .ignored)
        XCTAssertEqual(detector.process(value: pressed, at: 1.10), .ignored)
        XCTAssertEqual(detector.process(value: idle, at: 1.20), .ignored)
    }
}
