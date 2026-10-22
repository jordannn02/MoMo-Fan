import Foundation
import FanCore
import Darwin

/// A separate command-line acceptance path. No hardware writes occur unless control is true.
@MainActor enum Verification {
    private static var session: VerificationSession?

    static func run(control: Bool) {
        guard session == nil else { return }
        let session = VerificationSession(control: control)
        self.session = session
        session.start()
    }
}

private struct VerificationFanResult: Codable {
    var fanID: Int
    var initialRPM: Double
    var requestedRPM: Double
    var observedRPM: Double
    var observedTargetRPM: Double
    var rpmIncrease: Double
    var isManual: Bool
    var targetMatches: Bool
    var currentRPMIncreased: Bool
}

private struct VerificationReport: Codable {
    var schemaVersion = 1
    var mode: String
    var success = false
    var startedAt = Date()
    var completedAt: Date?
    var elapsedSeconds: Double?
    var observationDelaySeconds = 5
    var targetToleranceRPM = 2.0
    var minimumRequiredRPMIncrease = 100.0
    var helperStatus: HelperResponse?
    var applyResponse: HelperResponse?
    var restoreResponse: HelperResponse?
    var initialSnapshot: HardwareSnapshot?
    var observedSnapshot: HardwareSnapshot?
    var restoredSnapshot: HardwareSnapshot?
    var requestedRules: [FanRule] = []
    var fanResults: [VerificationFanResult] = []
    var successfulHeartbeats = 0
    var applyAttempted = false
    var restorationRequested = false
    var restorationVerified = false
    var connectionInvalidatedForFailSafe = false
    var errors: [String] = []
}

@MainActor private final class VerificationSession {
    private enum Phase { case status, preflight, applying, observing, restoring, checkingRestoration, finished }
    private let control: Bool
    private let helper = HelperClient()
    private let readQueue = DispatchQueue(label: "tw.momo.MoMoFan.verification.read", qos: .utility)
    private let startUptime = ProcessInfo.processInfo.systemUptime
    private var phase: Phase = .status
    private var heartbeat: Timer?
    private var heartbeatPending = false
    private var report: VerificationReport

    init(control: Bool) {
        self.control = control
        report = VerificationReport(mode: control ? "control" : "status")
    }

