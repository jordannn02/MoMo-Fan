import Foundation
import CSMC

/// Readings are available to a normal user. Writes require an approved privileged helper.
/// The lock spans complete read/write/verify transactions; C also serializes IOKit calls.
public final class SMCClient {
    private let connection: OpaquePointer
    private let lock = NSRecursiveLock()
    private var modeKeys: [Int: String] = [:]
    private var missingSensorKeys = Set<String>()
    private var expectedCPUSensors = Set<String>()
    private var expectedGPUSensors = Set<String>()

    public init() throws {
        var error = CSMCError()
        guard let connection = CSMCOpen(&error) else { throw Failure(error, operation: "開啟連線") }
        self.connection = connection
    }

    deinit { CSMCClose(connection) }

    /// nil reads all known sensors; an empty set reads only fans. Aggregate keys
    /// expand to all known members so a missing hot core cannot lower a maximum.
    public func snapshot(sensorKeys: Set<String>? = nil) throws -> HardwareSnapshot {
        lock.lock(); defer { lock.unlock() }
        let fans = try (0..<fanCount()).map { try readFan($0) }
        let includeCPU = sensorKeys == nil || sensorKeys!.contains("CPU_MAX")
        let includeGPU = sensorKeys == nil || sensorKeys!.contains("GPU_MAX")
        var sensors: [SensorReading] = []
        var cpu: [SensorReading] = []
        var gpu: [SensorReading] = []
        var invalidCPU = false
        var invalidGPU = false
        let selectedSensors = Self.knownSensors.filter { sensor in
            sensorKeys == nil || sensorKeys!.contains(sensor.key)
                || (includeCPU && sensor.group == "CPU") || (includeGPU && sensor.group == "GPU")
        }
        for sensor in selectedSensors where !missingSensorKeys.contains(sensor.key) {
            do {
                let value = try number(sensor.key)
                // Zero, NaN, and firmware sentinel values must not drive a fan rule.
                guard value.isFinite, value > 0, value < 130 else {
                    if sensor.group == "CPU" { invalidCPU = true }
                    if sensor.group == "GPU" { invalidGPU = true }
                    continue
                }
                let reading = SensorReading(key: sensor.key, name: sensor.name,
                                            group: sensor.group, celsius: value)
                sensors.append(reading)
                if sensor.group == "CPU" { cpu.append(reading); expectedCPUSensors.insert(sensor.key) }
                if sensor.group == "GPU" { gpu.append(reading); expectedGPUSensors.insert(sensor.key) }
            } catch let failure as Failure where failure.isMissingKeyInfo {
                // Only an explicit metadata 'not found' result marks a key absent.
                missingSensorKeys.insert(sensor.key)
            } catch {
                // A failed sensor is omitted from THIS snapshot, never replaced with an old value.
                if sensor.group == "CPU" { invalidCPU = true }
                if sensor.group == "GPU" { invalidGPU = true }
                continue
            }
        }
        // Once discovered, every member must read successfully for the aggregate to exist.
        // Otherwise a missing hot core could silently lower a control temperature.
        if includeCPU, !invalidCPU, !cpu.isEmpty, Set(cpu.map(\.key)) == expectedCPUSensors,
           let hottest = cpu.map(\.celsius).max() {
            sensors.insert(SensorReading(key: "CPU_MAX", name: "CPU 最高溫", group: "CPU", celsius: hottest), at: 0)
        }
        if includeGPU, !invalidGPU, !gpu.isEmpty, Set(gpu.map(\.key)) == expectedGPUSensors,
           let hottest = gpu.map(\.celsius).max() {
            let index = sensors.first?.key == "CPU_MAX" ? 1 : 0
            sensors.insert(SensorReading(key: "GPU_MAX", name: "GPU 最高溫", group: "GPU", celsius: hottest), at: index)
        }
        return HardwareSnapshot(timestamp: Date(), fans: fans, sensors: sensors)
    }

