import AppKit
import Charts
import FanCore
import SwiftUI

private enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "總覽"
    case presets = "預設檔"
    case settings = "設定"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .presets: return "slider.horizontal.3"
        case .settings: return "gearshape"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var selection: DashboardSection? = .overview
    @State private var showingSavePreset = false
    @State private var deletingPreset: FanPreset?
    @State private var editingPresetID: UUID?
    @State private var presetName = ""
    @State private var presetRPMs: [Int: String] = [:]
    @State private var convertsPresetToFixed = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 194, max: 220)
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview: overview
                case .presets: presets
                case .settings: settings
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.teal)
        .frame(minWidth: 1040, minHeight: 720)
        .sheet(isPresented: $showingSavePreset) {
            SavePresetView(model: model)
        }
        .alert("刪除預設檔？", isPresented: Binding(
            get: { deletingPreset != nil },
            set: { if !$0 { deletingPreset = nil } }
        ), presenting: deletingPreset) { preset in
            Button("取消", role: .cancel) { deletingPreset = nil }
            Button("刪除", role: .destructive) {
                model.deletePreset(preset)
                if editingPresetID == preset.id { resetPresetEditor() }
                deletingPreset = nil
            }
        } message: { preset in
            Text("將刪除「\(preset.name)」。目前的風扇控制不會因此變更。")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: MoMoBrandArtwork.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MoMo Fan").font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("溫度與風扇").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 25)
            .padding(.bottom, 24)

            List(DashboardSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.vertical, 5)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            VStack(alignment: .leading, spacing: 10) {
                Divider()
                Label(model.machineName, systemImage: "laptopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.snapshot == nil ? Color.orange : Color.teal)
                        .frame(width: 6, height: 6)
                    Text(model.snapshot == nil ? "正在讀取硬體" : "即時監測中")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader(title: "總覽", subtitle: "掌握溫度，讓散熱保持在你的節奏。") {
                    StatusPill(text: model.activePresetName, symbol: "waveform.path", color: .teal)
                }
                if !model.helperReady { helperNotice }
                summaryCards
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        fanControls
                        TemperatureHistoryView(model: model)
                    }
                    .frame(maxWidth: .infinity)
                    SensorListView(model: model)
                        .frame(width: 270)
                }
                if !model.message.isEmpty { messageNotice }
                Label("結束程式或控制連線中斷時，控制服務會要求風扇回復系統自動。", systemImage: "shield.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .navigationTitle("總覽")
    }

    private var summaryCards: some View {
        HStack(spacing: 14) {
            MetricCard(title: "CPU 溫度", value: model.hottestCPU.map(model.temperature) ?? "—", detail: "最熱 CPU 感測器", symbol: "cpu", color: .teal)
            MetricCard(title: "GPU 溫度", value: model.hottestGPU.map(model.temperature) ?? "—", detail: "最熱 GPU 感測器", symbol: "square.stack.3d.up", color: .blue)
            MetricCard(title: "風扇轉速", value: maximumFanRPM, detail: "最高即時轉速 · RPM", symbol: "fanblades", color: .teal)
        }
    }

    private var maximumFanRPM: String {
        guard let value = model.snapshot?.fans.map(\.currentRPM).max(), value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    private var fanControls: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("風扇控制").font(.headline)
                Spacer()
                Button("儲存為預設檔", systemImage: "square.and.arrow.down") { showingSavePreset = true }
                    .controlSize(.small)
                    .disabled(model.rules.isEmpty)
                if model.isBusy { ProgressView().controlSize(.small) }
                Menu {
                    Button("回復系統自動", systemImage: "arrow.counterclockwise") { model.setAllAutomatic() }
                    Button("全速散熱", systemImage: "wind") { model.setMaximum() }
                    Divider()
                    if model.presets.isEmpty {
                        Button("尚無已儲存的預設檔") {}.disabled(true)
                    } else {
                        ForEach(model.presets) { preset in
                            Button {
                                model.applyPreset(preset)
                            } label: {
                                Label("\(preset.name) · \(presetSummary(preset))", systemImage: model.isPresetActive(preset) ? "checkmark" : "slider.horizontal.3")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!model.helperReady || model.isBusy)
                .accessibilityLabel("快速調整所有風扇")
                .help("快速調整所有風扇")
            }

            if let fans = model.snapshot?.fans, !fans.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(fans) { fan in
                        FanControlCard(model: model, fan: fan, rule: ruleBinding(for: fan))
                    }
                }
                HStack(spacing: 10) {
                    Text("調整後按「套用調整」才會生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("套用調整") { model.applyRules() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.helperReady || model.isBusy)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "fanblades").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("等待風扇資訊").font(.headline)
                    Text("取得硬體讀值後，這裡會顯示可用的風扇。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .panel()
            }
        }
    }

    private func ruleBinding(for fan: FanReading) -> Binding<FanRule> {
        Binding {
            model.rules.first(where: { $0.fanID == fan.id }) ?? FanRule(
                fanID: fan.id,
                rpm: max(fan.minimumRPM, min(fan.maximumRPM, fan.currentRPM)),
                sensorKey: model.snapshot?.sensors.first(where: { $0.group == "CPU" })?.key ?? model.snapshot?.sensors.first?.key ?? ""
            )
        } set: { value in
            if let index = model.rules.firstIndex(where: { $0.fanID == fan.id }) {
                model.rules[index] = value
            } else {
                model.rules.append(value)
            }
        }
    }

    private var helperNotice: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: "eye")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 36, height: 36)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text("目前為唯讀監測").font(.system(size: 13, weight: .semibold))
                Text(model.helperStatus.isEmpty ? "啟用風扇控制後，即可調整轉速與套用預設檔。" : model.helperStatus)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button("啟用風扇控制") { model.enableHelper() }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
        }
        .padding(14)
        .background(.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.orange.opacity(0.18), lineWidth: 1))
    }

    private var messageNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(model.message).font(.caption).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(13)
        .panel(cornerRadius: 12)
    }

    private var presets: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    pageHeader(title: "預設檔", subtitle: "輸入常用轉速，儲存後隨時套用。") {
                        EmptyView()
                    }
                    presetEditor
                        .id("presetEditor")
                    Text("已儲存 · \(model.presets.count) 組")
                        .font(.headline)
                    if model.presets.isEmpty {
                        Text("還沒有常用轉速，在上方輸入數字並儲存即可。")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(model.presets) { preset in
                                presetRow(preset)
                            }
                        }
                    }
                    if !model.message.isEmpty { messageNotice }
                }
                .padding(24)
            }
            .onChange(of: editingPresetID) { _, id in
                if id != nil { proxy.scrollTo("presetEditor", anchor: .top) }
            }
        }
        .navigationTitle("預設檔")
        .onAppear { seedPresetRPMs() }
        .onChange(of: presetFans.map(\.id)) { _, _ in seedPresetRPMs() }
    }

    private var presetFans: [FanReading] {
        (model.snapshot?.fans ?? []).sorted { $0.id < $1.id }
    }

    private var presetEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(editingPresetID == nil ? "新增常用轉速" : "修改常用轉速")
                    .font(.headline)
                Spacer()
                if editingPresetID != nil {
                    Button("取消修改") { resetPresetEditor() }
                        .buttonStyle(.borderless)
                }
            }
            if presetFans.isEmpty {
                Text("正在讀取風扇資訊…").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 20)], alignment: .leading, spacing: 16) {
                    ForEach(presetFans) { fan in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(fan.name).font(.subheadline.weight(.medium))
                            HStack(spacing: 8) {
                                TextField("3000", text: Binding(
                                    get: { presetRPMs[fan.id] ?? "" },
                                    set: { presetRPMs[fan.id] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.title3.monospacedDigit())
                                .accessibilityLabel("預設檔\(fan.name)轉速")
                                Text("RPM").foregroundStyle(.secondary)
                            }
                            Text("\(fan.minimumRPM.formatted(.number.precision(.fractionLength(0))))–\(fan.maximumRPM.formatted(.number.precision(.fractionLength(0)))) RPM")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: 580)
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("名稱（選填）").font(.subheadline)
                        TextField("例如：日常工作", text: $presetName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("預設檔名稱，選填")
                    }
                    .frame(maxWidth: 320)
                    Button(editingPresetID == nil ? "儲存" : "儲存修改") {
                        if model.saveFixedPreset(id: editingPresetID, name: presetName, rpms: presetRPMs) {
                            resetPresetEditor()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Text(convertsPresetToFixed ? "儲存後將這組設定改為固定轉速；按「套用」才會生效。" : "儲存在這台 Mac，按「套用」才會改變轉速。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func seedPresetRPMs() {
        // A transient read failure must not replace an unfinished draft with defaults.
        guard !presetFans.isEmpty else { return }
        for fan in presetFans where presetRPMs[fan.id] == nil {
            let rpm = min(fan.maximumRPM, max(fan.minimumRPM, 3000))
            presetRPMs[fan.id] = String(Int(rpm.rounded()))
        }
        let ids = Set(presetFans.map(\.id))
        presetRPMs = presetRPMs.filter { ids.contains($0.key) }
    }

    private func resetPresetEditor() {
        editingPresetID = nil
        presetName = ""
        presetRPMs = [:]
        convertsPresetToFixed = false
        seedPresetRPMs()
    }

    private func editPreset(_ preset: FanPreset) {
        editingPresetID = preset.id
        presetName = preset.name
        convertsPresetToFixed = preset.rules.contains { $0.mode != .fixed }
        presetRPMs = Dictionary(preset.rules.map { ($0.fanID, String(format: "%.0f", $0.rpm)) }, uniquingKeysWith: { first, _ in first })
        seedPresetRPMs()
    }

    private func presetRow(_ preset: FanPreset) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 21))
                .foregroundStyle(.teal)
                .frame(width: 46, height: 46)
                .background(.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(preset.name).font(.headline)
                    if model.isPresetActive(preset) {
                        StatusPill(text: "目前使用", symbol: "checkmark", color: .teal)
                    }
                }
                Text(presetSummary(preset))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Button(preset.rules.allSatisfy { $0.mode == .fixed } ? "修改" : "轉為固定轉速") {
                editPreset(preset)
            }
            .buttonStyle(.bordered)
            .disabled(presetFans.isEmpty)
            Button("套用") { model.applyPreset(preset) }
                .buttonStyle(.bordered)
                .disabled(!model.helperReady || model.isBusy)
            Button {
                deletingPreset = preset
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("刪除「\(preset.name)」")
        }
        .padding(18)
        .panel()
    }

    private func presetSummary(_ preset: FanPreset) -> String {
        preset.rules.map { rule in
            let name = model.snapshot?.fans.first(where: { $0.id == rule.fanID })?.name ?? "風扇 \(rule.fanID + 1)"
            switch rule.mode {
            case .automatic: return "\(name)：系統自動"
            case .fixed: return "\(name)：\(rule.rpm.formatted(.number.precision(.fractionLength(0)))) RPM"
            case .sensor:
                return "\(name)：\(rule.sensorKey) · \(model.temperature(rule.lowerTemperature))–\(model.temperature(rule.upperTemperature))"
            }
        }.joined(separator: "　·　")
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader(title: "設定", subtitle: "依照你的習慣，安排每一個顯示細節。") {
                EmptyView()
            }
            .padding(24)
            Form {
                Section("溫度顯示") {
                    Picker("顯示單位", selection: $model.usesFahrenheit) {
                        Text("攝氏 °C").tag(false)
                        Text("華氏 °F").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                }
                Section("選單列") {
                    Toggle("只顯示圖示", isOn: $model.menuIconOnly)
                    Text("開啟後只保留風扇圖示；點一下仍可查看溫度、轉速與預設檔。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("顯示溫度", isOn: $model.showMenuTemperature)
                        .disabled(model.menuIconOnly)
                    Picker("溫度感測器", selection: $model.menuSensorKey) {
                        if model.menuSensorKey.isEmpty {
                            Text("自動選擇 CPU 感測器").tag("")
                        } else if !(model.snapshot?.sensors.contains(where: { $0.key == model.menuSensorKey }) ?? false) {
                            Text("\(model.menuSensorKey) · 等待讀值").tag(model.menuSensorKey)
                        }
                        ForEach(model.snapshot?.sensors ?? []) { sensor in
                            Text("\(sensor.name) · \(sensor.key)").tag(sensor.key)
                        }
                    }
                    .disabled(model.menuIconOnly || !model.showMenuTemperature)
                    Toggle("顯示風扇轉速", isOn: $model.showMenuRPM)
                        .disabled(model.menuIconOnly)
                    Picker("風扇", selection: $model.menuFanID) {
                        if !(model.snapshot?.fans.contains(where: { $0.id == model.menuFanID }) ?? false) {
                            Text("等待風扇讀值").tag(model.menuFanID)
                        }
                        ForEach(model.snapshot?.fans ?? []) { fan in
                            Text(fan.name).tag(fan.id)
                        }
                    }
                    .disabled(model.menuIconOnly || !model.showMenuRPM)
                }
                Section("啟動") {
                    Toggle("登入時啟動 MoMo Fan", isOn: $model.launchAtLogin)
                    Button("開啟系統登入項目設定", systemImage: "arrow.up.right.square") { model.openLoginSettings() }
                        .buttonStyle(.link)
                }
                Section("風扇控制") {
                    LabeledContent("控制服務") {
                        StatusPill(text: model.helperReady ? "已就緒" : "唯讀模式", symbol: model.helperReady ? "checkmark.circle.fill" : "eye", color: model.helperReady ? .teal : .orange)
                    }
                    if !model.helperStatus.isEmpty {
                        Text(model.helperStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !model.helperReady {
                        Button("啟用風扇控制") { model.enableHelper() }.disabled(model.isBusy)
                    }
                    Text("結束 MoMo Fan 或控制連線中斷時，控制服務會要求回復系統自動。自訂設定仍會受到硬體可用轉速範圍限制。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("診斷") {
                    Button("匯出診斷資訊", systemImage: "doc.text") { model.exportDiagnostics() }
                    Text("包含目前的感測器與風扇讀值，方便排查問題。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.message.isEmpty {
                    Section {
                        Text(model.message).font(.caption).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("設定")
    }

    private func pageHeader<Trailing: View>(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 28, weight: .bold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

private struct FanControlCard: View {
    @ObservedObject var model: AppModel
    let fan: FanReading
    @Binding var rule: FanRule

    private var safeRange: ClosedRange<Double> {
        let lower = fan.minimumRPM.isFinite ? max(0, fan.minimumRPM) : 0
        let upper = fan.maximumRPM.isFinite ? max(lower + 1, fan.maximumRPM) : lower + 1
        return lower...upper
    }

    private var fixedRPM: Binding<Double> {
        Binding {
            min(safeRange.upperBound, max(safeRange.lowerBound, rule.rpm))
        } set: { rule.rpm = $0 }
    }

    private var mode: Binding<FanMode> {
        Binding { rule.mode } set: { newValue in
            rule.mode = newValue
            if newValue == .fixed { rule.rpm = fixedRPM.wrappedValue }
            if newValue == .sensor, rule.sensorKey.isEmpty {
                rule.sensorKey = model.snapshot?.sensors.first(where: { $0.group == "CPU" })?.key ?? model.snapshot?.sensors.first?.key ?? ""
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 8) {
                Image(systemName: "fanblades.fill").foregroundStyle(.teal)
                Text(fan.name).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                Circle().fill(fan.isManual ? Color.teal : Color.secondary.opacity(0.45)).frame(width: 6, height: 6)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(rpm(fan.currentRPM)).font(.system(size: 32, weight: .medium, design: .rounded)).monospacedDigit()
                Text("RPM").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            VStack(spacing: 7) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.teal.opacity(0.10))
                        Capsule().fill(.teal.opacity(0.75))
                            .frame(width: geometry.size.width * speedFraction)
                    }
                }
                .frame(height: 5)
                HStack {
                    Text("最低 \(rpm(fan.minimumRPM))")
                    Spacer(minLength: 0)
                    Text("最高 \(rpm(fan.maximumRPM))")
                }
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                Text("已生效")
                    .foregroundStyle(.tertiary)
                Text(fan.isManual ? "自訂 · \(rpm(fan.targetRPM)) RPM" : "系統自動")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Divider()
            VStack(alignment: .leading, spacing: 13) {
                Picker("控制方式", selection: mode) {
                    ForEach(FanMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                switch rule.mode {
                case .automatic:
                    Label {
                        Text("由 macOS 依照溫度與負載，自動決定風扇轉速。")
                            .font(.caption).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "sparkles").foregroundStyle(.teal)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 46, alignment: .top)
                case .fixed:
                    fixedControls
                case .sensor:
                    sensorControls
                }
            }
            .disabled(model.isBusy)
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .panel()
    }

    private var fixedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("目標轉速").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(rpm(fixedRPM.wrappedValue)) RPM").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Slider(value: fixedRPM, in: safeRange, step: 50)
                .accessibilityLabel("\(fan.name)目標轉速")
            Text("每次調整 50 RPM")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private var sensorControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("依據感測器").font(.caption).foregroundStyle(.secondary)
                Picker("依據感測器", selection: $rule.sensorKey) {
                    if rule.sensorKey.isEmpty { Text("選擇感測器").tag("") }
                    else if !(model.snapshot?.sensors.contains(where: { $0.key == rule.sensorKey }) ?? false) {
                        Text("\(rule.sensorKey) · 等待讀值").tag(rule.sensorKey)
                    }
                    ForEach(model.snapshot?.sensors ?? []) { sensor in
                        Text("\(sensor.name) · \(sensor.key)").tag(sensor.key)
                    }
                }
                .labelsHidden()
            }
            HStack(alignment: .top, spacing: 12) {
                temperatureStepper(title: "開始升速", value: $rule.lowerTemperature, range: 20...90)
                temperatureStepper(title: "達到全速", value: $rule.upperTemperature, range: 25...95)
            }
            CurvePreview(lower: model.temperature(rule.lowerTemperature), upper: model.temperature(rule.upperTemperature))
            Text("兩個溫度之間，轉速會線性增加。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func temperatureStepper(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(model.temperature(value.wrappedValue))
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                Spacer(minLength: 0)
                Stepper(title, value: value, in: range, step: 1).labelsHidden().fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var speedFraction: Double {
        guard fan.currentRPM.isFinite, fan.maximumRPM.isFinite, fan.maximumRPM > 0 else { return 0 }
        return min(1, max(0, fan.currentRPM / fan.maximumRPM))
    }

    private func rpm(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}

private struct CurvePreview: View {
    let lower: String
    let upper: String

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("最高")
                Spacer()
            }
            .font(.system(size: 9)).foregroundStyle(.tertiary)
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height))
                    path.addLine(to: CGPoint(x: width * 0.22, y: height))
                    path.addLine(to: CGPoint(x: width * 0.78, y: 0))
                    path.addLine(to: CGPoint(x: width, y: 0))
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [.teal.opacity(0.15), .teal.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height))
                    path.addLine(to: CGPoint(x: width * 0.22, y: height))
                    path.addLine(to: CGPoint(x: width * 0.78, y: 0))
                    path.addLine(to: CGPoint(x: width, y: 0))
                }
                .stroke(.teal, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .frame(height: 35)
            HStack {
                Text("最低 · \(lower)")
                Spacer(minLength: 0)
                Text(upper)
            }
            .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lower) 開始增加轉速，\(upper) 達到最高轉速")
    }
}

private struct TemperatureHistoryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text("溫度走勢").font(.headline)
                Spacer()
                Text(model.usesFahrenheit ? "°F" : "°C").font(.caption).foregroundStyle(.secondary)
            }
            if !model.mainWindowVisible {
                // Keep recording history while hidden, but release the Chart tree.
                // Removing only the plot preserves window layout and editing state.
                Color.clear.frame(height: 155)
            } else if model.history.contains(where: { $0.cpu != nil || $0.gpu != nil }) {
                Chart {
                    ForEach(model.history) { point in
                        if let cpu = point.cpu, cpu.isFinite {
                            LineMark(x: .value("時間", point.time), y: .value("溫度", displayTemperature(cpu)))
                                .foregroundStyle(by: .value("感測器", "CPU"))
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                        if let gpu = point.gpu, gpu.isFinite {
                            LineMark(x: .value("時間", point.time), y: .value("溫度", displayTemperature(gpu)))
                                .foregroundStyle(by: .value("感測器", "GPU"))
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                }
                .chartForegroundStyleScale(["CPU": Color.teal, "GPU": Color.blue])
                .chartYScale(domain: chartRange)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        AxisValueLabel()
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
                .frame(height: 155)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path").font(.title2).foregroundStyle(.teal.opacity(0.7))
                    Text("正在收集溫度讀值").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 155)
            }
        }
        .padding(18)
        .panel()
    }

    private func displayTemperature(_ value: Double) -> Double {
        model.usesFahrenheit ? value * 1.8 + 32 : value
    }

    private var chartRange: ClosedRange<Double> {
        let values = model.history.flatMap { [$0.cpu, $0.gpu].compactMap { $0 } }
            .filter(\.isFinite).map(displayTemperature)
        guard let minimum = values.min(), let maximum = values.max() else { return 20...100 }
        let lower = floor((minimum - 4) / 5) * 5
        let upper = ceil((maximum + 4) / 5) * 5
        return lower...max(lower + 10, upper)
    }
}

private struct SensorListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let sensors = model.filteredSensors
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("溫度感測器").font(.headline)
                Spacer()
                Text("\(sensors.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("搜尋名稱或代碼", text: $model.sensorFilter)
                    .textFieldStyle(.plain).font(.caption)
                if !model.sensorFilter.isEmpty {
                    Button { model.sensorFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain).help("清除搜尋")
                }
            }
            .padding(9)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            if sensors.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: model.sensorFilter.isEmpty ? "thermometer.medium" : "magnifyingglass")
                        .font(.title2).foregroundStyle(.secondary)
                    Text(model.sensorFilter.isEmpty ? "等待感測器資訊" : "找不到符合的感測器")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 350)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sensors) { sensor in
                            sensorRow(sensor)
                            if sensor.id != sensors.last?.id {
                                Divider().opacity(0.45)
                            }
                        }
                    }
                }
                .frame(height: 438)
            }
        }
        .padding(17)
        .panel()
    }

    private func sensorRow(_ sensor: SensorReading) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(sensor.name).font(.system(size: 11, weight: .medium)).lineLimit(2)
                Text(sensor.key).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Text(model.temperature(sensor.celsius))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(sensor.celsius >= 85 ? Color.orange : Color.primary)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct SavePresetView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saveError = ""
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 27)).foregroundStyle(.teal)
                .frame(width: 54, height: 54)
                .background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 7) {
                Text("儲存預設檔").font(.title2.weight(.semibold))
                Text("保存總覽中目前的設定，之後即可一鍵套用。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            TextField("例如：日常工作、安靜閱讀", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            Text("名稱最多 40 字")
                .font(.caption).foregroundStyle(trimmedName.count > 40 ? Color.orange : Color.secondary)
            if !saveError.isEmpty {
                Text(saveError).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("儲存") {
                    if model.savePreset(name: trimmedName) { dismiss() }
                    else { saveError = model.message }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || trimmedName.count > 40)
            }
        }
        .padding(26)
        .frame(width: 430)
        .onAppear { nameFocused = true }
    }
}

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    var openWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label {
                    Text("MoMo Fan")
                } icon: {
                    Image(nsImage: MoMoBrandArtwork.image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Button(action: openWindow) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("開啟主視窗")
            }
            HStack(spacing: 10) {
                menuTemperature(title: "CPU", value: model.hottestCPU, color: .teal)
                menuTemperature(title: "GPU", value: model.hottestGPU, color: .blue)
            }
            if let fans = model.snapshot?.fans {
                VStack(spacing: 10) {
                    ForEach(fans) { fan in
                        HStack(spacing: 8) {
                            Image(systemName: "fanblades").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fan.name).font(.caption)
                                Text(fan.isManual ? "自訂控制" : "系統自動").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(fan.currentRPM.isFinite ? fan.currentRPM.formatted(.number.precision(.fractionLength(0))) : "—")
                                .font(.system(size: 14, weight: .medium, design: .rounded)).monospacedDigit()
                            Text("RPM").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text(model.helperReady ? model.activePresetName : "唯讀監測")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.mini) }
                if !model.presets.isEmpty {
                    Menu("預設檔") {
                        ForEach(model.presets) { preset in
                            Button(preset.name) { model.applyPreset(preset) }
                        }
                    }
                    .fixedSize()
                    .disabled(!model.helperReady || model.isBusy)
                }
            }
            HStack(spacing: 8) {
                Button { model.setAllAutomatic() } label: {
                    Label("系統自動", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                }
                Button { model.setMaximum() } label: {
                    Label("全速散熱", systemImage: "wind").frame(maxWidth: .infinity)
                }
            }
            .disabled(!model.helperReady || model.isBusy)
            HStack {
                Button("開啟主視窗", action: openWindow)
                    .buttonStyle(.link)
                Spacer()
                Button("結束") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(17)
        .frame(width: 330)
        .tint(.teal)
    }

    private func menuTemperature(title: String, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map(model.temperature) ?? "—")
                .font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(color)
            }
            Text(value).font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

private struct StatusPill: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(color.opacity(0.09), in: Capsule())
    }
}

private extension View {
    func panel(cornerRadius: CGFloat = 16) -> some View {
        background(Color(nsColor: .controlBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.primary.opacity(0.055), lineWidth: 1))
    }
}
