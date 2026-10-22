import AppKit
import Combine
import ServiceManagement
import FanCore

struct HistoryPoint: Identifiable {
    let id = UUID()
    let time: Date
    let cpu: Double?
    let gpu: Double?
    let rpm: Double
}

@MainActor final class HelperClient {
    private struct PendingRequest {
        let generation: UInt64
        let timeout: DispatchSourceTimer
        let completion: (Result<HelperResponse, Error>) -> Void
    }

    private var connection: NSXPCConnection?
    private var generation: UInt64 = 0
    private var pending: [UUID: PendingRequest] = [:]

    deinit {
        connection?.invalidate()
        for request in pending.values { request.timeout.cancel() }
    }

    func invalidate() {
        disconnect(generation: generation, error: FanError.helper("控制連線已關閉。"))
    }

    func send(_ request: HelperRequest, completion: @escaping (Result<HelperResponse, Error>) -> Void) {
        let data: Data
        do { data = try JSONEncoder().encode(request) }
        catch { completion(.failure(error)); return }
        if connection == nil {
            generation &+= 1
            let connectionGeneration = generation
            let connection = NSXPCConnection(machServiceName: helperServiceName, options: .privileged)
            connection.setCodeSigningRequirement("anchor apple generic and identifier \"\(helperServiceName)\" and certificate leaf[subject.OU] = \"\(signingTeamIdentifier)\"")
            connection.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
            connection.interruptionHandler = { [weak self] in
                DispatchQueue.main.async {
                    self?.disconnect(generation: connectionGeneration, error: FanError.helper("控制服務連線中斷。"))
                }
            }
            connection.invalidationHandler = { [weak self] in
                DispatchQueue.main.async {
                    self?.disconnect(generation: connectionGeneration, error: FanError.helper("控制服務連線已失效。"))
                }
            }
            self.connection = connection
            connection.resume()
        }

        let requestID = UUID()
        let connectionGeneration = generation
        let timeout = DispatchSource.makeTimerSource(queue: .main)
        timeout.schedule(deadline: .now() + 4, leeway: .milliseconds(100))
        timeout.setEventHandler { [weak self] in
            guard let self, self.pending[requestID] != nil else { return }
            self.disconnect(generation: connectionGeneration, error: FanError.helper("控制服務未回應；失聯保護會要求回復系統自動。"))
        }
        pending[requestID] = PendingRequest(generation: connectionGeneration, timeout: timeout, completion: completion)
        timeout.resume()

        let proxy = connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.pending[requestID] != nil else { return }
                self.disconnect(generation: connectionGeneration, error: error)
            }
        } as? FanHelperProtocol
        guard let proxy else {
            disconnect(generation: connectionGeneration, error: FanError.helper("無法連線至控制服務。"))
            return
        }
        proxy.request(data) { [weak self] data in
            let result = Result { try JSONDecoder().decode(HelperResponse.self, from: data) }
            DispatchQueue.main.async {
                self?.complete(requestID, with: result)
            }
        }
    }

    private func complete(_ requestID: UUID, with result: Result<HelperResponse, Error>) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.timeout.cancel()
        request.completion(result)
    }

    private func disconnect(generation disconnectedGeneration: UInt64, error: Error) {
        // An invalidation callback from a retired connection must not close its replacement.
        if generation == disconnectedGeneration {
            let retired = connection
            connection = nil
            retired?.invalidate()
        }
        let affected = pending.filter { $0.value.generation == disconnectedGeneration }
        for (id, request) in affected {
            pending.removeValue(forKey: id)
            request.timeout.cancel()
        }
        // Remove all old requests before callbacks, which may immediately reconnect.
        for request in affected.values { request.completion(.failure(error)) }
    }
}

