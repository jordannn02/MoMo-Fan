import Foundation
import XCTest
@testable import FanCore

final class ControlSafetyTests: XCTestCase {
    private func fan(_ id: Int = 0, target: Double = 2400, manual: Bool = true) -> FanReading {
        FanReading(id: id, name: "Fan \(id)", currentRPM: 2300, minimumRPM: 1200,
                   maximumRPM: 6200, targetRPM: target, isManual: manual)
    }

    private func sensor(_ temperature: Double, key: String = "CPU_MAX") -> SensorReading {
        SensorReading(key: key, name: key, group: "CPU", celsius: temperature)
    }

    private func reason(now: Double = 107, heartbeat: Double = 100, owner: Bool = true,
                        active: Bool = true, critical: Bool = false, sleeping: Bool = false) -> FanControlPolicy.RestoreReason? {
        FanControlPolicy.restorationReason(hasOwner: owner, hasActiveRules: active, now: now,
                                            lastHeartbeat: heartbeat, criticalThermalState: critical,
                                            powerSuspended: sleeping)
    }

    func testLeaseExpiresAtExactlyEightSeconds() {
        XCTAssertNil(reason(now: 107.999))
        XCTAssertEqual(reason(now: 108), .heartbeatExpired)
        XCTAssertEqual(reason(now: 108.001), .heartbeatExpired)
        XCTAssertNil(reason(now: 108, heartbeat: 108))
    }

