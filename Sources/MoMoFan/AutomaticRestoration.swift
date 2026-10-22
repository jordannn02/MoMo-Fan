import Foundation
import FanCore
import Darwin

/// Explicit operator recovery. It never enables manual control.
@MainActor enum AutomaticRestoration {
    static func run() {
        let helper = HelperClient()
        var finished = false
        func emit(_ object: [String: Any], success: Bool) {
            guard !finished else { return }; finished = true
            helper.invalidate()
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            exit(success ? 0 : 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            emit(["success": false, "message": "復原驗證逾時，不能宣稱硬體已回復自動。"], success: false)
        }
        helper.send(HelperRequest(.automatic)) { result in
            do {
                let response = try result.get()
                let snapshot = try SMCClient().snapshot()
                let ok = response.success && response.activeRules.isEmpty && response.pendingRestoreFanIDs.isEmpty
                    && !snapshot.fans.isEmpty && snapshot.fans.allSatisfy { !$0.isManual }
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                let responseJSON = try JSONSerialization.jsonObject(with: encoder.encode(response))
                let snapshotJSON = try JSONSerialization.jsonObject(with: encoder.encode(snapshot))
                emit(["success": ok, "response": responseJSON, "independentSnapshot": snapshotJSON], success: ok)
            } catch {
                emit(["success": false, "message": error.localizedDescription], success: false)
            }
        }
    }
}
