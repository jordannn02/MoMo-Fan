import Foundation
import XCTest
@testable import FanCore

final class FanCoreTests: XCTestCase {
    private let sensorKey = "CPU_MAX"

    private func fan(id: Int = 0, minimum: Double = 1200, maximum: Double = 6200) -> FanReading {
        FanReading(id: id, name: "Left fan", currentRPM: 2400,
                   minimumRPM: minimum, maximumRPM: maximum,
                   targetRPM: 2400, isManual: false)
    }

    private func sensorRule(lower: Double = 50, upper: Double = 80) -> FanRule {
        FanRule(fanID: 0, mode: .sensor, sensorKey: sensorKey,
                lowerTemperature: lower, upperTemperature: upper)
    }

    func testAutomaticModeDoesNotProduceAManualTarget() throws {
        let rule = FanRule(fanID: 0, mode: .automatic)
        try rule.validate(for: fan(), sensorKeys: [])
        XCTAssertNil(try rule.target(for: fan(), temperature: nil))
    }

    func testFixedModeAcceptsBothHardwareEndpoints() throws {
        for rpm in [1200.0, 6200.0] {
            let rule = FanRule(fanID: 0, mode: .fixed, rpm: rpm)
            try rule.validate(for: fan(), sensorKeys: [])
            XCTAssertEqual(try rule.target(for: fan(), temperature: nil), rpm)
        }
    }

    func testFixedModeRejectsOutOfRangeAndNonFiniteRPM() {
        let invalidRPMs: [Double] = [-1, 1199.99, 6200.01, .nan, .infinity, -.infinity]
        for rpm in invalidRPMs {
            let rule = FanRule(fanID: 0, mode: .fixed, rpm: rpm)
            XCTAssertThrowsError(try rule.validate(for: fan(), sensorKeys: []), "RPM: \(rpm)")
        }
    }

    func testFixedTargetClampsFiniteValuesToHardwareRange() throws {
        // Validation rejects these inputs; the target calculation also bounds a finite value.
        XCTAssertEqual(try FanRule(fanID: 0, mode: .fixed, rpm: 500)
            .target(for: fan(), temperature: nil), 1200)
        XCTAssertEqual(try FanRule(fanID: 0, mode: .fixed, rpm: 9000)
            .target(for: fan(), temperature: nil), 6200)
    }