private final class HardwareReader {
    private let queue = DispatchQueue(label: "tw.momo.MoMoFan.read", qos: .utility)
    private var smc: SMCClient?
    func read(_ completion: @escaping (Result<HardwareSnapshot, Error>) -> Void) {
        queue.async {
            let result: Result<HardwareSnapshot, Error>
            do {
                if self.smc == nil { self.smc = try SMCClient() }
                result = .success(try self.smc!.snapshot())
            } catch {
                self.smc = nil
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var snapshot: HardwareSnapshot?
    @Published var rules: [FanRule] = []
    @Published var presets: [FanPreset] = []
    @Published var helperReady = false
    @Published var helperStatus = "監看模式 · 尚未啟用控制服務"
    @Published var message = ""
    @Published var isBusy = false
    @Published var activePresetName = "等待確認風扇模式"
    @Published private var confirmedActiveRules: [FanRule] = []
    @Published var history: [HistoryPoint] = []
    @Published var sensorFilter = ""
    @Published private(set) var menuTitle = ""
    @Published var menuIconOnly: Bool {
        didSet {
            guard menuIconOnly != oldValue else { return }
            defaults.set(menuIconOnly, forKey: "menuIconOnly")
            updateMenuTitle(); configurePolling()
        }
    }
    @Published var usesFahrenheit: Bool {
        didSet {
            guard usesFahrenheit != oldValue else { return }
            defaults.set(usesFahrenheit, forKey: "fahrenheit"); updateMenuTitle()
        }
    }
    @Published var menuSensorKey: String {
        didSet {
            guard menuSensorKey != oldValue else { return }
            defaults.set(menuSensorKey, forKey: "menuSensor"); updateMenuTitle()
        }
    }
    @Published var menuFanID: Int {
        didSet {
            guard menuFanID != oldValue else { return }
            defaults.set(menuFanID, forKey: "menuFan"); updateMenuTitle()
        }
    }
    @Published var showMenuTemperature: Bool {
        didSet {
            guard showMenuTemperature != oldValue else { return }
            defaults.set(showMenuTemperature, forKey: "menuTemperature")
            updateMenuTitle(); configurePolling()
        }
    }
    @Published var showMenuRPM: Bool {
        didSet {
            guard showMenuRPM != oldValue else { return }
            defaults.set(showMenuRPM, forKey: "menuRPM")
            updateMenuTitle(); configurePolling()
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue, !synchronizingLoginSetting else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                update(\.message, to: "登入時啟動設定失敗：\(error.localizedDescription)")
                refreshLoginSetting()
            }
        }
    }
    let machineName: String
    private let defaults = UserDefaults.standard
    private var presetStoreReadable = true
    private let reader = HardwareReader()
    private let helper = HelperClient()
    private var hardwareTimer: Timer?
    private var helperTimer: Timer?
    private var hardwareTimerInterval: TimeInterval?
    private var helperTimerInterval: TimeInterval?
    @Published private(set) var mainWindowVisible = false
    private var popoverVisible = false
    private var stopped = false
    private var synchronizingLoginSetting = false
    private var latestSnapshot: HardwareSnapshot?
    private var isReading = false
    private var helperPendingID: UUID?
    private var helperRetryInterval: TimeInterval = 30
    private var controlRevision: UInt64 = 0
    private var sleeping = false
    private var hasActiveControl = false {
        didSet {
            if !hasActiveControl { update(\.confirmedActiveRules, to: []) }
            if hasActiveControl != oldValue { configurePolling() }
        }
    }
    private var awaitingRestore = false
    private var didInitializeRules = false
    private var observers: [NSObjectProtocol] = []

    private var interfaceVisible: Bool { mainWindowVisible || popoverVisible }
    private var showsMenuReadings: Bool { !menuIconOnly && (showMenuTemperature || showMenuRPM) }

    var filteredSensors: [SensorReading] {
        let values = snapshot?.sensors ?? []
        guard !sensorFilter.isEmpty else { return values }
        return values.filter { "\($0.name) \($0.key) \($0.group)".localizedCaseInsensitiveContains(sensorFilter) }
    }
    var hottestCPU: Double? { snapshot?.sensors.first(where: { $0.key == "CPU_MAX" })?.celsius }
    var hottestGPU: Double? { snapshot?.sensors.first(where: { $0.key == "GPU_MAX" })?.celsius }

    init() {
        menuIconOnly = defaults.object(forKey: "menuIconOnly") as? Bool ?? true
        usesFahrenheit = defaults.bool(forKey: "fahrenheit")
        menuSensorKey = defaults.string(forKey: "menuSensor") ?? "CPU_MAX"
        menuFanID = defaults.integer(forKey: "menuFan")
        showMenuTemperature = defaults.object(forKey: "menuTemperature") as? Bool ?? true
        showMenuRPM = defaults.object(forKey: "menuRPM") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        machineName = String(cString: bytes)
        if let data = defaults.data(forKey: "presets") {
            do { presets = try JSONDecoder().decode([FanPreset].self, from: data) }
            catch {
                presetStoreReadable = false
                message = "預設檔無法載入，原始資料仍保留：\(error.localizedDescription)"
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.sleeping = true
                self.configurePolling()
                self.releaseControl {}
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.sleeping = false
                self.releaseControl {}
                self.update(\.activePresetName, to: "等待確認風扇模式")
                self.configurePolling()
                self.poll()
            }
        })
        configurePolling()
        poll()
    }

    deinit {
        hardwareTimer?.invalidate()
        helperTimer?.invalidate()
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    func temperature(_ c: Double) -> String {
        String(format: "%.1f°%@", usesFahrenheit ? c * 9 / 5 + 32 : c, usesFahrenheit ? "F" : "C")
    }

    private func updateMenuTitle() {
        var parts: [String] = []
        if !menuIconOnly {
            let key = menuSensorKey.isEmpty ? "CPU_MAX" : menuSensorKey
            if showMenuTemperature, let sensor = snapshot?.sensors.first(where: { $0.key == key }) {
                parts.append(temperature(sensor.celsius))
            }
            if showMenuRPM, let fan = snapshot?.fans.first(where: { $0.id == menuFanID }), fan.currentRPM.isFinite {
                parts.append("\(Int(fan.currentRPM)) RPM")
            }
        }
        update(\.menuTitle, to: parts.joined(separator: "  "))
    }

    func setMainWindowVisible(_ visible: Bool) {
        guard visible != mainWindowVisible else { return }
        mainWindowVisible = visible
        visibilityChanged(becameVisible: visible)
    }

    func setPopoverVisible(_ visible: Bool) {
        guard visible != popoverVisible else { return }
        popoverVisible = visible
        visibilityChanged(becameVisible: visible)
    }

    func refreshLoginSetting() {
        synchronizingLoginSetting = true
        update(\.launchAtLogin, to: SMAppService.mainApp.status == .enabled)
        synchronizingLoginSetting = false
    }

    private func visibilityChanged(becameVisible: Bool) {
        configurePolling()
        if becameVisible { poll() }
    }

    private func configurePolling() {
        guard !sleeping, !stopped else {
            hardwareTimer?.invalidate(); hardwareTimer = nil; hardwareTimerInterval = nil
            helperTimer?.invalidate(); helperTimer = nil; helperTimerInterval = nil
            return
        }
        let readInterval: TimeInterval = interfaceVisible || showsMenuReadings ? 2 : 10
        if hardwareTimerInterval != readInterval {
            hardwareTimer?.invalidate()
            let timer = Timer(timeInterval: readInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.readHardware() }
            }
            timer.tolerance = readInterval == 2 ? 0.2 : 2
            RunLoop.main.add(timer, forMode: .common)
            hardwareTimer = timer; hardwareTimerInterval = readInterval
        }
        // Lease heartbeats never inherit the slower background sensor cadence.
        let statusInterval: TimeInterval = hasActiveControl ? 2 : (helperReady ? (interfaceVisible ? 10 : 30) : helperRetryInterval)
        if helperTimerInterval != statusInterval {
            helperTimer?.invalidate()
            let timer = Timer(timeInterval: statusInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollHelper() }
            }
            timer.tolerance = hasActiveControl ? 0.2 : min(3, statusInterval * 0.1)
            RunLoop.main.add(timer, forMode: .common)
            helperTimer = timer; helperTimerInterval = statusInterval
        }
    }

