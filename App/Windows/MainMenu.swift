// MainMenu.swift — Thermik (MIT). Basic version by Unit 0; OWNER: Unit 8. Shown only while a window is open (.regular).
import AppKit

@MainActor enum MainMenu {
    static func make(router: AppRouter) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: String(localized: "About Thermik"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settings = MenuAction(title: String(localized: "Settings…"), key: ",") { router.showSettings(nil) }
        app.addItem(settings.item)
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Quit Thermik"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        NSApp.windowsMenu = window
        return main
    }
}

/// Closure-backed menu item target (kept alive by the item's representedObject).
@MainActor final class MenuAction: NSObject {
    let item: NSMenuItem
    private let handler: () -> Void
    init(title: String, key: String, handler: @escaping () -> Void) {
        self.handler = handler
        item = NSMenuItem(title: title, action: nil, keyEquivalent: key)
        super.init()
        item.target = self
        item.action = #selector(run)
        item.representedObject = self
    }
    @objc private func run() { handler() }
}
