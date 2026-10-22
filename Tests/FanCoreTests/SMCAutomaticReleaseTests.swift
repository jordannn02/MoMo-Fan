import XCTest
@testable import FanCore

final class SMCAutomaticReleaseTests: XCTestCase {
    func testModeWriteFailureWhileStillManualNeverClearsTargetAndRemainsPending() {
        var clears = 0, reads = 0, pauses = 0
        let recovery = FanRecovery.restore([0]) { id in
            try SMCAutomaticRelease.run(fanID: id,
                writeAutomatic: { throw FanError.hardware("injected mode write failure") },
                readMode: { reads += 1; return 1 },
                clearTarget: { clears += 1 }, pause: { pauses += 1 })
        }
        XCTAssertEqual(clears, 0)
        XCTAssertEqual(reads, 11)
        XCTAssertEqual(pauses, 10)
        XCTAssertEqual(recovery.remaining, [0])
        XCTAssertTrue(recovery.failures.first?.contains("injected mode write failure") == true)
        XCTAssertTrue(recovery.failures.first?.contains("自動模式讀回失敗") == true)
    }

    func testAcknowledgedModeWriteStillRequiresAutomaticReadbackBeforeClearing() {
        var clears = 0
        XCTAssertThrowsError(try SMCAutomaticRelease.run(fanID: 0, writeAutomatic: {},
            readMode: { 1 }, clearTarget: { clears += 1 }, pause: {}))
        XCTAssertEqual(clears, 0)
    }

    func testDelayedAutomaticReadbackPrecedesTargetClearWithoutRepeatingWrite() throws {
        var events: [String] = []
        var samples = [1.0, 1.0, 0.0, 3.0]
        try SMCAutomaticRelease.run(fanID: 0,
            writeAutomatic: { events.append("write-mode") },
            readMode: { let value = samples.removeFirst(); events.append("read-\(Int(value))"); return value },
            clearTarget: { events.append("clear-target") }, pause: { events.append("pause") })
        XCTAssertEqual(events, ["write-mode", "read-1", "pause", "read-1", "pause", "read-0", "clear-target", "read-3"])
        XCTAssertTrue(samples.isEmpty)
    }

    func testModeWriteErrorWithConfirmedAutomaticCanClearButCannotReportSuccess() {
        var clears = 0
        let recovery = FanRecovery.restore([0]) { id in
            try SMCAutomaticRelease.run(fanID: id,
                writeAutomatic: { throw FanError.hardware("injected write error") },
                readMode: { 0 }, clearTarget: { clears += 1 }, pause: {})
        }
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(recovery.remaining, [0])
        XCTAssertEqual(recovery.failures, ["injected write error"])
    }

    func testTargetClearFailureRemainsPendingAndVerifiesFinalMode() {
        var reads = 0, clears = 0
        let recovery = FanRecovery.restore([0]) { id in
            try SMCAutomaticRelease.run(fanID: id, writeAutomatic: {},
                readMode: { reads += 1; return 3 },
                clearTarget: { clears += 1; throw FanError.hardware("injected target clear failure") }, pause: {})
        }
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(recovery.remaining, [0])
        XCTAssertEqual(recovery.failures, ["injected target clear failure"])
    }

    func testModeReadFailureNeverClearsTargetOrRetriesFailedIO() {
        var reads = 0, clears = 0, pauses = 0
        XCTAssertThrowsError(try SMCAutomaticRelease.run(fanID: 0, writeAutomatic: {},
            readMode: { reads += 1; throw FanError.hardware("injected read failure") },
            clearTarget: { clears += 1 }, pause: { pauses += 1 }))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(clears, 0)
        XCTAssertEqual(pauses, 0)
    }

    func testUnrecognizedAndNonFiniteModesNeverPermitTargetClear() {
        for mode in [2.0, 4.0, -1, Double.nan, .infinity] {
            var clears = 0
            XCTAssertThrowsError(try SMCAutomaticRelease.run(fanID: 0, writeAutomatic: {},
                readMode: { mode }, clearTarget: { clears += 1 }, pause: {}))
            XCTAssertEqual(clears, 0, "Mode: \(mode)")
        }
    }

    func testBothConfirmedAutomaticModesAllowClearAndCompleteRecovery() {
        for mode in [0.0, 3.0] {
            var clears = 0
            let recovery = FanRecovery.restore([0]) { id in
                try SMCAutomaticRelease.run(fanID: id, writeAutomatic: {},
                    readMode: { mode }, clearTarget: { clears += 1 }, pause: {})
            }
            XCTAssertEqual(clears, 1)
            XCTAssertTrue(recovery.remaining.isEmpty)
            XCTAssertTrue(recovery.failures.isEmpty)
        }
    }

    func testModeReturningToManualAfterClearCannotReportSuccessfulRecovery() {
        var reads = 0, clears = 0
        let recovery = FanRecovery.restore([0]) { id in
            try SMCAutomaticRelease.run(fanID: id, writeAutomatic: {},
                readMode: { reads += 1; return reads == 1 ? 0 : 1 },
                clearTarget: { clears += 1 }, pause: {})
        }
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(reads, 12)
        XCTAssertEqual(recovery.remaining, [0])
        XCTAssertFalse(recovery.failures.isEmpty)
    }
}