    public func setManual(fanID: Int, rpm: Double) throws {
        lock.lock(); defer { lock.unlock() }
        try validateFanID(fanID)
        let fan = try readFan(fanID)
        guard rpm.isFinite, rpm >= fan.minimumRPM, rpm <= fan.maximumRPM else {
            throw FanError.invalid("風扇 \(fanID + 1) 轉速需介於 \(Int(fan.minimumRPM))–\(Int(fan.maximumRPM)) RPM。")
        }
        let mode = try modeKey(fanID)
        let target = "F\(fanID)Tg"
        // Validate BOTH payload formats before changing either key.
        let modeBytes = try encoded(1, for: mode)
        let targetBytes = try encoded(rpm, for: target)
        do {
            if !fan.isManual { try write(mode, bytes: modeBytes) }
            try write(target, bytes: targetBytes)
            var actualMode = 0.0, actualTarget = 0.0
            let applied = try SMCReadback.wait {
                actualMode = try number(mode)
                actualTarget = try number(target)
                return actualMode == 1 && abs(actualTarget - rpm) <= 0.5
            }
            guard applied else {
                throw FanError.hardware("風扇 \(fanID + 1) 手動設定讀回不符（模式 \(actualMode)，目標 \(actualTarget) RPM）。")
            }
        } catch {
            let original = error.localizedDescription
            do { try setAutomaticUnchecked(fanID) }
            catch { throw FanError.hardware("\(original)；自動還原亦失敗：\(error.localizedDescription)") }
            throw FanError.hardware("\(original)；已回復系統自動。")
        }
    }

    public func setAutomatic(fanID: Int) throws {
        lock.lock(); defer { lock.unlock() }
        // A previously owned fan must still be releasable if FNum/current RPM fail.
        // The key metadata and automatic-mode readback remain mandatory.
        guard (0..<10).contains(fanID) else { throw FanError.invalid("風扇識別碼超出支援範圍。") }
        try setAutomaticUnchecked(fanID)
    }

