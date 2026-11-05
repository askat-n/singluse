import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var hubWindow: NSWindow?
    private var menuBarObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        NSApp.setActivationPolicy(.accessory)
        Coordinator.shared.start()
        applyMenuBarIcon()
        // Значок в строке меню можно спрятать; настройка применяется сразу.
        menuBarObserver = AppSettings.shared.$showMenuBarIcon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyMenuBarIcon() }

        // Автозапуск включён по просьбе один раз. Выключенный потом в настройках, он больше сам не включится.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "migratedLaunchAtLogin") {
            do {
                try SMAppService.mainApp.register()
                defaults.set(true, forKey: "migratedLaunchAtLogin")
            } catch {
                NSLog("Singluse: launch at login failed: \(error)")
            }
        }

        // При автозапуске с Mac окно не мешает: приложение тихо живёт в строке меню.
        if SMAppService.mainApp.status != .enabled || !AppSettings.shared.launchedBefore {
            showHub()
        }
        AppSettings.shared.launchedBefore = true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHub()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Coordinator.shared.clipboard.saveNow()
    }

    // MARK: - Главное окно

    @objc func showHub() {
        if hubWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Singluse"
            window.isReleasedWhenClosed = false
            window.toolbarStyle = .unified
            window.minSize = NSSize(width: 760, height: 520)
            // Контроллер передаёт окну заголовок и панель инструментов, как в приложениях Apple.
            let controller = NSHostingController(rootView: HubView())
            controller.sceneBridgingOptions = [.all]
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 900, height: 640))
            window.center()
            window.setFrameAutosaveName("SingluseHub")
            window.delegate = self
            hubWindow = window
        }
        // Пока окно открыто, у приложения есть значок в Dock; закрыли — живём в строке меню.
        NSApp.setActivationPolicy(.regular)
        hubWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Coordinator.shared.permissions.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === hubWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Строка меню

    private func applyMenuBarIcon() {
        if AppSettings.shared.showMenuBarIcon {
            if statusItem == nil { setUpStatusItem() }
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Singluse")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = NSMenuItem(title: L("Открыть Singluse"), action: #selector(showHub), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let meeting = NSMenuItem(
            title: Coordinator.shared.meetings.isRecording ? L("Остановить запись встречи") : L("Начать запись встречи"),
            action: #selector(toggleMeeting),
            keyEquivalent: ""
        )
        meeting.target = self
        menu.addItem(meeting)
        let clips = NSMenuItem(title: "\(L("История буфера"))  \(ClipboardController.hotkeyTitle)", action: #selector(showClipboard), keyEquivalent: "")
        clips.target = self
        clips.isEnabled = AppSettings.shared.isEnabled(.clipboard)
        menu.addItem(clips)
        menu.addItem(.separator())
        for module in Module.allCases {
            let row = NSMenuItem(title: module.title, action: #selector(toggleModule(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = module.rawValue
            row.state = AppSettings.shared.isEnabled(module) ? .on : .off
            row.image = NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil)
            menu.addItem(row)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Выйти"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleMeeting() {
        Coordinator.shared.meetings.toggle()
    }

    @objc private func showClipboard() {
        Coordinator.shared.clipboard.togglePanel()
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let module = Module(rawValue: raw) else { return }
        AppSettings.shared.setEnabled(module, !AppSettings.shared.isEnabled(module))
    }

    // Без главного меню в полях ввода не работают ⌘C/⌘V, а окно не закрывается по ⌘W.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: L("Выйти из Singluse"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: L("Правка"))
        edit.addItem(NSMenuItem(title: L("Отменить"), action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: L("Вернуть"), action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: L("Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: L("Копировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: L("Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: L("Выбрать всё"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: L("Окно"))
        window.addItem(NSMenuItem(title: L("Закрыть"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: L("Свернуть"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = window
        return main
    }
}
