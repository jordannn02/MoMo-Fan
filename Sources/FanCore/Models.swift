import Foundation

public let helperServiceName = "tw.momo.MoMoFan.helper"
public let appBundleIdentifier = "tw.momo.MoMoFan"
public let signingTeamIdentifier = "F8222FBL22"

public struct FanReading: Codable, Identifiable, Equatable {
    public var id: Int
    public var name: String
    public var currentRPM: Double
    public var minimumRPM: Double
    public var maximumRPM: Double
    public var targetRPM: Double
    public var isManual: Bool
    public init(id: Int, name: String, currentRPM: Double, minimumRPM: Double, maximumRPM: Double, targetRPM: Double, isManual: Bool) {
        self.id = id; self.name = name; self.currentRPM = currentRPM
        self.minimumRPM = minimumRPM; self.maximumRPM = maximumRPM
        self.targetRPM = targetRPM; self.isManual = isManual
    }
}

public struct SensorReading: Codable, Identifiable, Equatable {
    public var id: String { key }
    public var key: String
    public var name: String
    public var group: String
    public var celsius: Double
    public init(key: String, name: String, group: String, celsius: Double) {
        self.key = key; self.name = name; self.group = group; self.celsius = celsius
    }
}

public struct HardwareSnapshot: Codable {
    public var timestamp: Date
    public var fans: [FanReading]
    public var sensors: [SensorReading]
    public init(timestamp: Date = Date(), fans: [FanReading], sensors: [SensorReading]) {
        self.timestamp = timestamp; self.fans = fans; self.sensors = sensors
    }
}

public enum FanMode: String, Codable, CaseIterable, Identifiable {
    case automatic, fixed, sensor
    public var id: String { rawValue }
    public var title: String {
        switch self { case .automatic: return "系統自動"; case .fixed: return "固定轉速"; case .sensor: return "依溫度調整" }
    }
}

public struct FanRule: Codable, Identifiable, Equatable {
    public var id: Int { fanID }
    public var fanID: Int
    public var mode: FanMode
    public var rpm: Double
    public var sensorKey: String
    public var lowerTemperature: Double
    public var upperTemperature: Double
    public init(fanID: Int, mode: FanMode = .automatic, rpm: Double = 3000, sensorKey: String = "", lowerTemperature: Double = 50, upperTemperature: Double = 80) {
        self.fanID = fanID; self.mode = mode; self.rpm = rpm; self.sensorKey = sensorKey
        self.lowerTemperature = lowerTemperature; self.upperTemperature = upperTemperature
    }
    public func validate(for fan: FanReading, sensorKeys: Set<String>) throws {
        try validateHardware(fan)
        if mode == .fixed {
            guard rpm.isFinite, (fan.minimumRPM...fan.maximumRPM).contains(rpm) else {
                throw FanError.invalid("轉速必須介於 \(Int(fan.minimumRPM))–\(Int(fan.maximumRPM)) RPM。")
            }
        }
        if mode == .sensor {
            try validateTemperatures()
            guard sensorKeys.contains(sensorKey) else { throw FanError.invalid("所選感測器無有效讀值。") }
        }
    }
    public func target(for fan: FanReading, temperature: Double?) throws -> Double? {
        try validateHardware(fan)
        switch mode {
        case .automatic: return nil
        case .fixed:
            guard rpm.isFinite else { throw FanError.invalid("轉速必須是有限數值。") }
            return min(fan.maximumRPM, max(fan.minimumRPM, rpm))
        case .sensor:
            try validateTemperatures()
            guard let temperature, temperature.isFinite, temperature > 0, temperature < 130 else {
                throw FanError.invalid("感測器讀值失效，已要求回復系統自動。")
            }
            let ratio = min(1, max(0, (temperature - lowerTemperature) / (upperTemperature - lowerTemperature)))
            let rounded = (fan.minimumRPM + ratio * (fan.maximumRPM - fan.minimumRPM)).rounded()
            return min(fan.maximumRPM, max(fan.minimumRPM, rounded))
        }
    }

    private func validateHardware(_ fan: FanReading) throws {
        guard (0..<10).contains(fanID), fanID == fan.id,
              fan.minimumRPM.isFinite, fan.maximumRPM.isFinite,
              fan.minimumRPM >= 0, fan.maximumRPM > fan.minimumRPM, fan.maximumRPM < 20_000 else {
            throw FanError.invalid("無法確認風扇硬體範圍。")
        }
    }

    private func validateTemperatures() throws {
        guard lowerTemperature.isFinite, upperTemperature.isFinite,
              lowerTemperature >= 20, upperTemperature <= 95, upperTemperature - lowerTemperature >= 5 else {
            throw FanError.invalid("升速與全速溫度需相差至少 5°C，介於 20–95°C。")
        }
    }
}

public struct FanPreset: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var rules: [FanRule]
    public init(id: UUID = UUID(), name: String, rules: [FanRule]) { self.id = id; self.name = name; self.rules = rules }
}

public enum FanError: LocalizedError {
    case invalid(String), hardware(String), helper(String)
    public var errorDescription: String? {
        switch self { case .invalid(let s), .hardware(let s), .helper(let s): return s }
    }
}

public struct HelperRequest: Codable {
    public enum Action: String, Codable { case status, apply, heartbeat, automatic }
    public var action: Action
    public var rules: [FanRule]
    public init(_ action: Action, rules: [FanRule] = []) { self.action = action; self.rules = rules }
}

public struct HelperResponse: Codable {
    public var success: Bool
    public var message: String
    public var activeRules: [FanRule]
    public var pendingRestoreFanIDs: [Int]
    public var diagnostics: HelperDiagnostics?
    public init(success: Bool, message: String, activeRules: [FanRule] = [], pendingRestoreFanIDs: [Int] = [], diagnostics: HelperDiagnostics? = nil) {
        self.success = success; self.message = message; self.activeRules = activeRules
        self.pendingRestoreFanIDs = pendingRestoreFanIDs
        self.diagnostics = diagnostics
    }
}

@objc public protocol FanHelperProtocol {
    func request(_ payload: Data, withReply reply: @escaping (Data) -> Void)
}
