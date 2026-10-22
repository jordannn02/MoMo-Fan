import AppKit
import Foundation
import FanCore
import Darwin

/// Explicit, signed-user-CLI acceptance paths. This file never writes SMC keys directly.
/// All control goes through the approved helper; independent SMC connections only read.
@MainActor enum AcceptanceVerification {
    nonisolated static let switches: Set<String> = [
        "--verify-thermal", "--verify-lease", "--verify-disconnect",
        "--verify-sleep", "--verify-crash-owner"
    ]
    private static var session: AcceptanceSession?

    /// The caller must run RunLoop.main, as with the existing Verification entry point.
    static func run(arguments: [String]) {
        guard session == nil else { return }
        do {
            let options = try AcceptanceOptions(arguments)
            let instance = AcceptanceSession(options: options)
            session = instance
            instance.start()
        } catch {
            let failure = AcceptanceArgumentFailure(success: false, errors: [error.localizedDescription])
            let data = (try? JSONEncoder().encode(failure)) ?? Data("{\"success\":false}".utf8)
            FileHandle.standardOutput.write(data + Data([0x0a]))
            exit(2)
        }
    }
}

private struct AcceptanceArgumentFailure: Codable {
    var success: Bool
    var errors: [String]
}

private enum AcceptanceMode: String, Codable {
    case thermal, lease, disconnect, sleep, crashOwner = "crash-owner"
    var limit: Double {
        switch self {
        case .thermal: return 48
        case .lease: return 24
        case .disconnect: return 18
        case .sleep: return 180
        case .crashOwner: return 90
        }
    }
    var keepsHeartbeat: Bool { self == .thermal || self == .sleep || self == .crashOwner }
}

private struct AcceptanceOptions {
    let mode: AcceptanceMode
    var output: URL?
    var ready: URL?

    init(_ arguments: [String]) throws {
        guard geteuid() != 0 else { throw FanError.invalid("請以已簽章 App 的一般使用者 CLI 執行驗收。") }
        var selected: AcceptanceMode?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if AcceptanceVerification.switches.contains(argument) {
                guard selected == nil, let value = AcceptanceMode(rawValue: String(argument.dropFirst("--verify-".count))) else {
                    throw FanError.invalid("一次只允許一種驗收模式。")
                }
                selected = value
            } else if argument == "--verification-output" || argument == "--verification-ready" {
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else {
                    throw FanError.invalid("\(argument) 需要完整的本機 JSON 檔案路徑。")
                }
                let url = URL(fileURLWithPath: arguments[index]).standardizedFileURL
                var directory: ObjCBool = false
                guard url.pathExtension.lowercased() == "json",
                      FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &directory),
                      directory.boolValue else {
                    throw FanError.invalid("驗收輸出需為既有目錄下的 .json 檔案。")
                }
                if argument == "--verification-output" {
                    guard output == nil else { throw FanError.invalid("輸出路徑重複。") }
                    output = url
                } else {
                    guard ready == nil else { throw FanError.invalid("Ready 路徑重複。") }
                    ready = url
                }
            } else { throw FanError.invalid("無法辨識驗收參數：\(argument)") }
            index += 1
        }
        guard let selected else { throw FanError.invalid("缺少驗收模式。") }
        guard output == nil || output != ready else { throw FanError.invalid("結果與 Ready 訊號需使用不同檔案。") }
        mode = selected
    }
}

private struct AcceptancePowerEvent: Codable {
    var name: String
    var date = Date()
    var elapsedSeconds: Double
}

private struct AcceptanceSample: Codable {
    var label: String
    var date = Date()
    var elapsedSeconds: Double
    var fans: [FanReading]
    var sensorTemperature: Double?
    var helperStatus: HelperResponse?
}

private struct AcceptanceAppliedStage: Codable {
    var label: String
    var requestedAt = Date()
    var acknowledgedAt: Date?
    var rules: [FanRule]
    var response: HelperResponse?
}

