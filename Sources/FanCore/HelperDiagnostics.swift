import Foundation

/// Values sampled by the helper from its own PID; no caller-selected process access.
public struct HelperResourceUsage: Codable {
    public var sampledAt: Date
    public var userTimeNanoseconds: UInt64
    public var systemTimeNanoseconds: UInt64
    public var interruptWakeups: UInt64
    public var packageIdleWakeups: UInt64
    public var physicalFootprintBytes: UInt64
    public var diskBytesRead: UInt64
    public var diskBytesWritten: UInt64

    public init(sampledAt: Date = Date(), userTimeNanoseconds: UInt64, systemTimeNanoseconds: UInt64,
                interruptWakeups: UInt64, packageIdleWakeups: UInt64, physicalFootprintBytes: UInt64,
                diskBytesRead: UInt64, diskBytesWritten: UInt64) {
        self.sampledAt = sampledAt
        self.userTimeNanoseconds = userTimeNanoseconds; self.systemTimeNanoseconds = systemTimeNanoseconds
        self.interruptWakeups = interruptWakeups; self.packageIdleWakeups = packageIdleWakeups
        self.physicalFootprintBytes = physicalFootprintBytes
        self.diskBytesRead = diskBytesRead; self.diskBytesWritten = diskBytesWritten
    }
}

/// Read-only evidence; targets are only values whose hardware write was confirmed.
public struct HelperDiagnostics: Codable {
    public var helperPID: Int32
    public var buildIdentifier: String
    public var timerScheduled = false
    public var powerSuspended = false
    public var sleepCount = 0
    public var wakeCount = 0
    public var sleepAcknowledgementTimeouts = 0
    public var lastRestoreReason: String?
    public var lastRestoreAt: Date?
    public var journalError: String?
    public var lastTargets: [Int: Double] = [:]
    public var lastTemperatures: [String: Double] = [:]
    public var controlTickCount = 0
    public var timerTargetUpdateCount = 0
    public var lastControlTickAt: Date?
    public var resources: HelperResourceUsage?

    public init(helperPID: Int32, buildIdentifier: String) {
        self.helperPID = helperPID; self.buildIdentifier = buildIdentifier
    }
}
