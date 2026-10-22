import Foundation

/// Actual release sequence, with injectable I/O for failure-ordering tests.
/// Never clear a forced target while the mode is manual or unconfirmed.
enum SMCAutomaticRelease {
    static func run(fanID: Int, writeAutomatic: () throws -> Void,
                    readMode: () throws -> Double, clearTarget: () throws -> Void,
                    pause: () -> Void = { Thread.sleep(forTimeInterval: 0.05) }) throws {
        var failures: [String] = []
        do { try writeAutomatic() } catch { failures.append(error.localizedDescription) }

        func confirmAutomatic() throws {
            var mode = 1.0
            let confirmed = try SMCReadback.wait(attempts: 11, pause: pause) {
                mode = try readMode()
                return mode == 0 || mode == 3
            }
            guard confirmed else {
                throw FanError.hardware("風扇 \(fanID + 1) 自動模式讀回失敗（模式 \(mode)）。")
            }
        }

        do {
            // A failed write may still have reached firmware. Read it back, but
            // retain the original error so recovery cannot report false success.
            try confirmAutomatic()
            do { try clearTarget() } catch { failures.append(error.localizedDescription) }
            // Preserve the final mode verification after the target operation.
            try confirmAutomatic()
        } catch { failures.append(error.localizedDescription) }

        if !failures.isEmpty { throw FanError.hardware(failures.joined(separator: "；")) }
    }
}