    func poll() {
        readHardware()
        pollHelper()
    }

    private func readHardware() {
        guard !sleeping, !stopped, !isReading else { return }
        isReading = true
        let revision = controlRevision
        reader.read { [weak self] result in
            guard let self else { return }
            self.isReading = false
            guard !self.sleeping, !self.stopped else { return }
            guard self.controlRevision == revision else {
                self.readHardware()
                return
            }
            self.received(result)
        }
    }

    private func pollHelper() {
        guard !sleeping, !stopped, helperPendingID == nil, !isBusy || hasActiveControl else { return }
        // Do not create an XPC timeout loop for a service the user has not enabled.
        if !hasActiveControl && !helperReady && SMAppService.daemon(plistName: "tw.momo.MoMoFan.helper.plist").status != .enabled {
            update(\.helperStatus, to: serviceStatusText)
            return
        }
        let requestID = UUID()
        let revision = controlRevision
        helperPendingID = requestID
        helper.send(HelperRequest(hasActiveControl ? .heartbeat : .status)) { [weak self] result in
            guard let self, self.helperPendingID == requestID else { return }
            self.helperPendingID = nil
            // A heartbeat may keep the lease alive while a command is pending, but
            // its earlier state must not overwrite the command's eventual reply.
            guard self.controlRevision == revision, !self.sleeping, !self.stopped, !self.isBusy else { return }
            switch result {
            case .success(let response):
                self.helperRetryInterval = 30
                self.update(\.helperReady, to: response.success)
                self.update(\.helperStatus, to: response.message)
                self.awaitingRestore = !response.pendingRestoreFanIDs.isEmpty
                if !response.success || !self.sameControlRules(self.confirmedActiveRules, response.activeRules) {
                    self.update(\.confirmedActiveRules, to: [])
                }
                if self.hasActiveControl && response.activeRules.isEmpty {
                    self.controlRevision &+= 1
                    self.hasActiveControl = false
                    self.update(\.activePresetName, to: "等待確認風扇模式")
                    self.update(\.message, to: response.message)
                    self.readHardware()
                }
            case .failure:
                self.helper.invalidate()
                self.update(\.helperReady, to: false)
                self.update(\.helperStatus, to: self.serviceStatusText)
                self.helperRetryInterval = min(60, self.helperRetryInterval * 2)
                if self.hasActiveControl {
                    self.controlRevision &+= 1
                    self.hasActiveControl = false
                    self.awaitingRestore = true
                    self.update(\.activePresetName, to: "控制連線中斷")
                    self.update(\.message, to: "控制服務連線中斷；待重新讀到風扇模式後確認狀態。")
                    self.readHardware()
                }
            }
            self.configurePolling()
        }
    }

