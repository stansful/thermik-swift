// HotKeys.swift — Thermik (MIT). OWNER: Unit 5. P1 global shortcuts ("Show main window", "Show or hide the panel")
// with Carbon `RegisterEventHotKey` — public API, no third-party dependency, no Accessibility permission, works
// from an LSUIElement agent. No default combination is set (FEAT §9.2): the user records one in Settings.
// Approach after FEAT §9.2 option 2; the context pointer replaces its static handler table.
import AppKit
import Carbon.HIToolbox
import Observation
import os
import SwiftUI

/// A global shortcut: Carbon virtual key code + Carbon modifier mask. Persisted as JSON (`SettingsStore.hotKeys`).
struct HotKeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    /// Key cap captured when recorded ("T", "F5", "Space"): layout-dependent, so it is stored, not recomputed.
    var keyLabel: String

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode; self.carbonModifiers = carbonModifiers; self.keyLabel = keyLabel
    }

    /// nil when the key press cannot be a global shortcut: it needs ⌘, ⌃ or ⌥ (function keys may stand alone).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        let code = UInt32(event.keyCode)
        let special = Self.specialKeyLabels[Int(code)]
        guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 || Self.functionKeys.contains(Int(code)) else { return nil }
        guard let label = special ?? event.charactersIgnoringModifiers?.uppercased(), !label.isEmpty,
              label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.init(keyCode: code, carbonModifiers: mods, keyLabel: label)
    }

    /// "⌃⌥⌘T" (Apple's modifier order: ⌃ ⌥ ⇧ ⌘).
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    private static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
                                                 kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
                                                 kVK_F18, kVK_F19, kVK_F20]
    /// Keys whose `characters` are control or private-use code points.
    private static let specialKeyLabels: [Int: String] = {
        var m: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
                                kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
                                kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟"]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                     kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, k) in fKeys.enumerated() { m[k] = "F\(i + 1)" }
        return m
    }()
}

/// What a global shortcut does.
enum HotKeyAction: String, CaseIterable, Identifiable, Sendable {
    case showMainWindow
    case togglePopover
    var id: String { rawValue }
    var title: String {
        switch self {
        case .showMainWindow: String(localized: "Show main window", comment: "Global keyboard shortcut action")
        case .togglePopover: String(localized: "Show or hide the panel", comment: "Global keyboard shortcut action (menu bar panel)")
        }
    }
    /// EventHotKeyID.id (0 is reserved by Carbon).
    fileprivate var carbonID: UInt32 {
        switch self { case .showMainWindow: 1; case .togglePopover: 2 }
    }
}

/// Registers the shortcuts stored in `SettingsStore.hotKeys` and re-registers whenever they change.
/// `HotKeys.shared` is configured once by AppDelegate; Settings (Unit 8) embeds `HotKeyRecorder(action:)`.
@MainActor @Observable final class HotKeys {
    static let shared = HotKeys()

    /// Actions whose shortcut macOS refused (e.g. an exclusive registration by another app).
    private(set) var conflicts: Set<HotKeyAction> = []

    @ObservationIgnored private var settings: SettingsStore?
    @ObservationIgnored private var handlers: [HotKeyAction: @MainActor () -> Void] = [:]
    @ObservationIgnored private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var eventHandler: EventHandlerRef?
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private let log = Logger(subsystem: "app.thermik.Thermik", category: "hotkeys")
    /// 'THMK'
    private static let signature: OSType = 0x5448_4D4B

    private init() {}

    func start(settings: SettingsStore, handlers: [HotKeyAction: @MainActor () -> Void]) {
        guard self.settings == nil else { return }
        self.settings = settings
        self.handlers = handlers
        installEventHandler()
        registerAll()
        observeContinuously({ [weak settings] in _ = settings?.hotKeys }) { [weak self] in
            guard let self else { return false }
            self.registerAll()
            return true
        }
    }