    func testInvalidClockCannotExtendALease() {
        for value in [Double.nan, .infinity, -.infinity, 99] {
            XCTAssertEqual(reason(now: value), .invalidClock)
        }
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(reason(heartbeat: value), .invalidClock)
        }
    }

    func testCriticalSleepAndOrphanedOwnershipRequireRestoration() {
        XCTAssertEqual(reason(critical: true), .criticalThermalState)
        XCTAssertEqual(reason(sleeping: true), .systemSleep)
        XCTAssertEqual(reason(owner: false), .missingOwner)
        XCTAssertEqual(reason(active: false), .missingOwner)
        XCTAssertEqual(reason(now: 999, critical: true), .criticalThermalState)
    }

    func testIdleAndSleepingHelpersHaveNoPeriodicTimer() {
        XCTAssertFalse(FanControlPolicy.needsTimer(ownedFanIDs: [], powerSuspended: false))
        XCTAssertFalse(FanControlPolicy.needsTimer(ownedFanIDs: [0, 1], powerSuspended: true))
        // Failed restoration still needs retries after wake, even without an active rule.
        XCTAssertTrue(FanControlPolicy.needsTimer(ownedFanIDs: [1], powerSuspended: false))
    }

    func testSafetyFailureSkipsSnapshotAndSelectsRestoration() {
        let rule = FanRule(fanID: 0, mode: .fixed, rpm: 2400)
        for condition in ["critical", "sleep", "expired", "orphaned"] {
            var reads = 0
            let decision = FanControlPolicy.evaluateTick(
                rules: [rule], lastTargets: [0: 2400], hasOwner: condition != "orphaned",
                now: condition == "expired" ? 108 : 101, lastHeartbeat: 100,
                criticalThermalState: condition == "critical", powerSuspended: condition == "sleep"
            ) { _ in
                reads += 1
                return HardwareSnapshot(fans: [self.fan()], sensors: [])
            }
            guard case .restore = decision else { return XCTFail("Expected restoration for \(condition)") }
            XCTAssertEqual(reads, 0, condition)
        }
    }

    func testSnapshotIOFaultSelectsRestoration() {
        let decision = evaluate(rules: [FanRule(fanID: 0, mode: .fixed, rpm: 2400)]) { _ in
            throw FanError.hardware("injected SMC read failure")
        }
        guard case let .restore(message) = decision else { return XCTFail("I/O failure must restore") }
        XCTAssertTrue(message.contains("injected SMC read failure"))
    }

    func testFixedTickReadsNoTemperatureSensorsButStillChecksFanMode() {
        let rules = [FanRule(fanID: 0, mode: .fixed, rpm: 2400)]
        var requested: Set<String>?
        let healthy = evaluate(rules: rules) { keys in
            requested = keys
            return HardwareSnapshot(fans: [self.fan()], sensors: [])
        }
        guard case let .control(updates, temperatures) = healthy else { return XCTFail("Healthy fixed rule") }
        XCTAssertEqual(requested, [])
        XCTAssertTrue(updates.isEmpty)
        XCTAssertTrue(temperatures.isEmpty)
        let overridden = evaluate(rules: rules) { _ in
            HardwareSnapshot(fans: [self.fan(manual: false)], sensors: [])
        }
        guard case .restore = overridden else { return XCTFail("Automatic mode means ownership was lost") }
    }

    func testThermalTickUsesTheSameSamplesForTargetsAndDiagnostics() {
        let rules = [FanRule(fanID: 0, mode: .sensor, sensorKey: "CPU_MAX", lowerTemperature: 50, upperTemperature: 80)]
        let decision = evaluate(rules: rules) { keys in
            XCTAssertEqual(keys, ["CPU_MAX"])
            return HardwareSnapshot(fans: [self.fan()], sensors: [self.sensor(65), self.sensor(40, key: "Tp00")])
        }
        guard case let .control(updates, temperatures) = decision else { return XCTFail("Valid thermal control") }
        XCTAssertEqual(updates, [0: 3700])
        XCTAssertEqual(temperatures, ["CPU_MAX": 65])
    }

    func testMissingOrInvalidSelectedSensorSelectsRestoration() {
        let rules = [FanRule(fanID: 0, mode: .sensor, sensorKey: "CPU_MAX")]
        let samples: [[SensorReading]] = [[], [sensor(.nan)], [sensor(.infinity)], [sensor(0)], [sensor(130)]]
        for sensors in samples {
            let decision = evaluate(rules: rules) { _ in HardwareSnapshot(fans: [self.fan()], sensors: sensors) }
            guard case .restore = decision else { return XCTFail("Invalid selected sensor must restore") }
        }
    }

    func testInvalidFanTelemetrySelectsRestoration() {
        let rules = [FanRule(fanID: 0, mode: .fixed, rpm: 2400)]
        for badValue in [Double.nan, .infinity, -1, 20000] {
            var reading = fan()
            reading.currentRPM = badValue
            let decision = evaluate(rules: rules) { _ in HardwareSnapshot(fans: [reading], sensors: []) }
            guard case .restore = decision else { return XCTFail("Invalid current RPM: \(badValue)") }
        }
        var reading = fan()
        reading.maximumRPM = 20000
        let decision = evaluate(rules: rules) { _ in HardwareSnapshot(fans: [reading], sensors: []) }
        guard case .restore = decision else { return XCTFail("Invalid hardware bounds must restore") }
    }

    func testExternalTargetDriftBeyondTwoRPMSelectsRestoration() throws {
        let rules = [FanRule(fanID: 0, mode: .fixed, rpm: 2400)]
        XCTAssertTrue(try FanControlPolicy.updatesForTick(rules: rules,
            snapshot: HardwareSnapshot(fans: [fan(target: 2402)], sensors: []), lastTargets: [0: 2400]).isEmpty)
        for target in [2402.01, 2397.99, Double.nan] {
            let decision = evaluate(rules: rules) { _ in HardwareSnapshot(fans: [self.fan(target: target)], sensors: []) }
            guard case .restore = decision else { return XCTFail("External drift: \(target)") }
        }
        XCTAssertThrowsError(try FanControlPolicy.updatesForTick(rules: rules,
            snapshot: HardwareSnapshot(fans: [fan()], sensors: []), lastTargets: [:]))
    }

    func testSmallTargetChangesDoNotWriteUntilFiftyRPM() throws {
        let snapshot = HardwareSnapshot(fans: [fan()], sensors: [])
        for delta in [-49.0, 0, 49] {
            XCTAssertTrue(try FanControlPolicy.updatesForTick(
                rules: [FanRule(fanID: 0, mode: .fixed, rpm: 2400 + delta)],
                snapshot: snapshot, lastTargets: [0: 2400]).isEmpty)
        }
        for delta in [-50.0, 50] {
            XCTAssertEqual(try FanControlPolicy.updatesForTick(
                rules: [FanRule(fanID: 0, mode: .fixed, rpm: 2400 + delta)],
                snapshot: snapshot, lastTargets: [0: 2400]), [0: 2400 + delta])
        }
    }

    func testOneBadFanRejectsTheWholeControlPlanBeforeAnyWrite() {
        let rules = [FanRule(fanID: 0, mode: .fixed, rpm: 3000),
                     FanRule(fanID: 1, mode: .sensor, sensorKey: "missing")]
        let decision = FanControlPolicy.evaluateTick(
            rules: rules, lastTargets: [0: 2400, 1: 2400], hasOwner: true,
            now: 101, lastHeartbeat: 100, criticalThermalState: false, powerSuspended: false
        ) { _ in HardwareSnapshot(fans: [self.fan(), self.fan(1)], sensors: []) }
        guard case .restore = decision else { return XCTFail("Partial plan must not be returned") }
        XCTAssertThrowsError(try FanControlPolicy.targetsForApply(rules: rules,
            snapshot: HardwareSnapshot(fans: [fan(), fan(1)], sensors: [])))
    }

    func testApplyRejectsDuplicateMissingOrExtraFanIdentities() throws {
        let snapshot = HardwareSnapshot(fans: [fan(), fan(1)], sensors: [])
        let rule = FanRule(fanID: 0, mode: .fixed, rpm: 3000)
        for rules in [[], [rule], [rule, rule], [rule, FanRule(fanID: 2, mode: .automatic)]] {
            XCTAssertThrowsError(try FanControlPolicy.targetsForApply(rules: rules, snapshot: snapshot))
        }
        XCTAssertEqual(try FanControlPolicy.targetsForApply(
            rules: [rule, FanRule(fanID: 1, mode: .automatic)], snapshot: snapshot), [0: 3000])
    }

    func testDuplicateSensorIdentityFailsClosed() {
        XCTAssertThrowsError(try FanControlPolicy.sensorValues([sensor(45), sensor(85)]))
    }

    private func evaluate(rules: [FanRule], reader: (Set<String>) throws -> HardwareSnapshot) -> FanControlPolicy.TickDecision {
        FanControlPolicy.evaluateTick(rules: rules, lastTargets: [0: 2400], hasOwner: true,
                                       now: 101, lastHeartbeat: 100, criticalThermalState: false,
                                       powerSuspended: false, readSnapshot: reader)
    }
}