    private func received(_ result: Result<HardwareSnapshot, Error>) {
        switch result {
        case .success(let value):
            latestSnapshot = value
            // Timestamp-only changes need not invalidate every SwiftUI view.
            if snapshot?.fans != value.fans || snapshot?.sensors != value.sensors { snapshot = value }
            if !didInitializeRules {
                rules = value.fans.map { FanRule(fanID: $0.id, rpm: min($0.maximumRPM, max($0.minimumRPM, 3000)), sensorKey: "CPU_MAX") }
                didInitializeRules = true
            }
            if !hasActiveControl && !value.fans.contains(where: \.isManual) {
                awaitingRestore = false
                update(\.activePresetName, to: "系統自動")
            } else if !hasActiveControl {
                update(\.activePresetName, to: awaitingRestore ? "回復自動控制中" : "偵測到外部手動控制")
            }
            var recent = history.filter { $0.time >= value.timestamp.addingTimeInterval(-360) && $0.time <= value.timestamp }
            if recent.last.map({ value.timestamp.timeIntervalSince($0.time) >= 1.5 }) ?? true {
                recent.append(HistoryPoint(time: value.timestamp,
                    cpu: value.sensors.first(where: { $0.key == "CPU_MAX" })?.celsius,
                    gpu: value.sensors.first(where: { $0.key == "GPU_MAX" })?.celsius,
                    rpm: value.fans.first?.currentRPM ?? 0))
            }
            if recent.count > 241 { recent.removeFirst(recent.count - 241) }
            if recent.map(\.id) != history.map(\.id) { history = recent }
            updateMenuTitle()
        case .failure(let error):
            latestSnapshot = nil
            if snapshot != nil { snapshot = nil }
            let cutoff = Date().addingTimeInterval(-360)
            if history.first.map({ $0.time < cutoff }) == true { history = history.filter { $0.time >= cutoff } }
            update(\.message, to: "無法讀取硬體：\(error.localizedDescription)")
            updateMenuTitle()
            if hasActiveControl { releaseControl {} }
        }
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>, to value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private var serviceStatusText: String {
        switch SMAppService.daemon(plistName: "tw.momo.MoMoFan.helper.plist").status {
        case .enabled: return "控制服務已註冊，正在連線"
        case .requiresApproval: return "等待 macOS 核准背景控制服務"
        case .notRegistered: return "監看模式 · 尚未啟用控制服務"
        case .notFound: return "控制服務尚未註冊，請按「啟用風扇控制」"
        @unknown default: return "控制服務尚未就緒"
        }
    }

    func enableHelper() {
        guard !isBusy else { return }
        let service = SMAppService.daemon(plistName: "tw.momo.MoMoFan.helper.plist")
        do {
            if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            update(\.helperStatus, to: serviceStatusText)
            if service.status == .requiresApproval {
                update(\.message, to: "請在系統設定允許 MoMo Fan 的背景活動，再回到程式。")
                openLoginSettings()
            } else { update(\.message, to: "正在確認控制服務連線。") }
            controlRevision &+= 1
            helperPendingID = nil
            helper.invalidate()
            helperRetryInterval = 30
            configurePolling()
            poll()
        } catch {
            // Some macOS versions register the item but return EPERM while approval is pending.
            if service.status == .requiresApproval {
                helperStatus = serviceStatusText
                message = "請在系統設定允許 MoMo Fan 的背景活動，再回到程式。"
                openLoginSettings()
            } else { message = "啟用控制服務失敗：\(error.localizedDescription)" }
        }
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    func applyRules() { apply(rules, name: "自訂調整") }

    private func apply(_ proposed: [FanRule], name: String) {
        guard helperReady, !isBusy, !sleeping, !stopped, let snapshot else { message = "請先啟用控制服務並等待硬體讀值。"; return }
        do {
            guard proposed.count == snapshot.fans.count, Set(proposed.map(\.fanID)) == Set(snapshot.fans.map(\.id)) else { throw FanError.invalid("預設檔與這台 Mac 的風扇不符。") }
            for rule in proposed { try rule.validate(for: snapshot.fans.first(where: { $0.id == rule.fanID })!, sensorKeys: Set(snapshot.sensors.map(\.key))) }
        } catch { message = error.localizedDescription; return }
        controlRevision &+= 1
        let revision = controlRevision
        let wasControlling = hasActiveControl
        update(\.isBusy, to: true)
        helper.send(HelperRequest(.apply, rules: proposed)) { [weak self] result in
            guard let self, self.controlRevision == revision else { return }
            self.controlRevision &+= 1
            self.update(\.isBusy, to: false)
            switch result {
            case .success(let response):
                self.update(\.message, to: response.message)
                self.update(\.helperStatus, to: response.message)
                // A rejected request can report another client's active rules.
                self.hasActiveControl = !response.activeRules.isEmpty && (response.success || wasControlling)
                self.awaitingRestore = !response.pendingRestoreFanIDs.isEmpty
                self.update(\.confirmedActiveRules, to: response.success && self.hasActiveControl ? response.activeRules : [])
                if response.success { self.update(\.rules, to: proposed) }
                if response.success || !self.hasActiveControl {
                    self.update(\.activePresetName, to: self.hasActiveControl ? name : "等待確認風扇模式")
                }
            case .failure(let error): self.commandFailed(error, wasControlling: wasControlling)
            }
            self.configurePolling()
            self.readHardware()
            if case .success = result { self.pollHelper() }
        }
    }

    func setAllAutomatic() {
        guard helperReady, !isBusy, !sleeping, !stopped else { message = "請先啟用控制服務。"; return }
        controlRevision &+= 1
        let revision = controlRevision
        let wasControlling = hasActiveControl
        update(\.isBusy, to: true)
        helper.send(HelperRequest(.automatic)) { [weak self] result in
            guard let self, self.controlRevision == revision else { return }
            self.controlRevision &+= 1
            self.update(\.isBusy, to: false)
            switch result {
            case .success(let response):
                self.update(\.message, to: response.message)
                self.update(\.helperStatus, to: response.message)
                self.hasActiveControl = wasControlling && !response.activeRules.isEmpty
                self.awaitingRestore = !response.pendingRestoreFanIDs.isEmpty
                self.update(\.confirmedActiveRules, to: [])
                if !self.hasActiveControl { self.update(\.activePresetName, to: "等待確認風扇模式") }
                if response.success {
                    self.update(\.rules, to: self.rules.map { var rule = $0; rule.mode = .automatic; return rule })
                }
            case .failure(let error): self.commandFailed(error, wasControlling: wasControlling)
            }
            self.configurePolling()
            self.readHardware()
            if case .success = result { self.pollHelper() }
        }
    }

    private func commandFailed(_ error: Error, wasControlling: Bool) {
        update(\.message, to: error.localizedDescription)
        update(\.helperReady, to: false)
        update(\.helperStatus, to: serviceStatusText)
        hasActiveControl = false
        // A timed-out apply may have reached the service before its reply was lost.
        awaitingRestore = true
        update(\.activePresetName, to: wasControlling ? "控制連線中斷" : "等待確認風扇模式")
        helperRetryInterval = 60
        helper.invalidate()
    }

    func setMaximum() {
        guard let snapshot else { return }
        apply(snapshot.fans.map { FanRule(fanID: $0.id, mode: .fixed, rpm: $0.maximumRPM, sensorKey: "CPU_MAX") }, name: "全速散熱")
    }

    @discardableResult
    func savePreset(name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { message = "請輸入 1–40 字的預設檔名稱。"; return false }
        do {
            try persistPresets(presets + [FanPreset(name: name, rules: rules)])
            message = "已儲存「\(name)」；套用後才會改變轉速。"
            return true
        } catch {
            message = "無法儲存預設檔：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func saveFixedPreset(id: UUID? = nil, name: String, rpms: [Int: String]) -> Bool {
        do {
            if let id, !presets.contains(where: { $0.id == id }) {
                throw FanError.invalid("這個預設檔已不存在，請重新選擇或新增。")
            }
            guard let snapshot = latestSnapshot, !snapshot.fans.isEmpty else {
                throw FanError.invalid("請先等待風扇讀值，再儲存預設檔。")
            }
            let fans = snapshot.fans.sorted { $0.id < $1.id }
            let fanIDs = Set(fans.map(\.id))
            guard fanIDs.count == fans.count, Set(rpms.keys) == fanIDs else {
                throw FanError.invalid("轉速欄位與這台 Mac 的風扇不符，請重新填寫。")
            }
            var fixedRules: [FanRule] = []
            var rpmNames: [String] = []
            for fan in fans {
                let input = (rpms[fan.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !input.isEmpty, input.utf8.allSatisfy({ (48...57).contains($0) }), let rpm = Int(input) else {
                    throw FanError.invalid("\(fan.name)：請輸入有效的整數 RPM。")
                }
                let rule = FanRule(fanID: fan.id, mode: .fixed, rpm: Double(rpm))
                do { try rule.validate(for: fan, sensorKeys: []) }
                catch { throw FanError.invalid("\(fan.name)：\(error.localizedDescription)") }
                fixedRules.append(rule)
                rpmNames.append(String(rpm))
            }
            var resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if resolvedName.isEmpty {
                resolvedName = rpmNames.joined(separator: "／") + " RPM"
                if resolvedName.count > 40 {
                    let existingNames = Set(presets.filter { $0.id != id }.map(\.name))
                    var number = 1
                    while existingNames.contains("常用轉速 \(number)") { number += 1 }
                    resolvedName = "常用轉速 \(number)"
                }
            }
            guard resolvedName.count <= 40 else { throw FanError.invalid("預設檔名稱最多 40 字。") }
            var candidate = presets
            if let id, let index = candidate.firstIndex(where: { $0.id == id }) {
                candidate[index].name = resolvedName
                candidate[index].rules = fixedRules
            } else {
                candidate.append(FanPreset(name: resolvedName, rules: fixedRules))
            }
            try persistPresets(candidate)
            message = "已\(id == nil ? "儲存" : "更新")「\(resolvedName)」；套用後才會改變轉速。"
            return true
        } catch {
            message = "無法儲存預設檔：\(error.localizedDescription)"
            return false
        }
    }

    func applyPreset(_ preset: FanPreset) { apply(preset.rules, name: preset.name) }

    func isPresetActive(_ preset: FanPreset) -> Bool {
        guard helperReady, hasActiveControl, !isBusy, !awaitingRestore,
              !confirmedActiveRules.isEmpty, let snapshot = latestSnapshot,
              preset.rules.count == snapshot.fans.count,
              Set(preset.rules.map(\.fanID)) == Set(snapshot.fans.map(\.id)) else { return false }
        let automaticFanIDs = Set(preset.rules.filter { $0.mode == .automatic }.map(\.fanID))
        guard snapshot.fans.allSatisfy({ !automaticFanIDs.contains($0.id) || !$0.isManual }) else { return false }
        return sameControlRules(preset.rules.filter { $0.mode != .automatic }, confirmedActiveRules)
    }

    private func sameControlRules(_ lhs: [FanRule], _ rhs: [FanRule]) -> Bool {
        guard lhs.count == rhs.count,
              Set(lhs.map(\.fanID)).count == lhs.count,
              Set(rhs.map(\.fanID)).count == rhs.count else { return false }
        return zip(lhs.sorted { $0.fanID < $1.fanID }, rhs.sorted { $0.fanID < $1.fanID }).allSatisfy { left, right in
            guard left.fanID == right.fanID, left.mode == right.mode else { return false }
            switch left.mode {
            case .automatic: return true
            case .fixed: return left.rpm.isFinite && left.rpm == right.rpm
            case .sensor:
                return left.sensorKey == right.sensorKey && left.lowerTemperature.isFinite && left.upperTemperature.isFinite
                    && left.lowerTemperature == right.lowerTemperature && left.upperTemperature == right.upperTemperature
            }
        }
    }

    func deletePreset(_ preset: FanPreset) {
        do {
            try persistPresets(presets.filter { $0.id != preset.id })
            message = "已刪除「\(preset.name)」；目前風扇設定不變。"
        } catch { message = "無法刪除預設檔：\(error.localizedDescription)" }
    }

    private func persistPresets(_ candidate: [FanPreset]) throws {
        guard presetStoreReadable else {
            throw FanError.invalid("原有預設檔無法讀取，為保留資料，尚未覆寫。")
        }
        let data = try JSONEncoder().encode(candidate)
        let previousData = defaults.data(forKey: "presets")
        defaults.set(data, forKey: "presets")
        guard defaults.synchronize(), defaults.data(forKey: "presets") == data else {
            if let previousData { defaults.set(previousData, forKey: "presets") }
            else { defaults.removeObject(forKey: "presets") }
            defaults.synchronize()
            throw FanError.invalid("本機儲存未成功確認，請稍後再試。")
        }
        update(\.presets, to: candidate)
    }

    func exportDiagnostics() {
        guard let snapshot = latestSnapshot else { message = "尚無硬體讀值可匯出。"; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MoMo-Fan-Diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: url, options: .atomic); message = "已匯出當下的風扇與溫度讀值。"
        } catch { message = error.localizedDescription }
    }

    func releaseControl(stopPolling: Bool = false, completion: @escaping () -> Void) {
        // Invalidating this authenticated session asks the daemon to release only its own fans.
        controlRevision &+= 1
        helperPendingID = nil
        if stopPolling { stopped = true }
        awaitingRestore = awaitingRestore || hasActiveControl || isBusy
        update(\.isBusy, to: false)
        hasActiveControl = false
        update(\.helperReady, to: false)
        if awaitingRestore { update(\.activePresetName, to: "等待確認風扇模式") }
        helper.invalidate()
        configurePolling()
        completion()
    }
}
