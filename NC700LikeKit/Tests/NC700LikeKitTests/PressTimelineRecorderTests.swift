import XCTest
@testable import NC700LikeKit

final class PressTimelineRecorderTests: XCTestCase {
    private func copyText(
        _ recorder: PressTimelineRecorder,
        terminal: String? = "5E"
    ) -> String {
        recorder.copyText(deviceName: "Bose NC 700", connectionRoute: "explicit-scan", terminalAtPress: terminal)
    }

    func testRelativeTimesFromConnectAndPress() {
        let recorder = PressTimelineRecorder()
        let connectAt = Date(timeIntervalSince1970: 1_000)
        recorder.beginGeneration(connectAt: connectAt)
        recorder.add("FE03購読開始")
        let pressAt = connectAt.addingTimeInterval(2.5)
        recorder.markPress("押下検出 state=7B61", at: pressAt)
        recorder.add("FE03制御(3B terminal=3B)")

        let text = copyText(recorder)
        XCTAssertTrue(text.contains("Bose NC 700"))
        XCTAssertTrue(text.contains("explicit-scan"))
        XCTAssertTrue(text.contains("押下時の直近制御terminal: 5E"))
        XCTAssertTrue(text.contains("FE03購読開始"))
        XCTAssertTrue(text.contains("押下検出 state=7B61"))
        XCTAssertTrue(text.contains("FE03制御(3B terminal=3B)"))
        // 押下起点の相対表示(押下+0ms の行があること)。
        XCTAssertTrue(text.contains("(押下+0ms)"))
    }

    func testGenerationSlicesOutOldEvents() {
        let recorder = PressTimelineRecorder()
        recorder.beginGeneration(connectAt: Date(timeIntervalSince1970: 0))
        recorder.add("旧世代の記録")
        recorder.beginGeneration(connectAt: Date(timeIntervalSince1970: 100))
        recorder.add("新世代の記録")

        let text = copyText(recorder, terminal: nil)
        XCTAssertTrue(text.contains("直近の押下なし"))
        XCTAssertTrue(text.contains("押下時の直近制御terminal: なし"))
        // 押下が登録されると、押下起点以降のイベントが出力される。
        recorder.markPress("押下検出", at: Date(timeIntervalSince1970: 200))
        let textWithPress = recorder.copyText(deviceName: "D", connectionRoute: "r", terminalAtPress: nil)
        XCTAssertFalse(textWithPress.contains("旧世代の記録"))
        XCTAssertTrue(textWithPress.contains("新世代の記録"))
    }

    func testMarkPressAlignsBackdatedEvents() {
        let recorder = PressTimelineRecorder()
        recorder.beginGeneration(connectAt: Date(timeIntervalSince1970: 0))
        // 押下検出は実時刻より遅れることがある。markPress(at:) で押下時刻を指定し、
        // それ以前のイベントも押下起点の相対時刻に載ること。
        recorder.add("FE03制御(押下直後に届いたもの)")
        recorder.markPress("押下検出 state=7B61", at: Date(timeIntervalSince1970: 5))
        let text = copyText(recorder)
        XCTAssertTrue(text.contains("FE03制御"))
    }

    func testWritesAndResponsesAreNumberedAndPaired() {
        let recorder = PressTimelineRecorder()
        let connectAt = Date(timeIntervalSince1970: 0)
        recorder.beginGeneration(connectAt: connectAt)
        let pressAt = connectAt.addingTimeInterval(2)
        recorder.markPress("押下検出 state=10 0E", at: pressAt)
        recorder.addWrite("P3 送信(7B)", seq: 1, date: pressAt.addingTimeInterval(0.016))
        recorder.addResponse(toWriteSeq: 1, label: "書込完了:成功", date: pressAt.addingTimeInterval(0.029))
        recorder.add("FE03制御(12B terminal=01)")

        let text = copyText(recorder)
        XCTAssertTrue(text.contains("書込#1 P3 送信(7B)"))
        XCTAssertTrue(text.contains("書込#1への応答(+13ms) 書込完了:成功"))
        // 集計ブロック: 書込→応答 pair と音声の有無
        XCTAssertTrue(text.contains("書込#1: P3 送信(7B)(押下+16ms) 応答: 書込完了:成功 +13ms"))
        XCTAssertTrue(text.contains("音声: なし"))
    }

    func testSummaryCountsAudioSpan() {
        let recorder = PressTimelineRecorder()
        recorder.beginGeneration(connectAt: Date(timeIntervalSince1970: 0))
        let pressAt = Date(timeIntervalSince1970: 10)
        recorder.markPress("押下検出", at: pressAt)
        recorder.add("FE03音声(232B)") // now() = 実時刻で十分後
        let text = copyText(recorder)
        XCTAssertTrue(text.contains("音声: 押下+"))
        XCTAssertTrue(text.contains("1件"))
    }
}
