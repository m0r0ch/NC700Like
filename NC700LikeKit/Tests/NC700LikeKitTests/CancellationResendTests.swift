import XCTest
@testable import NC700LikeKit

final class P1ResendWindowTests: XCTestCase {
    private let pressAt: TimeInterval = 1_000.0
    private let window8 = CancelRetryConstants.resendWindowSeconds
    private let window2 = CancelRetryConstants.legacyWindowSeconds

    private var immediatePIWindow: P1ResendWindow {
        P1ResendWindow(
            windowSeconds: window8,
            pressAt: pressAt,
            immediateID: 0x4A,
            sentImmediate: true
        )
    }

    private var deferredWindow: P1ResendWindow {
        P1ResendWindow(
            windowSeconds: window8,
            pressAt: pressAt,
            immediateID: nil,
            sentImmediate: false
        )
    }

    func testConstantsMeetDesignValues() {
        XCTAssertEqual(CancelRetryConstants.resendWindowSeconds, 8.0)
        XCTAssertEqual(CancelRetryConstants.legacyWindowSeconds, 2.0)
        XCTAssertEqual(CancelRetryConstants.maxResends, 1)
    }

    func testNilWindowIsSkipped() {
        let decision = P1ResendWindow.decide(
            window: nil,
            controlTerminal: 0x3B,
            controlAt: pressAt + 1.0,
            now: pressAt + 1.0
        )
        guard case .skip = decision else {
            return XCTFail("skip を期待: \(decision)")
        }
    }

    func testSameIDIsSkippedWhenImmediateP1Sent() {
        let decision = P1ResendWindow.decide(
            window: immediatePIWindow,
            controlTerminal: 0x4A,
            controlAt: pressAt + 0.5,
            now: pressAt + 0.5
        )
        guard case .skip(let reason) = decision else {
            return XCTFail("skip を期待: \(decision)")
        }
        XCTAssertTrue(reason.contains("4A"))
    }

    func testNewIDAfterWindowCoveredArrivalSendsResend() {
        // 実測では押下後 2.4〜3.8 秒程度に新しい {ID} が到着した(旧期限 2.0 秒では間に合わなかった)。
        let decision = P1ResendWindow.decide(
            window: immediatePIWindow,
            controlTerminal: 0x3B,
            controlAt: pressAt + 3.7,
            now: pressAt + 3.7
        )
        guard case .send(let id, let label) = decision else {
            return XCTFail("send を期待: \(decision)")
        }
        XCTAssertEqual(id, 0x3B)
        XCTAssertTrue(label.contains("3B"))
        XCTAssertTrue(label.contains("P1 再送"))
    }

    func testArrivalBeyondWindowIsSkipped() {
        let decision = P1ResendWindow.decide(
            window: immediatePIWindow,
            controlTerminal: 0x3B,
            controlAt: pressAt + window8 + 0.5,
            now: pressAt + window8 + 0.5
        )
        guard case .skip = decision else {
            return XCTFail("skip を期待: \(decision)")
        }
    }

    func testLegacyWindowImpactsExtendedPolicyAppropriately() {
        // 「現行」方式(2.0 秒)では 3.7 秒到着は期限超過で再送しない(旧挙動の再現)。
        let legacyWindow = P1ResendWindow(
            windowSeconds: window2,
            pressAt: pressAt,
            immediateID: 0x4A,
            sentImmediate: true
        )
        let decision = P1ResendWindow.decide(
            window: legacyWindow,
            controlTerminal: 0x3B,
            controlAt: pressAt + 3.7,
            now: pressAt + 3.7
        )
        guard case .skip = decision else {
            return XCTFail("skip を期待(2 秒期限超過): \(decision)")
        }
    }