private struct AcceptanceReport: Codable {
    var schemaVersion = 1
    var mode: AcceptanceMode
    var processID = ProcessInfo.processInfo.processIdentifier
    var phase = "starting"
    var success = false
    var testPassed = false
    var startedAt = Date()
    var completedAt: Date?
    var elapsedAwakeSeconds: Double?
    var elapsedWallSeconds: Double?
    var testLimitSeconds: Double
    var cleanupLimitSeconds = 14.0
    var targetToleranceRPM = 2.0
    var thermalHysteresisRPM = 50.0
    var selectedSensor: String?
    var initialHelperStatus: HelperResponse?
    var initialSnapshot: HardwareSnapshot?
    var manualHelperStatus: HelperResponse?
    var manualSnapshot: HardwareSnapshot?
    var automaticHelperStatus: HelperResponse?
    var automaticSnapshot: HardwareSnapshot?
    var finalHelperStatus: HelperResponse?
    var finalSnapshot: HardwareSnapshot?
    var appliedStages: [AcceptanceAppliedStage] = []
    var samples: [AcceptanceSample] = []
    var powerEvents: [AcceptancePowerEvent] = []
    var checks: [String: Bool] = [:]
    var successfulHeartbeats = 0
    var applyAttempted = false
    var originalConnectionInvalidated = false
    var automaticObservedBeforeCleanup = false
    var automaticObservedSecondsAfterTrigger: Double?
    var lastManualSecondsAfterTrigger: Double?
    var cleanupAttempted = false
    var cleanupResponses: [HelperResponse] = []
    var finalAutomaticVerified = false
    var errors: [String] = []
    var limitations: [String] = []
}

private struct AcceptanceReady: Codable {
    var schemaVersion = 1
    var state: String
    var mode: AcceptanceMode
    var pid: Int32
    var createdAt = Date()
    var remainingAwakeSeconds: Double
    var remainingWallSeconds: Double
    var selectedSensor: String?
    var initialSnapshot: HardwareSnapshot?
    var manualSnapshot: HardwareSnapshot?
    var helperStatus: HelperResponse?
    var externalAction: String
}

@MainActor private final class AcceptanceSession {
    private let options: AcceptanceOptions
    private let owner = HelperClient()
    private let observer = HelperClient()
    private let cleanupClient = HelperClient()
    private let readQueue = DispatchQueue(label: "tw.momo.MoMoFan.acceptance.read", qos: .utility)
    private let startUptime = ProcessInfo.processInfo.systemUptime
    private var report: AcceptanceReport
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var signalSources: [DispatchSourceSignal] = []
    private var powerObservers: [NSObjectProtocol] = []
    private var sleeping = false
    private var sawWake = false
    private var cleanupStarted = false
    private var finished = false
    private var latestRules: [FanRule] = []
    private var applying = false
    private var applyAckUptime = 0.0
    private var helperPID: Int32?

    init(options: AcceptanceOptions) {
        self.options = options
        report = AcceptanceReport(mode: options.mode, testLimitSeconds: options.mode.limit)
        if options.mode == .crashOwner {
            report.limitations.append("SIGKILL 後本程序無法寫最終報告；需由外部獨立 --diagnose 與 --verify-helper 完成 auto 回讀。")
        }
    }

    private var elapsed: Double { ProcessInfo.processInfo.systemUptime - startUptime }

