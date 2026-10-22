import Foundation
import FanCore
import Darwin
import IOKit
import IOKit.pwr_mgt

// IOMessage.h uses function-like C macros which Swift cannot import.
// iokit_common_msg = err_system(0x38) | err_sub(0) | message.
private let systemCanSleep: UInt32 = 0xe0000270
private let systemWillSleep: UInt32 = 0xe0000280
private let systemHasPoweredOn: UInt32 = 0xe0000300

private final class PowerAcknowledgement {
    private let lock = NSLock()
    private var acknowledged = false
    private let root: io_connect_t
    private let token: Int
    init(root: io_connect_t, token: Int) { self.root = root; self.token = token }
    @discardableResult func finish() -> Bool {
        lock.lock()
        guard !acknowledged else { lock.unlock(); return false }
        acknowledged = true
        lock.unlock()
        IOAllowPowerChange(root, token)
        return true
    }
}

final class PowerObserver {
    let controller: Controller
    var root: io_connect_t = 0
    var notifier: io_object_t = 0
    var port: IONotificationPortRef?
    init(_ controller: Controller) throws {
        self.controller = controller
        root = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let observer = Unmanaged<PowerObserver>.fromOpaque(context).takeUnretainedValue()
            if message == systemWillSleep {
                // Block even already-queued apply requests without waiting for SMC I/O.
                observer.controller.setPowerSuspended(true)
                let acknowledgement = PowerAcknowledgement(root: observer.root, token: Int(bitPattern: argument))
                observer.controller.queue.async {
                    observer.controller.diagnostics.sleepCount += 1
                    observer.controller.failSafe("Mac 進入睡眠")
                    acknowledgement.finish()
                }
                // IOKit forces sleep after 30 seconds regardless. Do not block its
                // run loop indefinitely if a kernel call hangs; keep the journal.
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                    if acknowledgement.finish() {
                        observer.controller.queue.async {
                            observer.controller.diagnostics.sleepAcknowledgementTimeouts += 1
                        }
                    }
                }
            } else if message == systemCanSleep {
                IOAllowPowerChange(observer.root, Int(bitPattern: argument))
            } else if message == systemHasPoweredOn {
                let generation = observer.controller.powerGeneration
                observer.controller.queue.async {
                    observer.controller.resumePower(after: generation)
                    observer.controller.diagnostics.wakeCount += 1
                    // Never resume a manual rule after sleep. Retry only automatic restoration.
                    if !observer.controller.owned.isEmpty { observer.controller.failSafe("喚醒後重試回復系統自動") }
                    observer.controller.updateTimer()
                }
            }
        }, &notifier)
        guard root != 0, let port,
              let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            throw FanError.helper("無法完整註冊系統睡眠通知，控制服務未啟動。")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if let port { IONotificationPortDestroy(port) }
        if root != 0 { IOServiceClose(root) }
    }
}

// The daemon exposes typed fan operations only. No shell, arbitrary keys or paths.
final class Controller {
    let queue = DispatchQueue(label: "tw.momo.MoMoFan.helper.control")
    let smc: SMCClient
    let journal = URL(fileURLWithPath: "/var/db/tw.momo.MoMoFan-owned.json")
    var owned = Set<Int>()
    var active: [FanRule] = []
    var lastTargets: [Int: Double] = [:]
    var owner: UUID?
    private let powerLock = NSLock()
    private var suspended = false
    private var sleepGeneration: UInt64 = 0
    var powerSuspended: Bool {
        powerLock.lock(); defer { powerLock.unlock() }
        return suspended
    }
    func setPowerSuspended(_ value: Bool) {
        powerLock.lock()
        if value { sleepGeneration &+= 1 }
        suspended = value
        powerLock.unlock()
    }
    var powerGeneration: UInt64 {
        powerLock.lock(); defer { powerLock.unlock() }
        return sleepGeneration
    }
    func resumePower(after generation: UInt64) {
        powerLock.lock(); defer { powerLock.unlock() }
        // A queued old wake must not clear a more recent will-sleep gate.
        if sleepGeneration == generation { suspended = false }
    }
    var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    var status = "控制服務已就緒"
    var diagnostics = HelperDiagnostics(helperPID: getpid(), buildIdentifier: "1.0.2-qc3")
    var journalError: String?
    var timer: DispatchSourceTimer?
    var termination: DispatchSourceSignal?
    var thermalObserver: NSObjectProtocol?
    private var started = false

    init() throws {
        smc = try SMCClient()
        // Recover only fans this daemon recorded before a write, including a crash.
        do {
            owned = try FanRecovery.decodeJournal(Data(contentsOf: journal))
            if !owned.isEmpty { failSafe("服務啟動，恢復先前控制狀態") }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // No previous writes have been journaled.
        } catch {
            journalError = "無法確認風扇復原紀錄：\(error.localizedDescription)"
            status = journalError!
        }
    }

