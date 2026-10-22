import Foundation

/// Firmware may acknowledge a write before exposing the new value to readers.
/// Poll only: never repeat the write, suppress an I/O error, or accept a mismatch.
enum SMCReadback {
    static func wait(attempts: Int = 21,
                     pause: () -> Void = { Thread.sleep(forTimeInterval: 0.05) },
                     matches: () throws -> Bool) throws -> Bool {
        guard attempts > 0 else { return false }
        for attempt in 0..<attempts {
            if try matches() { return true }
            if attempt + 1 < attempts { pause() }
        }
        return false
    }
}