    /// The recorder suspends every shortcut while it listens, so pressing the current combination records it
    /// instead of firing it.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        registerAll()
    }

    func combo(for action: HotKeyAction) -> HotKeyCombo? { settings?.hotKeys[action.rawValue] }
    func setCombo(_ combo: HotKeyCombo?, for action: HotKeyAction) { settings?.hotKeys[action.rawValue] = combo }

    // MARK: Carbon

    private func installEventHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // `HotKeys.shared` is never deallocated, so an unretained context pointer is safe for the process lifetime.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr, hotKeyID.signature == HotKeys.signature else { return OSStatus(eventNotHandledErr) }
            // Carbon dispatches application-target events from the main event loop.
            let handled = MainActor.assumeIsolated {
                Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue().fire(hotKeyID.id)
            }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }, 1, &spec, context, &eventHandler)
        if status != noErr { log.error("InstallEventHandler failed: \(status, privacy: .public)") }
    }

    private func fire(_ id: UInt32) -> Bool {
        guard let action = HotKeyAction.allCases.first(where: { $0.carbonID == id }), let h = handlers[action] else { return false }
        log.info("hot key \(action.rawValue, privacy: .public)")
        h()
        return true
    }

    private func registerAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        var failed: Set<HotKeyAction> = []
        if !isSuspended, let settings {
            for action in HotKeyAction.allCases {
                guard let combo = settings.hotKeys[action.rawValue] else { continue }
                var ref: EventHotKeyRef?
                // Non-exclusive (kEventHotKeyNoOptions): never steal a combination another app also listens to.
                let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers,
                                                 EventHotKeyID(signature: Self.signature, id: action.carbonID),
                                                 GetApplicationEventTarget(), OptionBits(kEventHotKeyNoOptions), &ref)
                if status == noErr, let ref { refs[action] = ref } else {
                    failed.insert(action)
                    log.error("RegisterEventHotKey \(action.rawValue, privacy: .public) failed: \(status, privacy: .public)")
                }
            }
        }
        if failed != conflicts { conflicts = failed }
    }
}

// MARK: - Recorder (embedded by the Settings window, Unit 8)

/// "Record Shortcut" button: click, press a combination (Esc cancels, ⌫ clears). Reads `SettingsStore` from the
/// environment (`.thermikEnvironment(env)`).
struct HotKeyRecorder: View {
    let action: HotKeyAction
    @Environment(SettingsStore.self) private var settings
    @State private var recorder = HotKeyRecordingSession()

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recorder.isRecording ? recorder.stop() : recorder.start { settings.hotKeys[action.rawValue] = $0 }
            } label: {
                Text(recorder.isRecording ? String(localized: "Press a shortcut…")
                     : (settings.hotKeys[action.rawValue]?.displayString ?? String(localized: "Record Shortcut")))
                    .monospacedDigit()
                    .frame(minWidth: 120)
            }
            .accessibilityLabel(action.title)
            if settings.hotKeys[action.rawValue] != nil, !recorder.isRecording {
                Button {
                    settings.hotKeys[action.rawValue] = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Clear shortcut"))
                .accessibilityLabel(String(localized: "Clear shortcut"))
            }
            if HotKeys.shared.conflicts.contains(action) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(String(localized: "macOS refused this shortcut. Choose another combination."))
                    .accessibilityLabel(String(localized: "macOS refused this shortcut. Choose another combination."))
            }
        }
        .onDisappear { recorder.stop() }
    }
}

/// One recording: a local key-down monitor that swallows the next key press.
@MainActor @Observable final class HotKeyRecordingSession {
    private(set) var isRecording = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var onRecord: ((HotKeyCombo?) -> Void)?

    func start(onRecord: @escaping (HotKeyCombo?) -> Void) {
        stop()
        self.onRecord = onRecord
        isRecording = true
        HotKeys.shared.setSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread; swallow the key press while recording.
            let swallowed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return swallowed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRecord = nil
        if isRecording { isRecording = false; HotKeys.shared.setSuspended(false) }
    }

    /// Always consumes the key press (returns true) while recording.
    private func handle(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        switch Int(event.keyCode) {
        case kVK_Escape where plain:
            stop()
        case kVK_Delete where plain, kVK_ForwardDelete where plain:
            onRecord?(nil); stop()
        default:
            guard let combo = HotKeyCombo(event: event) else { NSSound.beep(); return true }
            onRecord?(combo); stop()
        }
        return true
    }
}