    func persist() throws {
        try JSONEncoder().encode(owned.sorted()).write(to: journal, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }

    func restoreOwned() throws {
        let hadOwned = !owned.isEmpty
        active = []; owner = nil; lastTargets = [:]
        diagnostics.lastTargets = [:]; diagnostics.lastTemperatures = [:]
        let result = FanRecovery.restore(owned) { try smc.setAutomatic(fanID: $0) }
        owned = result.remaining
        var failures = result.failures
        // Avoid journal writes for idle sleep/disconnect/status events.
        if hadOwned {
            do { try persist() }
            catch { failures.append("保存復原紀錄失敗：\(error.localizedDescription)") }
        }
        updateTimer()
        if !failures.isEmpty { throw FanError.hardware(failures.joined(separator: "；")) }
    }

    func failSafe(_ reason: String) {
        diagnostics.lastRestoreReason = reason; diagnostics.lastRestoreAt = Date()
        do { try restoreOwned(); status = "\(reason)，已回復系統自動" }
        catch { status = "\(reason)；回復仍待重試：\(error.localizedDescription)" }
        if let journalError { status += "；\(journalError)" }
    }

    func start() {
        started = true
        updateTimer()
        signal(SIGTERM, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        signalSource.setEventHandler { [weak self] in
            self?.failSafe("服務停止")
            exit(0)
        }
        signalSource.resume(); termination = signalSource
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                if !self.owned.isEmpty && ProcessInfo.processInfo.thermalState == .critical {
                    self.failSafe("系統回報高溫")
                }
            }
        }
    }

    func updateTimer() {
        guard started, FanControlPolicy.needsTimer(ownedFanIDs: owned, powerSuspended: powerSuspended) else {
            timer?.cancel(); timer = nil
            return
        }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume(); timer = source
    }

    func tick() {
        guard !owned.isEmpty else { return }
        let decision = FanControlPolicy.evaluateTick(
            rules: active, lastTargets: lastTargets, hasOwner: owner != nil,
            now: ProcessInfo.processInfo.systemUptime, lastHeartbeat: lastHeartbeat,
            criticalThermalState: ProcessInfo.processInfo.thermalState == .critical,
            powerSuspended: powerSuspended,
            readSnapshot: { try smc.snapshot(sensorKeys: $0) }
        )
        guard case let .control(updates, temperatures) = decision else {
            if case let .restore(reason) = decision { failSafe(reason) }
            return
        }
        do {
            for id in updates.keys.sorted() {
                try requireSafePowerAndThermalState()
                try smc.setManual(fanID: id, rpm: updates[id]!)
                lastTargets[id] = updates[id]!
                diagnostics.timerTargetUpdateCount += 1
            }
            try requireSafePowerAndThermalState()
            diagnostics.lastTargets = lastTargets
            diagnostics.lastTemperatures = temperatures
            diagnostics.controlTickCount += 1
            diagnostics.lastControlTickAt = Date()
        } catch { failSafe(error.localizedDescription) }
    }

    func requireSafePowerAndThermalState() throws {
        guard !powerSuspended else { throw FanError.helper("Mac 正在睡眠轉換，請喚醒後重新套用。") }
        guard ProcessInfo.processInfo.thermalState != .critical else { throw FanError.helper("系統回報高溫，請保留系統自動控制。") }
    }

    func response(success: Bool, message: String, includeResources: Bool = false) -> HelperResponse {
        diagnostics.timerScheduled = timer != nil
        diagnostics.powerSuspended = powerSuspended
        diagnostics.journalError = journalError
        diagnostics.resources = includeResources ? resourceUsage() : nil
        return HelperResponse(success: success, message: message, activeRules: active,
                              pendingRestoreFanIDs: active.isEmpty ? owned.sorted() : [], diagnostics: diagnostics)
    }

