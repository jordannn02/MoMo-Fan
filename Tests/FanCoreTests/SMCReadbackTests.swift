import XCTest
@testable import FanCore

final class SMCReadbackTests: XCTestCase {
    func testAllowsDelayedFirmwareReadbackWithoutFurtherWrites() throws {
        var reads = 0, pauses = 0
        XCTAssertTrue(try SMCReadback.wait(pause: { pauses += 1 }) {
            reads += 1
            return reads == 4
        })
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(pauses, 3)
    }

    func testPermanentMismatchTerminatesWithinBound() throws {
        var reads = 0, pauses = 0
        XCTAssertFalse(try SMCReadback.wait(pause: { pauses += 1 }) {
            reads += 1
            return false
        })
        XCTAssertEqual(reads, 21)
        XCTAssertEqual(pauses, 20)
    }

    func testIOFailureIsNotHiddenByRetrying() {
        var reads = 0, pauses = 0
        XCTAssertThrowsError(try SMCReadback.wait(pause: { pauses += 1 }) {
            reads += 1
            throw FanError.hardware("read failed")
        })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(pauses, 0)
    }

    func testImmediateConfirmationDoesNotWait() throws {
        var pauses = 0
        XCTAssertTrue(try SMCReadback.wait(pause: { pauses += 1 }) { true })
        XCTAssertEqual(pauses, 0)
    }
}
