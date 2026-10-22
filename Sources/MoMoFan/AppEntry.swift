import AppKit
import SwiftUI
import Combine
import FanCore

@MainActor enum MoMoBrandArtwork {
    // Load the original bundled artwork once, shared by all brand surfaces.
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let artwork = NSImage(contentsOf: url) {
            return artwork
        }
        // Unbundled development launches can use macOS's application icon.
        return NSApplication.shared.applicationIconImage ?? NSImage(size: NSSize(width: 42, height: 42))
    }()

    static let statusImage: NSImage = {
        let artwork = image
        return NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            artwork.draw(in: bounds)
            return true
        }
    }()
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    var model: AppModel!
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var subscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "關於 MoMo Fan", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "顯示 MoMo Fan", action: #selector(showWindow), keyEquivalent: "1")
        let showMenu = appMenu.addItem(withTitle: "顯示選單列面板", action: #selector(togglePopover), keyEquivalent: "m")
        showMenu.target = self
        showMenu.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "隱藏 MoMo Fan", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "結束 MoMo Fan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let editMenu = NSMenu(title: "編輯"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "複製", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu

        model = AppModel()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "MoMo Fan"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 1040, height: 720)
        window.contentView = NSHostingView(rootView: DashboardView(model: model).tint(.teal))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("MoMoFanMainWindow")
        window.center()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MoMoBrandArtwork.statusImage
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.setAccessibilityLabel("MoMo Fan")
        statusItem.button?.toolTip = "MoMo Fan · 點一下查看溫度與風扇"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 350, height: 360)
        subscription = model.$menuTitle.removeDuplicates().sink { [weak self] title in
            guard let button = self?.statusItem.button else { return }
            let displayedTitle = title.isEmpty ? "" : " " + title
            if button.title != displayedTitle { button.title = displayedTitle }
        }
        showWindow()
    }

    @objc func showWindow() {
        popover?.performClose(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.setMainWindowVisible(true)
    }
    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.contentViewController = NSHostingController(rootView: MenuContentView(model: model, openWindow: { [weak self] in self?.showWindow() }).tint(.teal))
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateWindowVisibility() {
        guard let window, let model else { return }
        model.setMainWindowVisible(window.isVisible && !window.isMiniaturized && !NSApp.isHidden && window.occlusionState.contains(.visible))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        model.setMainWindowVisible(false)
        return false
    }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateWindowVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { updateWindowVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updateWindowVisibility() }
    func applicationDidHide(_ notification: Notification) {
        popover?.performClose(nil)
        model?.setMainWindowVisible(false)
        model?.setPopoverVisible(false)
    }
    func applicationDidUnhide(_ notification: Notification) { updateWindowVisibility() }
    func applicationDidBecomeActive(_ notification: Notification) {
        updateWindowVisibility()
        // Approval may have changed while System Settings was in front.
        model?.refreshLoginSetting()
        model?.poll()
    }
    func popoverDidShow(_ notification: Notification) { model.setPopoverVisible(true) }
    func popoverDidClose(_ notification: Notification) {
        guard !popover.isShown else { return }
        model.setPopoverVisible(false)
        // A closed panel should not retain another SwiftUI model observer tree.
        popover.contentViewController = nil
    }
    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "MoMo Fan", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", .credits: NSAttributedString(string: "個人使用的原生風扇與溫度控制工具\n獨立實作 · 不含付費授權檢查 · 資料留在本機")])
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        subscription?.cancel()
        model?.releaseControl(stopPolling: true) {}
    }
}

@main struct MoMoFanEntry {
    static func main() {
        if CommandLine.arguments.contains("--reload-helper") {
            HelperMaintenance.run()
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--restore-automatic") {
            AutomaticRestoration.run()
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                print(String(decoding: try encoder.encode(SMCClient().snapshot()), as: UTF8.self))
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--verify-helper") || CommandLine.arguments.contains("--verify-control") {
            Verification.run(control: CommandLine.arguments.contains("--verify-control"))
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains(where: AcceptanceVerification.switches.contains) {
            AcceptanceVerification.run(arguments: CommandLine.arguments)
            RunLoop.main.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