    func start() {
        // Leave time for the automatic request and a separate hardware read before the hard limit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [self] in
            guard phase != .finished else { return }
            fail("驗收超過 20 秒，已停止控制驗收。")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 27) { [self] in
            guard phase != .finished else { return }
            report.errors.append("27 秒期限已到；無法宣稱已完成硬體復原回讀。")
            invalidateForFailSafe()
            finish()
        }
        helper.send(HelperRequest(.status)) { [self] result in
            guard phase == .status else { return }
            switch result {
            case .failure(let error): fail("控制服務狀態：\(error.localizedDescription)")
            case .success(let response):
                report.helperStatus = response
                guard response.success else { fail(response.message); return }
                guard control else { report.success = true; finish(); return }
                guard response.activeRules.isEmpty, response.pendingRestoreFanIDs.isEmpty else {
                    fail("控制服務已有使用中的規則或待復原風扇，未開始驗收。")
                    return
                }
                phase = .preflight
                readSnapshot { [self] result in
                    guard phase == .preflight else { return }
                    do {
                        let snapshot = try result.get()
                        report.initialSnapshot = snapshot
                        try validateHealth(snapshot)
                        guard snapshot.fans.allSatisfy({ !$0.isManual }) else {
                            throw FanError.invalid("初始風扇並非全部系統自動，未變更既有控制。")
                        }
                        report.requestedRules = snapshot.fans.map { fan in
                            let baseline = max(fan.currentRPM, max(fan.targetRPM, fan.minimumRPM))
                            return FanRule(fanID: fan.id, mode: .fixed, rpm: min(fan.maximumRPM, baseline + 400))
                        }
                        for rule in report.requestedRules {
                            guard let fan = snapshot.fans.first(where: { $0.id == rule.fanID }) else {
                                throw FanError.invalid("初始風扇識別碼不一致。")
                            }
                            try rule.validate(for: fan, sensorKeys: Set(snapshot.sensors.map(\.key)))
                        }
                        apply()
                    } catch { fail("驗收前檢查：\(error.localizedDescription)") }
                }
            }
        }
    }

    private func apply() {
        phase = .applying
        report.applyAttempted = true
        helper.send(HelperRequest(.apply, rules: report.requestedRules)) { [self] result in
            guard phase == .applying else { return }
            switch result {
            case .failure(let error):
                invalidateForFailSafe()
                fail("套用要求：\(error.localizedDescription)")
            case .success(let response):
                report.applyResponse = response
                guard response.success, response.activeRules == report.requestedRules,
                      response.pendingRestoreFanIDs.isEmpty else {
                    fail("控制服務未確認完整套用：\(response.message)")
                    return
                }
                phase = .observing
                heartbeat = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.sendHeartbeat() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in observe() }
            }
        }
    }

    private func sendHeartbeat() {
        guard phase == .observing, !heartbeatPending else { return }
        heartbeatPending = true
        helper.send(HelperRequest(.heartbeat)) { [self] result in
            heartbeatPending = false
            guard phase == .observing else { return }
            switch result {
            case .failure(let error):
                invalidateForFailSafe()
                fail("驗收心跳：\(error.localizedDescription)")
            case .success(let response):
                guard response.success, response.activeRules == report.requestedRules,
                      response.pendingRestoreFanIDs.isEmpty else {
                    fail("驗收期間控制已停止：\(response.message)")
                    return
                }
                report.successfulHeartbeats += 1
            }
        }
    }

    private func observe() {
        guard phase == .observing else { return }
        readSnapshot { [self] result in
            guard phase == .observing else { return }
            do {
                let snapshot = try result.get()
                report.observedSnapshot = snapshot
                try validateHealth(snapshot)
                guard let initial = report.initialSnapshot,
                      Set(snapshot.fans.map(\.id)) == Set(initial.fans.map(\.id)) else {
                    throw FanError.hardware("驗收期間風扇清單已變更。")
                }
                for rule in report.requestedRules {
                    guard let before = initial.fans.first(where: { $0.id == rule.fanID }),
                          let after = snapshot.fans.first(where: { $0.id == rule.fanID }) else {
                        throw FanError.hardware("無法比對風扇回讀。")
                    }
                    let targetMatches = abs(after.targetRPM - rule.rpm) <= report.targetToleranceRPM
                    let increased = after.currentRPM - before.currentRPM >= report.minimumRequiredRPMIncrease
                    report.fanResults.append(VerificationFanResult(
                        fanID: rule.fanID, initialRPM: before.currentRPM, requestedRPM: rule.rpm,
                        observedRPM: after.currentRPM, observedTargetRPM: after.targetRPM,
                        rpmIncrease: after.currentRPM - before.currentRPM, isManual: after.isManual,
                        targetMatches: targetMatches, currentRPMIncreased: increased))
                    if !after.isManual || !targetMatches || !increased {
                        report.errors.append("風扇 \(rule.fanID + 1) 未同時通過手動模式、目標轉速回讀與實際 RPM 上升檢查。")
                    }
                }
                if report.successfulHeartbeats == 0 { report.errors.append("未確認任何驗收心跳成功。") }
                restore()
            } catch { fail("加速後獨立回讀：\(error.localizedDescription)") }
        }
    }

    private func fail(_ message: String) {
        guard phase != .finished else { return }
        report.errors.append(message)
        if report.applyAttempted { restore() }
        else { finish() } // A failed preflight must not reset another tool's existing manual control.
    }

    private func restore() {
        guard phase != .restoring, phase != .checkingRestoration, phase != .finished else { return }
        phase = .restoring
        heartbeat?.invalidate(); heartbeat = nil
        report.restorationRequested = true
        helper.send(HelperRequest(.automatic)) { [self] result in
            guard phase == .restoring else { return }
            var settleDelay = 0.0
            switch result {
            case .failure(let error):
                report.errors.append("回復自動要求：\(error.localizedDescription)")
                invalidateForFailSafe()
                settleDelay = 0.5
            case .success(let response):
                report.restoreResponse = response
                if !response.success || !response.activeRules.isEmpty || !response.pendingRestoreFanIDs.isEmpty {
                    report.errors.append("控制服務尚未確認復原完成：\(response.message)")
                    invalidateForFailSafe()
                    settleDelay = 0.5
                }
            }
            phase = .checkingRestoration
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [self] in
                guard phase == .checkingRestoration else { return }
                readSnapshot { [self] result in
                    guard phase == .checkingRestoration else { return }
                    do {
                        let snapshot = try result.get()
                        report.restoredSnapshot = snapshot
                        // Sensor/thermal failure can trigger recovery; fan modes can still prove recovery succeeded.
                        try validateFanReadings(snapshot)
                        let expected = Set(report.requestedRules.map(\.fanID))
                        report.restorationVerified = Set(snapshot.fans.map(\.id)) == expected
                            && snapshot.fans.allSatisfy { !$0.isManual }
                        if !report.restorationVerified { report.errors.append("獨立回讀尚未確認全部風扇恢復自動。") }
                    } catch { report.errors.append("復原後獨立回讀：\(error.localizedDescription)") }
                    finish()
                }
            }
        }
    }

    private func validateHealth(_ snapshot: HardwareSnapshot) throws {
        try validateFanReadings(snapshot)
        guard !snapshot.sensors.isEmpty,
              snapshot.sensors.allSatisfy({ $0.celsius.isFinite && $0.celsius > 0 && $0.celsius < 130 }),
              ProcessInfo.processInfo.thermalState != .critical else {
            throw FanError.hardware("風扇／感測器清單或系統熱狀態不適合驗收。")
        }
    }

    private func validateFanReadings(_ snapshot: HardwareSnapshot) throws {
        guard !snapshot.fans.isEmpty, snapshot.fans.count <= 10,
              Set(snapshot.fans.map(\.id)).count == snapshot.fans.count else {
            throw FanError.hardware("風扇清單無效。")
        }
        for fan in snapshot.fans {
            guard [fan.currentRPM, fan.targetRPM].allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 20000 }) else {
                throw FanError.hardware("風扇讀值無效。")
            }
            try FanRule(fanID: fan.id).validate(for: fan, sensorKeys: [])
        }
    }

    private func readSnapshot(_ completion: @escaping @MainActor (Result<HardwareSnapshot, Error>) -> Void) {
        readQueue.async {
            let result: Result<HardwareSnapshot, Error>
            do {
                // Open an independent read-only connection for each observation.
                let smc = try SMCClient()
                result = .success(try smc.snapshot())
            } catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func invalidateForFailSafe() {
        report.connectionInvalidatedForFailSafe = true
        helper.invalidate()
    }

    private func finish() {
        guard phase != .finished else { return }
        phase = .finished
        heartbeat?.invalidate(); heartbeat = nil
        helper.invalidate()
        if control {
            report.success = report.errors.isEmpty && report.restorationVerified
                && !report.fanResults.isEmpty
                && report.fanResults.allSatisfy { $0.isManual && $0.targetMatches && $0.currentRPMIncreased }
        }
        report.completedAt = Date()
        report.elapsedSeconds = ProcessInfo.processInfo.systemUptime - startUptime
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(report)
            data.append(0x0a)
            FileHandle.standardOutput.write(data)
        } catch {
            FileHandle.standardOutput.write(Data("{\"success\":false,\"errors\":[\"驗收結果 JSON 編碼失敗\"]}\n".utf8))
            exit(1)
        }
        exit(report.success ? 0 : 1)
    }
}
