// MainMenu.swift — Thermik (MIT). Unit 0 seed; OWNER: Unit 8. The app menu bar, visible while a window is open
// (`.regular`); its key equivalents also work while Thermik is an agent (`.accessory`) and a window is key.
// View ▸ pages carry ⌘1…⌘8 (SPEC §4.6, §4.13); Edit ▸ Undo/Redo route through the responder chain to the key window's
// UndoManager (the fan-curve editor registers its edits there).
import AppKit
import ThermikCore

@MainActor enum MainMenu {
    static func make(router: AppRouter) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(router: router)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu(router: router)))
        let window = windowMenu(router: router)
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func appMenu(router: AppRouter) -> NSMenu {
        let app = NSMenu(title: "Thermik")
        app.addItem(withTitle: String(localized: "About Thermik"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(MenuAction(title: String(localized: "Settings…"), key: ",") { router.showSettings(nil) }.item)
        app.addItem(MenuAction(title: String(localized: "Welcome Guide…"), key: "") { router.showOnboarding() }.item)
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Hide Thermik"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Quit Thermik"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return app
    }

    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return edit
    }

    private static func viewMenu(router: AppRouter) -> NSMenu {
        let view = NSMenu(title: String(localized: "View"))
        for page in Route.Page.contentPages {
            let route = Self.route(page)
            let item = MenuAction(title: page.title, key: "\(page.shortcutDigit)") { router.showMain(route) }.item
            item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil)
            view.addItem(item)
        }
        view.addItem(.separator())
        let sidebar = view.addItem(withTitle: String(localized: "Toggle Sidebar"), action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        let full = view.addItem(withTitle: String(localized: "Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        return view
    }

    private static func windowMenu(router: AppRouter) -> NSMenu {
        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(MenuAction(title: String(localized: "Thermik Main Window"), key: "0") { router.showMain(nil) }.item)
        window.addItem(.separator())
        window.addItem(withTitle: String(localized: "Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return window
    }

    private static func route(_ page: Route.Page) -> Route {
        switch page {
        case .overview: .overview; case .sensors: .sensors(nil); case .fans: .fans; case .battery: .battery
        case .system: .system; case .diagnostics: .diagnostics; case .logs: .logs; case .alerts: .alerts
        case .settings: .settings(nil)
        }
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