    func testTargetIndependentlyRejectsNonFiniteRPMAndInvalidHardware() {
        for rpm in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try FanRule(fanID: 0, mode: .fixed, rpm: rpm)
                .target(for: fan(), temperature: nil))
        }
        for mode in FanMode.allCases {
            let rule = FanRule(fanID: 0, mode: mode, sensorKey: sensorKey)
            XCTAssertThrowsError(try rule.target(for: fan(minimum: .nan), temperature: 65))
            XCTAssertThrowsError(try rule.target(for: fan(maximum: 20000), temperature: 65))
            XCTAssertThrowsError(try rule.target(for: fan(id: 1), temperature: 65))
        }
    }

    func testSensorCurveHasCorrectEndpointsMidpointAndSaturation() throws {
        let rule = sensorRule()
        try rule.validate(for: fan(), sensorKeys: [sensorKey])
        let cases: [(temperature: Double, rpm: Double)] = [
            (20, 1200), (50, 1200), (65, 3700), (80, 6200), (100, 6200)
        ]
        for sample in cases {
            XCTAssertEqual(try rule.target(for: fan(), temperature: sample.temperature),
                           sample.rpm, "Temperature: \(sample.temperature)")
        }
    }

    func testSensorCurveRoundsToWholeRPM() throws {
        XCTAssertEqual(try sensorRule().target(for: fan(), temperature: 61.234), 3072)
    }

    func testSensorRoundingNeverCrossesFractionalHardwareEndpoints() throws {
        let reading = fan(minimum: 1200.25, maximum: 6200.75)
        XCTAssertEqual(try sensorRule().target(for: reading, temperature: 20), 1200.25)
        XCTAssertEqual(try sensorRule().target(for: reading, temperature: 100), 6200.75)
    }

    func testSensorTargetRejectsMissingNonFiniteAndInvalidReadings() {
        let invalidTemperatures: [Double?] = [nil, .nan, .infinity, -.infinity, -1, 0, 130, 150]
        for temperature in invalidTemperatures {
            XCTAssertThrowsError(try sensorRule().target(for: fan(), temperature: temperature),
                                 "Temperature: \(String(describing: temperature))")
        }
    }

    func testSensorRuleRejectsAnUnavailableSensor() {
        XCTAssertThrowsError(try sensorRule().validate(for: fan(), sensorKeys: []))
        XCTAssertThrowsError(try sensorRule().validate(for: fan(), sensorKeys: ["GPU_MAX"]))
    }

    func testSensorThresholdsAcceptFiveDegreeGapAndTemperatureLimits() throws {
        for (lower, upper) in [(20.0, 25.0), (90.0, 95.0), (20.0, 95.0)] {
            try sensorRule(lower: lower, upper: upper).validate(for: fan(), sensorKeys: [sensorKey])
        }
    }

    func testSensorThresholdsRejectShortGapReversalAndOutOfRangeValues() {
        let invalidThresholds: [(Double, Double)] = [
            (50, 54.99), (50, 50), (80, 50), (19.99, 80), (50, 95.01),
            (.nan, 80), (50, .nan), (.infinity, 80), (-.infinity, 80),
            (50, .infinity), (50, -.infinity)
        ]
        for (lower, upper) in invalidThresholds {
            XCTAssertThrowsError(try sensorRule(lower: lower, upper: upper)
                .validate(for: fan(), sensorKeys: [sensorKey]), "Thresholds: \(lower), \(upper)")
        }
    }

    func testSensorTargetRejectsEqualOrReversedThresholds() {
        for (lower, upper) in [(50.0, 50.0), (80.0, 50.0), (50, 54.99), (.nan, 80), (50, .infinity)] {
            XCTAssertThrowsError(try sensorRule(lower: lower, upper: upper)
                .target(for: fan(), temperature: 65))
        }
    }

    func testEveryModeRejectsMismatchedFanIdentity() {
        for mode in FanMode.allCases {
            let rule = FanRule(fanID: 1, mode: mode, sensorKey: sensorKey)
            XCTAssertThrowsError(try rule.validate(for: fan(id: 0), sensorKeys: [sensorKey]),
                                 "Mode: \(mode)")
        }
    }

    func testEveryModeRejectsInvalidHardwareRanges() {
        let ranges: [(minimum: Double, maximum: Double)] = [
            (.nan, 6200), (.infinity, 6200), (-.infinity, 6200), (-1, 6200),
            (1200, .nan), (1200, .infinity), (1200, -.infinity),
            (1200, 1200), (6200, 1200), (1200, 20000)
        ]
        for mode in FanMode.allCases {
            let rule = FanRule(fanID: 0, mode: mode, sensorKey: sensorKey)
            for range in ranges {
                XCTAssertThrowsError(try rule.validate(
                    for: fan(minimum: range.minimum, maximum: range.maximum),
                    sensorKeys: [sensorKey]),
                    "Mode: \(mode), range: \(range.minimum)...\(range.maximum)")
            }
        }
    }

    func testHardwareRangeAllowsZeroMinimumWhenReportedByHardware() throws {
        let hardware = fan(minimum: 0, maximum: 6200)
        let rule = FanRule(fanID: 0, mode: .fixed, rpm: 0)
        try rule.validate(for: hardware, sensorKeys: [])
        XCTAssertEqual(try rule.target(for: hardware, temperature: nil), 0)
    }

    func testCustomPresetsRoundTripWithoutLosingControlSettings() throws {
        let presets = [FanPreset(
            id: UUID(uuidString: "8BCABABC-92F9-45D9-80C5-F190E35ABC70")!,
            name: "工作與剪輯・自訂",
            rules: [
                FanRule(fanID: 0, mode: .automatic),
                FanRule(fanID: 1, mode: .fixed, rpm: 3456, sensorKey: "GPU_MAX"),
                FanRule(fanID: 2, mode: .sensor, rpm: 4567, sensorKey: "TC0P",
                        lowerTemperature: 42.5, upperTemperature: 83.5)
            ])]
        let encoded = try JSONEncoder().encode(presets)
        let decoded = try JSONDecoder().decode([FanPreset].self, from: encoded)
        XCTAssertEqual(decoded, presets)
    }

    func testJSONRejectsUnknownFanMode() {
        let json = Data("""
        {"fanID":0,"mode":"unrestricted","rpm":3000,"sensorKey":"CPU_MAX","lowerTemperature":50,"upperTemperature":80}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FanRule.self, from: json))
    }

    func testHelperResponsePreservesPendingRestorationSeparatelyFromActiveRules() throws {
        let response = HelperResponse(success: true, message: "回復仍待重試", activeRules: [],
                                      pendingRestoreFanIDs: [0, 1])
        let encoded = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: encoded)
        XCTAssertTrue(decoded.activeRules.isEmpty)
        XCTAssertEqual(decoded.pendingRestoreFanIDs, [0, 1])
        XCTAssertEqual(decoded.message, response.message)
    }

    func testHelperResponseCanDecodeAResponseWithoutOptionalDiagnostics() throws {
        let json = Data("""
        {"success":true,"message":"automatic","activeRules":[],"pendingRestoreFanIDs":[]}
        """.utf8)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: json)
        XCTAssertNil(decoded.diagnostics)
    }

    func testDiagnosticsRoundTripPreservesThermalAndResourceEvidence() throws {
        var diagnostics = HelperDiagnostics(helperPID: 123, buildIdentifier: "1.0.2-qc1")
        diagnostics.lastTargets = [0: 3700]
        diagnostics.lastTemperatures = ["CPU_MAX": 65]
        diagnostics.controlTickCount = 4
        diagnostics.timerTargetUpdateCount = 2
        diagnostics.sleepCount = 1
        diagnostics.resources = HelperResourceUsage(userTimeNanoseconds: 123456789012,
            systemTimeNanoseconds: 876543210987, interruptWakeups: 3, packageIdleWakeups: 4,
            physicalFootprintBytes: 5000000, diskBytesRead: 1024, diskBytesWritten: 2048)
        let response = HelperResponse(success: true, message: "diagnostics", diagnostics: diagnostics)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: JSONEncoder().encode(response))
        let evidence = try XCTUnwrap(decoded.diagnostics)
        XCTAssertEqual(evidence.lastTargets, [0: 3700])
        XCTAssertEqual(evidence.lastTemperatures, ["CPU_MAX": 65])
        XCTAssertEqual(evidence.controlTickCount, 4)
        XCTAssertEqual(evidence.timerTargetUpdateCount, 2)
        XCTAssertEqual(evidence.sleepCount, 1)
        XCTAssertEqual(evidence.resources?.userTimeNanoseconds, 123456789012)
        XCTAssertEqual(evidence.resources?.diskBytesWritten, 2048)
    }
}