    private func resourceUsage() -> HelperResourceUsage? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        // proc_pid_rusage CPU times are Mach ticks, not nanoseconds.
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS,
              let userNanoseconds = MachTimeConversion.nanoseconds(ticks: usage.ri_user_time,
                  numerator: timebase.numer, denominator: timebase.denom),
              let systemNanoseconds = MachTimeConversion.nanoseconds(ticks: usage.ri_system_time,
                  numerator: timebase.numer, denominator: timebase.denom) else { return nil }
        return HelperResourceUsage(userTimeNanoseconds: userNanoseconds, systemTimeNanoseconds: systemNanoseconds,
                                   interruptWakeups: usage.ri_interrupt_wkups, packageIdleWakeups: usage.ri_pkg_idle_wkups,
                                   physicalFootprintBytes: usage.ri_phys_footprint,
                                   diskBytesRead: usage.ri_diskio_bytesread, diskBytesWritten: usage.ri_diskio_byteswritten)
    }

    func handle(_ request: HelperRequest, client: UUID, isClientConnected: () -> Bool) -> HelperResponse {
        do {
            switch request.action {
            case .status:
                if let journalError { throw FanError.helper(journalError) }
            case .heartbeat:
                if owner == client { lastHeartbeat = ProcessInfo.processInfo.systemUptime }
            case .automatic:
                // Explicit user action, unlike startup/disconnect recovery.
                // Discovery failing must NEVER skip restoration of known owned fans.
                var failures: [String] = []
                do { owned.formUnion(try smc.fanIDs()); try persist() }
                catch { failures.append(error.localizedDescription) }
                diagnostics.lastRestoreReason = "使用者要求回復系統自動"; diagnostics.lastRestoreAt = Date()
                do { try restoreOwned() } catch { failures.append(error.localizedDescription) }
                guard failures.isEmpty else {
                    status = "回復系統自動未完整確認：\(failures.joined(separator: "；"))"
                    throw FanError.hardware(status)
                }
                journalError = nil
                status = "全部風扇已回復系統自動"
            case .apply:
                guard owner == nil || owner == client else { throw FanError.helper("另一個 MoMo Fan 視窗正在控制風扇。") }
                do {
                    guard isClientConnected() else { throw FanError.helper("App 連線已結束。") }
                    try requireSafePowerAndThermalState()
                    guard journalError == nil else { throw FanError.helper("復原紀錄未確認，請先明確回復系統自動。") }
                    if active.isEmpty && !owned.isEmpty { try restoreOwned() }
                    let keys = FanControlPolicy.sensorKeys(for: request.rules)
                    let snapshot = try smc.snapshot(sensorKeys: keys)
                    let targets = try FanControlPolicy.targetsForApply(rules: request.rules, snapshot: snapshot)
                    // Journal before taking control so launchd recovery can release it.
                    owned.formUnion(targets.keys)
                    try persist()
                    for rule in request.rules {
                        if let target = targets[rule.fanID] {
                            guard isClientConnected() else { throw FanError.helper("App 連線已結束。") }
                            try requireSafePowerAndThermalState()
                            try smc.setManual(fanID: rule.fanID, rpm: target)
                            lastTargets[rule.fanID] = target
                        } else {
                            try smc.setAutomatic(fanID: rule.fanID)
                            owned.remove(rule.fanID); lastTargets.removeValue(forKey: rule.fanID)
                        }
                    }
                    guard isClientConnected() else { throw FanError.helper("App 連線已結束。") }
                    try requireSafePowerAndThermalState()
                    try persist()
                    active = request.rules.filter { $0.mode != .automatic }
                    owner = active.isEmpty ? nil : client
                    lastHeartbeat = ProcessInfo.processInfo.systemUptime
                    diagnostics.lastTargets = lastTargets
                    diagnostics.lastTemperatures = try FanControlPolicy.sensorValues(snapshot.sensors).filter { keys.contains($0.key) }
                    updateTimer()
                    status = active.isEmpty ? "全部風扇已回復系統自動" : "已套用並回讀風扇控制設定"
                } catch {
                    if !owned.isEmpty { failSafe("套用失敗") }
                    throw error
                }
            }
            return response(success: true, message: status, includeResources: request.action == .status)
        } catch { return response(success: false, message: error.localizedDescription, includeResources: request.action == .status) }
    }

    func disconnected(_ client: UUID) {
        queue.async { if self.owner == client { self.failSafe("App 已離線") } }
    }
}

final class Session: NSObject, FanHelperProtocol {
    let id = UUID()
    let controller: Controller
    private let connectionLock = NSLock()
    private var connected = true
    init(_ controller: Controller) { self.controller = controller }
    private var isConnected: Bool {
        connectionLock.lock(); defer { connectionLock.unlock() }
        return connected
    }
    func disconnected() {
        // Mark synchronously: invalidation may precede an already queued apply.
        connectionLock.lock(); connected = false; connectionLock.unlock()
        controller.disconnected(id)
    }
    func request(_ payload: Data, withReply reply: @escaping (Data) -> Void) {
        controller.queue.async {
            let response: HelperResponse
            do {
                guard self.isConnected else { throw FanError.helper("App 連線已結束。") }
                guard payload.count < 32768 else { throw FanError.invalid("要求過大") }
                response = self.controller.handle(try JSONDecoder().decode(HelperRequest.self, from: payload),
                                                   client: self.id, isClientConnected: { self.isConnected })
            } catch { response = self.controller.response(success: false, message: error.localizedDescription) }
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    let controller: Controller
    init(_ controller: Controller) { self.controller = controller }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        connection.setCodeSigningRequirement("anchor apple generic and identifier \"\(appBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(signingTeamIdentifier)\"")
        let session = Session(controller)
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { session.disconnected() }
        connection.interruptionHandler = { session.disconnected() }
        connection.resume()
        return true
    }
}

guard geteuid() == 0 else { fputs("MoMoFanHelper must run as an approved launch daemon.\n", stderr); exit(1) }
do {
    let controller = try Controller()
    let delegate = Listener(controller)
    let powerObserver = try PowerObserver(controller)
    let listener = NSXPCListener(machServiceName: helperServiceName)
    listener.delegate = delegate
    listener.setConnectionCodeSigningRequirement("anchor apple generic and identifier \"\(appBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(signingTeamIdentifier)\"")
    controller.start()
    listener.resume()
    withExtendedLifetime(powerObserver) { RunLoop.current.run() }
} catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