final class FanRecoveryTests: XCTestCase {
    func testPartialRestorationAttemptsEveryFanAndPersistsOnlyPendingIDs() throws {
        var attempts: [Int] = []
        let initial = try FanRecovery.decodeJournal(Data("[0,1,2]".utf8))
        let result = FanRecovery.restore(initial) { id in
            attempts.append(id)
            if id == 0 || id == 2 { throw FanError.hardware("Injected mode readback failure for \(id)") }
        }
        XCTAssertEqual(attempts, [0, 1, 2])
        XCTAssertEqual(result.remaining, [0, 2])
        XCTAssertEqual(result.failures.count, 2)
        let persisted = try JSONEncoder().encode(result.remaining.sorted())
        XCTAssertEqual(try FanRecovery.decodeJournal(persisted), [0, 2])

        attempts = []
        let retry = FanRecovery.restore(try FanRecovery.decodeJournal(persisted)) { attempts.append($0) }
        XCTAssertEqual(attempts, [0, 2])
        XCTAssertTrue(retry.remaining.isEmpty)
        XCTAssertTrue(retry.failures.isEmpty)
    }

    func testJournalCorruptionCannotBecomeAnEmptySuccessfulRecovery() throws {
        for json in ["", "null", "{broken", "{}", "[0,0]", "[-1]", "[10]", "[0.5]", "[\"0\"]"] {
            XCTAssertThrowsError(try FanRecovery.decodeJournal(Data(json.utf8)), json)
        }
        XCTAssertEqual(try FanRecovery.decodeJournal(Data("[]".utf8)), [])
        XCTAssertEqual(try FanRecovery.decodeJournal(Data("[0,9]".utf8)), [0, 9])
    }

    func testNoOwnedFansRequiresNoRestoreCalls() {
        var calls = 0
        let result = FanRecovery.restore([]) { _ in calls += 1 }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(result.remaining.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
    }
}