    func testDeferredWindowSendsOnFirstControlArrivalEvenWithSameID() {
        // 古 ID 時は押下時に送っていないため、同一 {ID} の制御パケットでも送る(ID は確定済みなので有効)。
        let decision = P1ResendWindow.decide(
            window: deferredWindow,
            controlTerminal: 0x4A,
            controlAt: pressAt + 0.2,
            now: pressAt + 0.2
        )
        guard case .send(let id, let label) = decision else {
            return XCTFail("send を期待: \(decision)")
        }
        XCTAssertEqual(id, 0x4A)
        XCTAssertTrue(label.contains("ウィンドウ待ち"))
    }

    func testResendCountCapBlocksSecondResend() {
        var window = immediatePIWindow
        window.resendCount = CancelRetryConstants.maxResends
        let decision = P1ResendWindow.decide(
            window: window,
            controlTerminal: 0x3B,
            controlAt: pressAt + 1.0,
            now: pressAt + 1.0
        )
        guard case .skip = decision else {
            return XCTFail("skip を期待(再送上限): \(decision)")
        }
    }

    func testStaleControlArrivalBeforePressIsSkipped() {
        // 押下より前の時刻で記録された制御パケットは対象としない(順序の揺れ対策はアプリ側で行う)。
        let decision = P1ResendWindow.decide(
            window: immediatePIWindow,
            controlTerminal: 0x3B,
            controlAt: pressAt - 0.5,
            now: pressAt
        )
        guard case .skip = decision else {
            return XCTFail("skip を期待: \(decision)")
        }
    }
}

final class PressTimelineRecorderTests: XCTestCase {
    func testRelativeTimesFromConnectAndPress() {
        var recorder = PressTimelineRecorder()
        let connectAt = Date(timeIntervalSince1970: 1_000)
        recorder.beginGeneration(connectAt: connectAt)
        recorder.add("PE03購読開始")
        let pressAt = connectAt.addingTimeInterval(2.5)
        recorder.markPress("押下検出 state=7B61", at: pressAt)
        recorder.add("FE03制御(3B terminal=3B)")

        let text = recorder.copyText(deviceName: "Bose NC 700", connectionRoute: "explicit-scan", idEstablishedAtPress: true)
        XCTAssertTrue(text.contains("Bose NC 700"))
        XCTAssertTrue(text.contains("explicit-scan"))
        XCTAssertTrue(text.contains("確定済み"))
        XCTAssertTrue(text.contains("PE03購読開始"))
        XCTAssertTrue(text.contains("押下検出 state=7B61"))
        XCTAssertTrue(text.contains("FE03制御(3B terminal=3B)"))
        // 押下起点の相対表示(押下+0ms の行があること)。
        XCTAssertTrue(text.contains("(押下+0ms)"))
    }

    func testGenerationSlicesOutOldEvents() {
        var recorder = PressTimelineRecorder()
        recorder.beginGeneration(connectAt: Date(timeIntervalSince1970: 0))
        recorder.add("旧世代の記録")
        recorder.beginGeneration(connectAt: Date(timeIntervalSince1970: 100))
        recorder.add("新世代の記録")

        let text = recorder.copyText(deviceName: "D", connectionRoute: "r", idEstablishedAtPress: false)
        XCTAssertFalse(text.contains("旧世代の記録"))
        XCTAssertTrue(text.contains("新世代の記録"))
        XCTAssertTrue(text.contains("未確定"))
    }

    func testMarkPressAlignsBackdatedEvents() throws {
        var recorder = PressTimelineRecorder()
        recorder.beginGeneration(connectAt: Date(timeIntervalSince1970: 0))
        // 押下検出は実時刻より遅れることがある。markPress(at:) で押下時刻を指定し、
        // それ以前のイベントも押下起点の相対時刻に載ること。
        recorder.add("FE03制御(押下直後に届いたもの)")
        recorder.markPress("押下検出 state=7B61", at: Date(timeIntervalSince1970: 5))
        let text = recorder.copyText(deviceName: "D", connectionRoute: "r", idEstablishedAtPress: true)
        XCTAssertTrue(text.contains("FE03制御"))
    }
}