    public func fanIDs() throws -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return Array(0..<(try fanCount()))
    }

    public func restoreAll() throws {
        lock.lock(); defer { lock.unlock() }
        let count = try fanCount()
        var failures: [String] = []
        // Attempt every fan even if one fails, and report all failures to the helper.
        for id in 0..<count {
            do { try setAutomaticUnchecked(id) }
            catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { throw FanError.hardware(failures.joined(separator: "；")) }
    }

    private func setAutomaticUnchecked(_ fanID: Int) throws {
        let mode = try modeKey(fanID)
        let target = "F\(fanID)Tg"
        try SMCAutomaticRelease.run(fanID: fanID,
            writeAutomatic: { try write(mode, bytes: encoded(0, for: mode)) },
            readMode: { try number(mode) },
            clearTarget: { try write(target, bytes: encoded(0, for: target)) })
    }

    private func fanCount() throws -> Int {
        let count = try number("FNum")
        guard count.isFinite, count >= 1, count <= 10, count.rounded() == count else {
            throw FanError.hardware("AppleSMC 回報無效風扇數量：\(count)。")
        }
        return Int(count)
    }

    private func validateFanID(_ id: Int) throws {
        guard id >= 0, id < (try fanCount()) else { throw FanError.invalid("找不到風扇 \(id + 1)。") }
    }

    private func readFan(_ id: Int) throws -> FanReading {
        let prefix = "F\(id)"
        let current = try number(prefix + "Ac")
        let minimum = try number(prefix + "Mn")
        let maximum = try number(prefix + "Mx")
        let target = try number(prefix + "Tg")
        let mode = try number(modeKey(id))
        guard [current, minimum, maximum, target].allSatisfy(\.isFinite),
              minimum >= 0, maximum > minimum, maximum < 20_000,
              current >= 0, current < 20_000, target >= 0, target < 20_000,
              mode == 0 || mode == 1 || mode == 3 else {
            throw FanError.hardware("風扇 \(id + 1) 回報無效轉速範圍或模式，未沿用舊讀值。")
        }
        return FanReading(id: id, name: "風扇 \(id + 1)", currentRPM: current,
                          minimumRPM: minimum, maximumRPM: maximum, targetRPM: target, isManual: mode == 1)
    }

    private func modeKey(_ id: Int) throws -> String {
        if let cached = modeKeys[id] { return cached }
        let lower = "F\(id)md"
        let upper = "F\(id)Md"
        let chosen: String
        do { _ = try info(lower); chosen = lower }
        catch let failure as Failure where failure.isMissingKeyInfo {
            _ = try info(upper); chosen = upper
        }
        let metadata = try info(chosen)
        guard metadata.size == 1, metadata.dataType == Self.fourCC("ui8 ") else {
            throw FanError.hardware("\(chosen) 不是支援的 ui8 模式鍵。")
        }
        modeKeys[id] = chosen
        return chosen
    }

    private func info(_ key: String) throws -> CSMCKeyInfo {
        var result = CSMCKeyInfo(), error = CSMCError()
        if CSMCGetKeyInfo(connection, Self.fourCC(key), &result, &error) != 0 {
            throw Failure(error, operation: "\(key) 讀取格式")
        }
        return result
    }

    private func number(_ key: String) throws -> Double {
        var value = CSMCValue(), error = CSMCError()
        if CSMCRead(connection, Self.fourCC(key), &value, &error) != 0 {
            throw Failure(error, operation: "\(key) 讀取")
        }
        let bytes = withUnsafeBytes(of: value.bytes) { Array($0.prefix(Int(value.info.size))) }
        switch (value.info.dataType, value.info.size) {
        case (Self.fourCC("flt "), 4):
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case (Self.fourCC("ui8 "), 1): return Double(bytes[0])
        case (Self.fourCC("ui16"), 2): return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case (Self.fourCC("ui32"), 4):
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case (Self.fourCC("sp78"), 2): return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case (Self.fourCC("fpe2"), 2): return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        default: throw FanError.hardware("\(key) 的資料型別或長度不受支援。")
        }
    }

    private func encoded(_ value: Double, for key: String) throws -> [UInt8] {
        guard value.isFinite, value >= 0 else { throw FanError.invalid("無效寫入數值。") }
        let metadata = try info(key)
        switch (metadata.dataType, metadata.size) {
        case (Self.fourCC("ui8 "), 1):
            guard key.hasSuffix("md") || key.hasSuffix("Md"), value == 0 || value == 1 else {
                throw FanError.invalid("只允許自動或手動模式。")
            }
            return [UInt8(value)]
        case (Self.fourCC("flt "), 4):
            guard key.hasSuffix("Tg"), value < 20_000 else { throw FanError.invalid("無效風扇目標。") }
            let bits = Float(value).bitPattern
            return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8),
                    UInt8(truncatingIfNeeded: bits >> 16), UInt8(truncatingIfNeeded: bits >> 24)]
        case (Self.fourCC("fpe2"), 2):
            guard key.hasSuffix("Tg"), value <= 16383.75 else { throw FanError.invalid("無效風扇目標。") }
            let bits = UInt16((value * 4).rounded())
            return [UInt8(truncatingIfNeeded: bits >> 8), UInt8(truncatingIfNeeded: bits)]
        default: throw FanError.hardware("\(key) 的資料格式不允許寫入。")
        }
    }

    private func write(_ key: String, bytes: [UInt8]) throws {
        var error = CSMCError()
        let result = bytes.withUnsafeBufferPointer { CSMCWrite(connection, Self.fourCC(key), $0.baseAddress, UInt32($0.count), &error) }
        if result != 0 { throw Failure(error, operation: "\(key) 寫入") }
    }

    private static func fourCC(_ key: String) -> UInt32 {
        precondition(key.utf8.count == 4, "SMC keys must have four ASCII bytes")
        return key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private struct Failure: LocalizedError {
        let raw: CSMCError
        let operation: String
        init(_ raw: CSMCError, operation: String) { self.raw = raw; self.operation = operation }
        var isMissingKeyInfo: Bool { raw.kernelCode == 0 && raw.smcResult == 0x84 && raw.command == 9 }
        var errorDescription: String? {
            "AppleSMC \(operation)失敗：kernel \(String(format: "0x%08x", raw.kernelCode))，SMC \(String(format: "0x%02x", raw.smcResult))，command \(raw.command)。"
        }
    }

    private struct SensorSpec {
        let key: String, name: String, group: String
    }

    // Stats' M5 map, checked against this Mac17,8. Unknown T* keys are excluded.
    // These labels are reverse-engineered, not an Apple-published sensor contract.
    private static let knownSensors: [SensorSpec] = {
        let cpuSuper = ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K"]
        let cpuPerformance = ["Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        let gpu = ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]
        var result = cpuSuper.enumerated().map { SensorSpec(key: $0.element, name: "CPU Super \($0.offset + 1)", group: "CPU") }
        result += cpuPerformance.enumerated().map { SensorSpec(key: $0.element, name: "CPU Performance \($0.offset + 1)", group: "CPU") }
        result += gpu.enumerated().map { SensorSpec(key: $0.element, name: "GPU \($0.offset + 1)", group: "GPU") }
        result += [
            SensorSpec(key: "TB1T", name: "電池 1", group: "其他"),
            SensorSpec(key: "TB2T", name: "電池 2", group: "其他"),
            SensorSpec(key: "TH0x", name: "SSD / NAND", group: "其他"),
            SensorSpec(key: "TaLP", name: "左側氣流", group: "其他"),
            SensorSpec(key: "TaRF", name: "右側氣流", group: "其他"),
            SensorSpec(key: "TW0P", name: "Wi-Fi", group: "其他")
        ]
        return result
    }()
}
