import Foundation

/// Pure decisions shared by the real controller and fault-injection tests.
public enum FanControlPolicy {
    public static let heartbeatTimeout: TimeInterval = 8
    public static let targetTolerance = 2.0
    public static let targetUpdateThreshold = 50.0

    public enum RestoreReason: String, Codable {
        case missingOwner, heartbeatExpired, invalidClock, criticalThermalState, systemSleep
        public var message: String {
            switch self {
            case .missingOwner: return "恢復先前控制狀態"
            case .heartbeatExpired: return "App 心跳逾時"
            case .invalidClock: return "控制計時失效"
            case .criticalThermalState: return "系統回報高溫"
            case .systemSleep: return "Mac 進入睡眠"
            }
        }
    }

    public static func needsTimer(ownedFanIDs: Set<Int>, powerSuspended: Bool) -> Bool {
        !ownedFanIDs.isEmpty && !powerSuspended
    }

    public static func restorationReason(hasOwner: Bool, hasActiveRules: Bool, now: TimeInterval,
                                         lastHeartbeat: TimeInterval, criticalThermalState: Bool,
                                         powerSuspended: Bool) -> RestoreReason? {
        if powerSuspended { return .systemSleep }
        if !hasOwner || !hasActiveRules { return .missingOwner }
        if criticalThermalState { return .criticalThermalState }
        guard now.isFinite, lastHeartbeat.isFinite, now >= lastHeartbeat else { return .invalidClock }
        return now - lastHeartbeat >= heartbeatTimeout ? .heartbeatExpired : nil
    }

    public static func sensorKeys(for rules: [FanRule]) -> Set<String> {
        Set(rules.filter { $0.mode == .sensor }.map(\.sensorKey))
    }

    public enum TickDecision {
        case restore(String)
        case control(updates: [Int: Double], temperatures: [String: Double])
    }

    /// The injected reader is never called once the lease or safety gate fails.
    /// Hardware and validation errors use the same restoration path as expiration.
    public static func evaluateTick(rules: [FanRule], lastTargets: [Int: Double], hasOwner: Bool,
                                    now: TimeInterval, lastHeartbeat: TimeInterval,
                                    criticalThermalState: Bool, powerSuspended: Bool,
                                    readSnapshot: (Set<String>) throws -> HardwareSnapshot) -> TickDecision {
        if let reason = restorationReason(hasOwner: hasOwner, hasActiveRules: !rules.isEmpty,
                                          now: now, lastHeartbeat: lastHeartbeat,
                                          criticalThermalState: criticalThermalState,
                                          powerSuspended: powerSuspended) { return .restore(reason.message) }
        do {
            let keys = sensorKeys(for: rules)
            let snapshot = try readSnapshot(keys)
            let updates = try updatesForTick(rules: rules, snapshot: snapshot, lastTargets: lastTargets)
            let temperatures = try sensorValues(snapshot.sensors).filter { keys.contains($0.key) }
            return .control(updates: updates, temperatures: temperatures)
        } catch { return .restore(error.localizedDescription) }
    }

    /// Validate the entire request, including every temperature, before the first write.
    public static func targetsForApply(rules: [FanRule], snapshot: HardwareSnapshot) throws -> [Int: Double] {
        try validateTelemetry(snapshot.fans)
        let fanIDs = Set(snapshot.fans.map(\.id))
        guard !fanIDs.isEmpty, fanIDs.count == snapshot.fans.count,
              rules.count == fanIDs.count, Set(rules.map(\.fanID)) == fanIDs else {
            throw FanError.invalid("預設檔的風扇數量或識別碼與這台 Mac 不符。")
        }
        let sensors = try sensorValues(snapshot.sensors)
        var targets: [Int: Double] = [:]
        for rule in rules {
            guard let fan = snapshot.fans.first(where: { $0.id == rule.fanID }) else {
                throw FanError.invalid("找不到所選風扇。")
            }
            try rule.validate(for: fan, sensorKeys: Set(sensors.keys))
            if let target = try rule.target(for: fan, temperature: sensors[rule.sensorKey]) { targets[fan.id] = target }
        }
        return targets
    }

    /// A single bad fan/sensor rejects the whole tick before any fan is changed.
    public static func updatesForTick(rules: [FanRule], snapshot: HardwareSnapshot,
                                      lastTargets: [Int: Double]) throws -> [Int: Double] {
        try validateTelemetry(snapshot.fans)
        guard Set(snapshot.fans.map(\.id)).count == snapshot.fans.count,
              Set(rules.map(\.fanID)).count == rules.count else { throw FanError.hardware("重複的風扇識別碼。") }
        let sensors = try sensorValues(snapshot.sensors)
        var updates: [Int: Double] = [:]
        for rule in rules {
            guard rule.mode != .automatic,
                  let fan = snapshot.fans.first(where: { $0.id == rule.fanID }), fan.isManual,
                  fan.targetRPM.isFinite, let expected = lastTargets[fan.id], expected.isFinite,
                  abs(expected - fan.targetRPM) <= targetTolerance else {
                throw FanError.hardware("風扇模式或目標已由其他控制來源變更。")
            }
            try rule.validate(for: fan, sensorKeys: Set(sensors.keys))
            guard let target = try rule.target(for: fan, temperature: sensors[rule.sensorKey]) else {
                throw FanError.invalid("控制規則缺少目標。")
            }
            if abs(target - fan.targetRPM) >= targetUpdateThreshold { updates[fan.id] = target }
        }
        return updates
    }

    public static func sensorValues(_ sensors: [SensorReading]) throws -> [String: Double] {
        var values: [String: Double] = [:]
        for sensor in sensors {
            guard values[sensor.key] == nil else { throw FanError.hardware("重複的感測器識別碼。") }
            values[sensor.key] = sensor.celsius
        }
        return values
    }

    private static func validateTelemetry(_ fans: [FanReading]) throws {
        guard fans.allSatisfy({
            $0.currentRPM.isFinite && $0.currentRPM >= 0 && $0.currentRPM < 20_000
                && $0.targetRPM.isFinite && $0.targetRPM >= 0 && $0.targetRPM < 20_000
        }) else { throw FanError.hardware("風扇轉速讀值失效。") }
    }
}

public enum FanRecovery {
    /// Keep only failures pending; attempt every recorded fan even when the first fails.
    public static func restore(_ fanIDs: Set<Int>, restoreFan: (Int) throws -> Void)
        -> (remaining: Set<Int>, failures: [String]) {
        var remaining = fanIDs
        var failures: [String] = []
        for id in fanIDs.sorted() {
            do { try restoreFan(id); remaining.remove(id) }
            catch { failures.append(error.localizedDescription) }
        }
        return (remaining, failures)
    }

    public static func decodeJournal(_ data: Data) throws -> Set<Int> {
        let ids = try JSONDecoder().decode([Int].self, from: data)
        guard ids.allSatisfy({ (0..<10).contains($0) }), Set(ids).count == ids.count else {
            throw FanError.invalid("風扇復原紀錄含無效或重複識別碼。")
        }
        return Set(ids)
    }
}
