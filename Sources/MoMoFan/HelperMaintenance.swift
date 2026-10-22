import Foundation
import AppKit
import ServiceManagement
import FanCore
import Darwin

/// Explicit maintenance for replacing an already approved embedded helper.
/// Never unregister a service while it owns manual fan control.
@MainActor enum HelperMaintenance {
    static func run() {
        Task { @MainActor in
            let helper = HelperClient()
            let service = SMAppService.daemon(plistName: "tw.momo.MoMoFan.helper.plist")
            var unregistered = false
            do {
                guard NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier)
                    .allSatisfy({ $0.processIdentifier == getpid() }) else {
                    throw FanError.helper("請先結束 MoMo Fan 視窗程式，再重新載入控制服務。")
                }
                guard service.status == .enabled else {
                    throw FanError.helper("控制服務尚未核准，未執行重新載入。")
                }
                let status: HelperResponse = try await withCheckedThrowingContinuation { continuation in
                    helper.send(HelperRequest(.status)) { continuation.resume(with: $0) }
                }
                guard status.success, status.activeRules.isEmpty, status.pendingRestoreFanIDs.isEmpty else {
                    throw FanError.helper("控制服務有作用中規則或待復原風扇，未重新載入。")
                }
                let snapshot = try SMCClient().snapshot()
                guard !snapshot.fans.isEmpty, snapshot.fans.allSatisfy({ !$0.isManual }) else {
                    throw FanError.helper("風扇未全部回復系統自動，未重新載入。")
                }
                helper.invalidate()
                // The async form completes only after launchd has reaped the old process.
                try await service.unregister()
                unregistered = true
                // Background Task Management can briefly lag after launchd has reaped the
                // old helper. Retry only an unregistered service, never an approval gate.
                for attempt in 0..<3 {
                    do { try service.register(); break }
                    catch {
                        guard attempt < 2, service.status == .notRegistered else { throw error }
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
                guard service.status == .enabled else {
                    throw FanError.helper("服務重新登錄後仍未啟用，請確認 macOS 背景活動核准狀態。")
                }
                let updated: HelperResponse = try await withCheckedThrowingContinuation { continuation in
                    helper.send(HelperRequest(.status)) { continuation.resume(with: $0) }
                }
                guard updated.success, updated.activeRules.isEmpty, updated.pendingRestoreFanIDs.isEmpty else {
                    throw FanError.helper("新版服務尚未確認自動狀態。")
                }
                let restored = try SMCClient().snapshot()
                guard Set(restored.fans.map(\.id)) == Set(snapshot.fans.map(\.id)),
                      restored.fans.allSatisfy({ !$0.isManual }) else {
                    throw FanError.helper("重新登錄後的獨立風扇回讀未全部為自動。")
                }
                emit(success: service.status == .enabled, unregistered: unregistered,
                     status: service.status, message: "已重新註冊控制服務、確認 XPC 連線與全部風扇自動狀態。")
            } catch {
                helper.invalidate()
                emit(success: false, unregistered: unregistered, status: service.status,
                     message: error.localizedDescription)
            }
        }
    }

    private static func emit(success: Bool, unregistered: Bool,
                             status: SMAppService.Status, message: String) {
        let result: [String: Any] = ["success": success, "oldServiceUnregistered": unregistered,
                                    "serviceStatus": status.rawValue, "message": message]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        exit(success ? 0 : 1)
    }
}