    func start() {
        installPowerObservers()
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.abort("驗收收到 signal \(number)，已啟動回復。")
            }
            source.resume()
            signalSources.append(source)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + options.mode.limit) { [weak self] in
            self?.abort("驗收達到 \(Int(self?.options.mode.limit ?? 0)) 秒上限。")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + options.mode.limit + report.cleanupLimitSeconds) { [weak self] in
            guard let self, !self.finished else { return }
            self.report.errors.append("硬性期限已到；復原未完成獨立驗證，結果不得視為通過。")
            self.owner.invalidate()
            self.report.originalConnectionInvalidated = true
            self.finish()
        }
        runTask = Task { [self] in
            do {
                // Replace stale ready files before any control; these paths never go to the helper.
                if let ready = options.ready {
                    try Self.json(AcceptanceReady(state: "starting", mode: options.mode, pid: ProcessInfo.processInfo.processIdentifier,
                        remainingAwakeSeconds: options.mode.limit, remainingWallSeconds: options.mode.limit,
                        externalAction: "等待本次 pid 的 ready 狀態")).write(to: ready, options: .atomic)
                }
                try await preflight()
                switch options.mode {
                case .lease: try await verifyLease()
                case .disconnect: try await verifyDisconnect()
                case .thermal: try await verifyThermal()
                case .sleep: try await verifySleep()
                case .crashOwner: try await awaitExternalKill()
                }
                try requireActive()
                report.testPassed = true
            } catch {
                if !cleanupStarted { report.errors.append(error.localizedDescription) }
            }
            beginCleanup()
        }
    }

    private func preflight() async throws {
        report.phase = "preflight"
        let status = try await request(owner, .init(.status))
        try requireActive()
        report.initialHelperStatus = status
        guard status.success, status.activeRules.isEmpty, status.pendingRestoreFanIDs.isEmpty else {
            throw FanError.invalid("控制服務已有規則／待復原風扇或未就緒，未接管既有控制。")
        }
        guard let diagnostics = status.diagnostics else {
            throw FanError.invalid("這個驗收需要含 diagnostics 的新版控制服務；尚未寫入硬體。")
        }
        guard !diagnostics.powerSuspended else { throw FanError.invalid("Mac 正在睡眠轉換，未開始驗收。") }
        helperPID = diagnostics.helperPID
        let snapshot = try await readSnapshot()
        try requireActive()
        report.initialSnapshot = snapshot
        try validate(snapshot, health: true)
        guard snapshot.fans.allSatisfy({ !$0.isManual }) else {
            throw FanError.invalid("初始風扇並非全自動，未接管既有控制。")
        }
        // Check again after the hardware read so an already-active application wins this race.
        let confirmation = try await request(owner, .init(.status))
        try requireActive()
        try validateStatus(confirmation)
        guard confirmation.activeRules.isEmpty, confirmation.pendingRestoreFanIDs.isEmpty else {
            throw FanError.invalid("前檢期間已有其他控制，未套用驗收規則。")
        }
        report.checks["preflightAllAutomaticAndUnowned"] = true
    }

    private func fixedRules() throws -> [FanRule] {
        guard let snapshot = report.initialSnapshot else { throw FanError.invalid("缺少初始快照。") }
        return try snapshot.fans.map { fan in
            let baseline = max(fan.minimumRPM, max(fan.currentRPM, fan.targetRPM))
            guard baseline + 400 <= fan.maximumRPM else {
                throw FanError.invalid("風扇 \(fan.id + 1) 未保留基準加 400 RPM 的空間，未開始控制。")
            }
            return FanRule(fanID: fan.id, mode: .fixed, rpm: baseline + 400)
        }
    }

    @discardableResult private func apply(_ rules: [FanRule], label: String) async throws -> HelperResponse {
        try requireActive()
        latestRules = rules
        report.phase = label
        report.applyAttempted = true
        let index = report.appliedStages.count
        report.appliedStages.append(AcceptanceAppliedStage(label: label, rules: rules))
        applying = true
        defer { applying = false }
        let response = try await request(owner, .init(.apply, rules: rules))
        applyAckUptime = ProcessInfo.processInfo.systemUptime
        report.appliedStages[index].acknowledgedAt = Date()
        report.appliedStages[index].response = response
        try requireActive()
        try validateStatus(response)
        guard response.activeRules == rules, response.pendingRestoreFanIDs.isEmpty else {
            throw FanError.hardware("Helper 未完整確認驗收規則：\(response.message)")
        }
        if options.mode.keepsHeartbeat { startHeartbeat() }
        return response
    }

    private func verifyLease() async throws {
        _ = try await apply(fixedRules(), label: "lease-manual")
        let evidence = try await stableManualEvidence()
        saveManual(evidence)
        report.phase = "waiting-for-lease-expiry"
        // Keep owner alive, issue no heartbeat, automatic or invalidate until observation completes.
        let observed = try await observeAutomatic(trigger: applyAckUptime, timeout: 11.5, label: "lease")
        let seconds = observed.time
        report.checks["noHeartbeatSent"] = report.successfulHeartbeats == 0
        report.checks["ownerConnectionKeptOpenUntilAutomatic"] = !report.originalConnectionInvalidated
        report.checks["leaseExpiredWithinExpectedWindow"] = seconds >= 7.75 && seconds <= 11.5
        report.checks["helperReportedHeartbeatTimeout"] = observed.status.diagnostics?.lastRestoreReason?.contains("心跳逾時") == true
        try requireChecks(["noHeartbeatSent", "ownerConnectionKeptOpenUntilAutomatic", "leaseExpiredWithinExpectedWindow", "helperReportedHeartbeatTimeout"])
    }

    private func verifyDisconnect() async throws {
        _ = try await apply(fixedRules(), label: "disconnect-manual")
        saveManual(try await stableManualEvidence())
        let trigger = ProcessInfo.processInfo.systemUptime
        owner.invalidate()
        report.originalConnectionInvalidated = true
        report.phase = "waiting-for-disconnect-recovery"
        let observed = try await observeAutomatic(trigger: trigger, timeout: 5, label: "disconnect")
        report.checks["disconnectRecoveredBeforeLeaseDeadline"] = observed.time <= 5
        report.checks["helperReportedOwnerDisconnect"] = observed.status.diagnostics?.lastRestoreReason?.contains("離線") == true
        try requireChecks(["disconnectRecoveredBeforeLeaseDeadline", "helperReportedOwnerDisconnect"])
    }

    private func verifyThermal() async throws {
        guard let initial = report.initialSnapshot,
              let sensor = ["CPU_MAX", "GPU_MAX", "TH0x"].compactMap({ key in initial.sensors.first { $0.key == key } }).first,
              sensor.celsius >= 25, sensor.celsius <= 78 else {
            throw FanError.invalid("沒有適合正常溫度驗收的 CPU_MAX／GPU_MAX／SSD 感測器（需 25–78°C）。")
        }
        report.selectedSensor = sensor.key
        func curve(_ temperature: Double, offset: Double) -> [FanRule] {
            initial.fans.map { FanRule(fanID: $0.id, mode: .sensor, sensorKey: sensor.key,
                lowerTemperature: max(20, min(89, temperature - offset)), upperTemperature: 95) }
        }
        let first = try await apply(curve(sensor.celsius, offset: 2), label: "thermal-curve-one")
        let firstBaseline = first.diagnostics?.controlTickCount ?? -1
        var firstEvidence = try await stableManualEvidence()
        saveManual(firstEvidence)
        let firstDeadline = ProcessInfo.processInfo.systemUptime + 6
        while (firstEvidence.status.diagnostics?.controlTickCount ?? -1) <= firstBaseline {
            guard ProcessInfo.processInfo.systemUptime < firstDeadline else { throw FanError.hardware("第一條溫控曲線未觀察到成功 timer tick。") }
            try await pause(0.5)
            firstEvidence = try await stableManualEvidence()
        }
        record(firstEvidence.snapshot, status: firstEvidence.status, label: "thermal-first-timer-tick")
        guard let currentTemperature = firstEvidence.snapshot.sensors.first(where: { $0.key == sensor.key })?.celsius,
              currentTemperature >= 25, currentTemperature <= 78 else {
            throw FanError.hardware("第二階段前真實感測器已超出正常驗收溫度。")
        }
        let second = try await apply(curve(currentTemperature, offset: 8), label: "thermal-curve-two")
        guard let baseline = second.diagnostics, let firstTargets = firstEvidence.status.diagnostics?.lastTargets else {
            throw FanError.hardware("缺少曲線比對 diagnostics。")
        }
        let afterSecond = try await stableManualEvidence()
        saveManual(afterSecond)
        report.checks["differentThresholdsChangedTarget"] = baseline.lastTargets.contains { id, target in
            guard let previous = firstTargets[id] else { return false }
            return abs(target - previous) >= 100
        }
        try requireChecks(["differentThresholdsChangedTarget"])
        report.phase = "thermal-observing"
        try emitReady(state: "thermal-observing", action: "正在觀察真實 \(sensor.key) 溫度與 timer 自主調整；可由外部執行已授權的有界單核心工作負載。最多觀察 18 秒。")
        let deadline = ProcessInfo.processInfo.systemUptime + 18
        var tickAdvanced = false
        var timerUpdated = false
        var targetChanged = false
        repeat {
            try await pause(0.5)
            let evidence = try await stableManualEvidence()
            record(evidence.snapshot, status: evidence.status, label: "thermal-autonomous-observation")
            guard let diagnostics = evidence.status.diagnostics else { throw FanError.hardware("溫控觀察缺少 diagnostics。") }
            tickAdvanced = diagnostics.controlTickCount > baseline.controlTickCount
            timerUpdated = diagnostics.timerTargetUpdateCount > baseline.timerTargetUpdateCount
            targetChanged = evidence.snapshot.fans.contains { fan in
                guard let original = baseline.lastTargets[fan.id] else { return false }
                return abs(fan.targetRPM - original) >= 50
            }
            if tickAdvanced && timerUpdated && targetChanged { break }
        } while ProcessInfo.processInfo.systemUptime < deadline
        report.checks["timerSuccessfullyEvaluatedRealSensor"] = tickAdvanced
        report.checks["timerActuallyWroteNewTarget"] = timerUpdated
        report.checks["independentTargetChangedAtLeast50RPM"] = targetChanged
        guard tickAdvanced && timerUpdated && targetChanged else {
            throw FanError.hardware("18 秒內未同時證明 timer 重算、timer 寫入與獨立目標至少改變 50 RPM；自然溫差不足也會未通過，不推定成功。")
        }
    }

    private func verifySleep() async throws {
        guard let baseline = report.initialHelperStatus?.diagnostics else { throw FanError.hardware("睡眠驗收缺少初始 diagnostics。") }
        _ = try await apply(fixedRules(), label: "sleep-manual")
        saveManual(try await stableManualEvidence())
        report.phase = "waiting-for-external-sleep"
        try emitReady(state: "sleep-ready", action: "由外部執行已授權的 pmset sleepnow；之後由使用者按鍵喚醒。此 CLI 不自行睡眠或排定喚醒。")
        var wakeStatus: HelperResponse?
        while elapsed < options.mode.limit - 8 {
            try await pause(0.5)
            // User-space execution already proves the CPU is awake enough to ask the daemon.
            // A missed NSWorkspace.didWake must not suppress the independent IOKit counters.
            let status = try await request(observer, .init(.status))
            try requireActive()
            try validateStatus(status)
            if let diagnostics = status.diagnostics,
               diagnostics.sleepCount > baseline.sleepCount, diagnostics.wakeCount > baseline.wakeCount {
                wakeStatus = status
                break
            }
        }
        stopHeartbeat()
        guard let wakeStatus, let after = wakeStatus.diagnostics else {
            throw FanError.hardware("期限內未由 helper 的實際電源事件計數確認睡眠／喚醒；未把螢幕關閉當作睡眠。")
        }
        report.checks["helperObservedActualSleepAndWake"] = after.sleepCount > baseline.sleepCount && after.wakeCount > baseline.wakeCount
        report.checks["helperSleepAcknowledgementDidNotTimeOut"] = after.sleepAcknowledgementTimeouts == baseline.sleepAcknowledgementTimeouts
        report.checks["helperNotSuspendedAfterWake"] = !after.powerSuspended
        report.checks["workspaceObservedSleepAndWake"] = report.powerEvents.contains { $0.name == "NSWorkspace.willSleep" }
            && report.powerEvents.contains { $0.name == "NSWorkspace.didWake" }
        let observation = try await observeAutomatic(trigger: ProcessInfo.processInfo.systemUptime, timeout: 6, label: "wake")
        report.checks["helperReleasedForSleep"] = observation.status.diagnostics?.lastRestoreReason?.contains("睡眠") == true
        try requireChecks(["helperObservedActualSleepAndWake", "helperSleepAcknowledgementDidNotTimeOut",
                           "helperNotSuspendedAfterWake", "helperReleasedForSleep"])
        if !report.checks["workspaceObservedSleepAndWake", default: false] {
            report.limitations.append("NSWorkspace 通知未成對到達；實際睡眠／喚醒採 helper IOKit sleepCount／wakeCount 的增量作為證據。")
        }
    }

    private func awaitExternalKill() async throws {
        _ = try await apply(fixedRules(), label: "crash-owner-manual")
        saveManual(try await stableManualEvidence())
        report.phase = "awaiting-external-sigkill"
        try emitReady(state: "crash-owner-ready", action: "只對本 JSON 的 pid 發送 SIGKILL；用獨立 --diagnose 與 --verify-helper 驗證全自動。不要殺 helper 或 GUI。")
        while elapsed < options.mode.limit - 5 { try await pause(0.5) }
        throw FanError.hardware("未在期限內收到外部 SIGKILL，已自行清理；本次不算 crash 驗收成功。")
    }

    private struct Evidence {
        var snapshot: HardwareSnapshot
        var status: HelperResponse
    }

    private func stableManualEvidence() async throws -> Evidence {
        // A control tick between status and SMC reads is allowed; retry observation, never hardware writes.
        for _ in 0..<4 {
            try requireActive()
            let before = try await request(observer, .init(.status))
            let snapshot = try await readSnapshot()
            let after = try await request(observer, .init(.status))
            try requireActive()
            try validateStatus(before); try validateStatus(after)
            try validate(snapshot, health: true)
            guard before.activeRules == latestRules, after.activeRules == latestRules,
                  before.pendingRestoreFanIDs.isEmpty, after.pendingRestoreFanIDs.isEmpty,
                  let first = before.diagnostics, let last = after.diagnostics else {
                throw FanError.hardware("驗收期間控制規則／擁有權已改變。")
            }
            guard first.lastTargets == last.lastTargets, first.controlTickCount == last.controlTickCount else {
                try await pause(0.1)
                continue
            }
            for fan in snapshot.fans {
                guard fan.isManual, let rule = latestRules.first(where: { $0.fanID == fan.id }),
                      let expected = last.lastTargets[fan.id], abs(fan.targetRPM - expected) <= 2 else {
                    throw FanError.hardware("獨立 SMC 未確認風扇 \(fan.id + 1) 的手動模式與 helper 目標。")
                }
                let recomputed = try rule.target(for: fan, temperature: last.lastTemperatures[rule.sensorKey])!
                let tolerance = rule.mode == .sensor ? 50.0 : 2.01
                guard abs(recomputed - expected) < tolerance else {
                    throw FanError.hardware("風扇 \(fan.id + 1) 目標與真感測器曲線／固定規則不符。")
                }
            }
            report.checks["independentManualModeAndTargetVerified"] = true
            return Evidence(snapshot: snapshot, status: after)
        }
        throw FanError.hardware("讀回期間控制 tick 持續跨越取樣，未取得一致的獨立目標證據。")
    }

    private func saveManual(_ evidence: Evidence) {
        report.manualSnapshot = evidence.snapshot
        report.manualHelperStatus = evidence.status
        record(evidence.snapshot, status: evidence.status, label: report.phase)
    }

    private func observeAutomatic(trigger: Double, timeout: Double, label: String) async throws -> (time: Double, status: HelperResponse) {
        repeat {
            try requireActive()
            let snapshot = try await readSnapshot()
            let status = try await request(observer, .init(.status))
            try requireActive()
            try validate(snapshot, health: false)
            try validateStatus(status)
            let duration = ProcessInfo.processInfo.systemUptime - trigger
            record(snapshot, status: status, label: "\(label)-poll")
            if snapshot.fans.allSatisfy({ !$0.isManual }), status.activeRules.isEmpty, status.pendingRestoreFanIDs.isEmpty {
                report.automaticSnapshot = snapshot
                report.automaticHelperStatus = status
                report.automaticObservedBeforeCleanup = true
                report.automaticObservedSecondsAfterTrigger = duration
                report.checks["automaticObservedWithoutCleanupCommand"] = true
                return (duration, status)
            }
            if snapshot.fans.contains(where: \.isManual) { report.lastManualSecondsAfterTrigger = duration }
            guard duration < timeout else { break }
            try await pause(0.25)
        } while true
        throw FanError.hardware("\(label) 在 \(timeout) 秒內未確認全部風扇與 helper 均回復自動。")
    }

    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && !self.cleanupStarted {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, !self.cleanupStarted, !self.sleeping, !self.sawWake else { continue }
                    let response = try await self.request(self.owner, .init(.heartbeat))
                    guard !Task.isCancelled, !self.cleanupStarted else { return }
                    try self.validateStatus(response)
                    // While sleep notifications are in transit the daemon may have released first.
                    if self.options.mode == .sleep, response.activeRules.isEmpty,
                       (response.diagnostics?.sleepCount ?? 0) > (self.report.initialHelperStatus?.diagnostics?.sleepCount ?? 0) {
                        self.stopHeartbeat()
                        return
                    }
                    guard response.activeRules == self.latestRules, response.pendingRestoreFanIDs.isEmpty else {
                        throw FanError.hardware("驗收心跳發現控制規則已停止。")
                    }
                    self.report.successfulHeartbeats += 1
                } catch is CancellationError { return }
                catch { self.abort("驗收心跳：\(error.localizedDescription)"); return }
            }
        }
    }

    private func stopHeartbeat() { heartbeatTask?.cancel(); heartbeatTask = nil }

    private func installPowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                self.report.powerEvents.append(.init(name: "NSWorkspace.willSleep", elapsedSeconds: self.elapsed))
                self.sleeping = true
                self.stopHeartbeat()
                if self.options.mode != .sleep { self.abort("非睡眠驗收期間收到系統睡眠，停止本次驗收。") }
                // Do not invalidate or send automatic: the helper's power observer must cause recovery.
            }
        })
        powerObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                self.report.powerEvents.append(.init(name: "NSWorkspace.didWake", elapsedSeconds: self.elapsed))
                self.sleeping = false; self.sawWake = true
                self.stopHeartbeat()
            }
        })
    }

    private func validateStatus(_ status: HelperResponse) throws {
        guard status.success else { throw FanError.helper(status.message) }
        guard let diagnostics = status.diagnostics, diagnostics.helperPID == helperPID else {
            throw FanError.hardware("驗收期間 helper 已重啟或 diagnostics 缺失，不能歸因為本次測試。")
        }
    }

    private func validate(_ snapshot: HardwareSnapshot, health: Bool) throws {
        guard !snapshot.fans.isEmpty, snapshot.fans.count <= 10,
              Set(snapshot.fans.map(\.id)).count == snapshot.fans.count,
              report.initialSnapshot == nil || Set(snapshot.fans.map(\.id)) == Set(report.initialSnapshot!.fans.map(\.id)) else {
            throw FanError.hardware("驗收風扇清單無效或已改變。")
        }
        for fan in snapshot.fans {
            try FanRule(fanID: fan.id).validate(for: fan, sensorKeys: [])
            guard [fan.currentRPM, fan.targetRPM].allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 20_000 }) else {
                throw FanError.hardware("驗收風扇讀值失效。")
            }
        }
        if health {
            guard !snapshot.sensors.isEmpty, snapshot.sensors.allSatisfy({ $0.celsius.isFinite && $0.celsius > 0 && $0.celsius < 130 }),
                  ProcessInfo.processInfo.thermalState != .critical else {
                throw FanError.hardware("感測器／系統熱狀態不適合驗收。")
            }
        }
    }

    private func requireChecks(_ names: [String]) throws {
        let failed = names.filter { report.checks[$0] != true }
        if !failed.isEmpty { throw FanError.hardware("驗收條件未通過：\(failed.joined(separator: ", "))") }
    }

    private func requireActive() throws {
        try Task.checkCancellation()
        guard !cleanupStarted, !finished else { throw CancellationError() }
        // Wall time also bounds tests across actual sleep; the machine cannot execute while asleep.
        guard elapsed < options.mode.limit, Date().timeIntervalSince(report.startedAt) < options.mode.limit else {
            throw FanError.hardware("驗收已達總時間上限。")
        }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try requireActive()
    }

    private func request(_ client: HelperClient, _ request: HelperRequest) async throws -> HelperResponse {
        try await withCheckedThrowingContinuation { continuation in
            client.send(request) { continuation.resume(with: $0) }
        }
    }

    private func readSnapshot() async throws -> HardwareSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async {
                // Each evidence snapshot opens a separate read-only AppleSMC connection.
                continuation.resume(with: Result { try SMCClient().snapshot() })
            }
        }
    }

    private func record(_ snapshot: HardwareSnapshot, status: HelperResponse?, label: String) {
        report.samples.append(.init(label: label, elapsedSeconds: elapsed, fans: snapshot.fans,
            sensorTemperature: snapshot.sensors.first { $0.key == report.selectedSensor }?.celsius, helperStatus: status))
    }

    private func emitReady(state: String, action: String) throws {
        let marker = AcceptanceReady(state: state, mode: options.mode, pid: ProcessInfo.processInfo.processIdentifier,
            remainingAwakeSeconds: max(0, options.mode.limit - elapsed),
            remainingWallSeconds: max(0, options.mode.limit - Date().timeIntervalSince(report.startedAt)),
            selectedSensor: report.selectedSensor, initialSnapshot: report.initialSnapshot,
            manualSnapshot: report.manualSnapshot, helperStatus: report.manualHelperStatus, externalAction: action)
        if let ready = options.ready { try Self.json(marker).write(to: ready, options: .atomic) }
        if let output = options.output { try Self.json(report).write(to: output, options: .atomic) }
        let compact = JSONEncoder(); compact.dateEncodingStrategy = .iso8601
        var data = Data("MOMOFAN_ACCEPTANCE_READY ".utf8)
        data.append(try compact.encode(marker)); data.append(0x0a)
        FileHandle.standardError.write(data)
    }

    private func abort(_ reason: String) {
        guard !finished, !cleanupStarted else { return }
        report.errors.append(reason)
        runTask?.cancel()
        beginCleanup()
    }

    private func beginCleanup() {
        guard !cleanupStarted, !finished else { return }
        cleanupStarted = true
        stopHeartbeat()
        guard report.applyAttempted else { finish(); return }
        report.phase = "cleanup"
        report.cleanupAttempted = true
        cleanupTask = Task { [self] in
            // Cancellation does not cancel an XPC continuation. Await the apply reply (the
            // client has its own four-second timeout) before issuing automatic elsewhere.
            // Otherwise a late apply could overtake recovery on the second connection.
            let applyDeadline = ProcessInfo.processInfo.systemUptime + 4.5
            while applying && ProcessInfo.processInfo.systemUptime < applyDeadline {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
                }
            }
            if applying {
                report.errors.append("套用請求在清理前仍未結束；已中斷擁有者連線，結果不得視為通過。")
                owner.invalidate(); report.originalConnectionInvalidated = true
            }
            // Use a separate connection even when the owner has intentionally been invalidated.
            do {
                let response = try await request(cleanupClient, .init(.automatic))
                report.cleanupResponses.append(response)
                if !response.success || !response.activeRules.isEmpty || !response.pendingRestoreFanIDs.isEmpty {
                    report.errors.append("清理要求尚未完成：\(response.message)")
                    owner.invalidate(); report.originalConnectionInvalidated = true
                }
            } catch {
                report.errors.append("清理連線：\(error.localizedDescription)")
                owner.invalidate(); report.originalConnectionInvalidated = true
                cleanupClient.invalidate()
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 7
            var lastError: String?
            repeat {
                do {
                    let snapshot = try await readSnapshot()
                    try validate(snapshot, health: false)
                    let status = try await request(cleanupClient, .init(.status))
                    report.finalSnapshot = snapshot
                    report.finalHelperStatus = status
                    if snapshot.fans.allSatisfy({ !$0.isManual }), status.success,
                       status.activeRules.isEmpty, status.pendingRestoreFanIDs.isEmpty {
                        report.finalAutomaticVerified = true
                        record(snapshot, status: status, label: "final-independent-automatic")
                        break
                    }
                    lastError = "獨立 SMC 或 helper 尚未確認全自動。"
                    // Retry explicit recovery once; never resume any manual rules.
                    if report.cleanupResponses.count < 2 {
                        let retry = try await request(cleanupClient, .init(.automatic))
                        report.cleanupResponses.append(retry)
                    }
                } catch { lastError = error.localizedDescription }
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { continuation.resume() }
                }
            } while ProcessInfo.processInfo.systemUptime < deadline
            if !report.finalAutomaticVerified { report.errors.append("最終自動回讀未通過：\(lastError ?? "沒有有效讀值")") }
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + report.cleanupLimitSeconds) { [weak self] in
            guard let self, !self.finished else { return }
            self.report.errors.append("清理達到 14 秒上限，未宣稱復原成功。")
            self.owner.invalidate(); self.report.originalConnectionInvalidated = true
            self.finish()
        }
    }

    private static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(value); data.append(0x0a)
        return data
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        stopHeartbeat()
        owner.invalidate(); observer.invalidate(); cleanupClient.invalidate()
        for token in powerObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        report.phase = "finished"
        report.completedAt = Date()
        report.elapsedAwakeSeconds = elapsed
        report.elapsedWallSeconds = Date().timeIntervalSince(report.startedAt)
        report.success = report.testPassed && report.finalAutomaticVerified && report.errors.isEmpty
        do {
            if let output = options.output {
                do { try Self.json(report).write(to: output, options: .atomic) }
                catch {
                    report.success = false
                    report.errors.append("結果檔寫入失敗：\(error.localizedDescription)")
                }
            }
            FileHandle.standardOutput.write(try Self.json(report))
        } catch {
            FileHandle.standardOutput.write(Data("{\"success\":false,\"errors\":[\"驗收結果 JSON 編碼失敗\"]}\n".utf8))
            exit(1)
        }
        exit(report.success ? 0 : 1)
    }
}
