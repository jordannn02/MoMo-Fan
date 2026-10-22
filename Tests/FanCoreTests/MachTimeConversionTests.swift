import XCTest
@testable import FanCore

final class MachTimeConversionTests: XCTestCase {
    func testAppleSilicon125Over3TimebaseProducesNanoseconds() {
        XCTAssertEqual(MachTimeConversion.nanoseconds(ticks: 24_000_000, numerator: 125, denominator: 3), 1_000_000_000)
        XCTAssertEqual(MachTimeConversion.nanoseconds(ticks: 0, numerator: 125, denominator: 3), 0)
    }

    func testFractionalNanosecondsTruncateOnlyAfterMultiplication() {
        XCTAssertEqual(MachTimeConversion.nanoseconds(ticks: 1, numerator: 125, denominator: 3), 41)
        XCTAssertEqual(MachTimeConversion.nanoseconds(ticks: 2, numerator: 125, denominator: 3), 83)
        XCTAssertEqual(MachTimeConversion.nanoseconds(ticks: 3, numerator: 125, denominator: 3), 125)
    }

    func testIdentityTimebasePreservesFullIntegerPrecision() {
        XCTAssertEqual(MachTimeConversion.nanoseconds(ticks: UInt64.max, numerator: 1, denominator: 1), UInt64.max)
        XCTAssertEqual(MachTimeConversion.nanoseconds(ticks: 9_007_199_254_740_993, numerator: 1, denominator: 1), 9_007_199_254_740_993)
    }

    func testWideIntermediateProductCanStillProduceRepresentableResult() {
        XCTAssertEqual(MachTimeConversion.nanoseconds(ticks: UInt64.max, numerator: 3, denominator: 3), UInt64.max)
    }

    func testUnrepresentableResultAndInvalidTimebaseReturnNoReading() {
        XCTAssertNil(MachTimeConversion.nanoseconds(ticks: UInt64.max, numerator: 125, denominator: 3))
        XCTAssertNil(MachTimeConversion.nanoseconds(ticks: 10, numerator: 1, denominator: 0))
        XCTAssertNil(MachTimeConversion.nanoseconds(ticks: 10, numerator: 0, denominator: 1))
    }

    func testAppleSiliconTimebaseAtUInt64NanosecondBoundary() {
        let lastRepresentableTick: UInt64 = 442_721_857_769_029_238
        XCTAssertEqual(MachTimeConversion.nanoseconds(ticks: lastRepresentableTick, numerator: 125, denominator: 3),
                       18_446_744_073_709_551_583)
        XCTAssertNil(MachTimeConversion.nanoseconds(ticks: lastRepresentableTick + 1, numerator: 125, denominator: 3))
    }
}
