// PopoverRoot.swift — Thermik (MIT). OWNER: Unit 7. The menu bar popover (SPEC §4.5, DES §7.7): 360 pt wide,
// height = content up to 620 pt (or the screen); header and fans stay pinned, the sensor list scrolls, footer pinned.
// The content tree exists only while the panel is open (StatusPanelState.isOpen), so a closed popover costs nothing.
import SwiftUI
import ThermikCore

struct PopoverRoot: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(StatusPanelState.self) private var panel: StatusPanelState?
    // Typical heights until measured (header + fans card ≈ 260 pt, footer ≈ 80 pt).
    @State private var headerHeight: CGFloat = 260
    @State private var footerHeight: CGFloat = 80

    var body: some View {
        let maxHeight = panel?.maxHeight ?? ThermikMetrics.popoverMaxHeight
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                PopoverHeader()
                PopoverBanners()
                PopoverFansSection()
                    .padding(.horizontal, ThermikMetrics.gutter)
                    .padding(.vertical, 8)
                Divider().padding(.horizontal, ThermikMetrics.gutter)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

            PopoverSensorList(maxHeight: max(maxHeight - headerHeight - footerHeight, 88))

            VStack(spacing: 0) {
                Divider().padding(.horizontal, ThermikMetrics.gutter)
                PopoverFooter()
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .frame(width: ThermikMetrics.popoverWidth)
        .thermikDesignEnvironment(colorBlind: settings.colorBlindScale, animatedEffects: settings.animatedEffects,
                                  visible: panel?.isOpen ?? true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Thermik"))
    }
}

// MARK: - Shared popover helpers

extension StatusPanelState? {
    /// Closes the popover (if hosted in the status panel), then runs `action` (navigation to a window).
    @MainActor func closeThen(_ action: () -> Void) {
        self?.requestClose()
        action()
    }
}

/// Fan name for the UI. The DB ships English "Left"/"Right" (SensorInventory.fanNames: "UI localizes Left/Right itself").
@MainActor func popoverFanName(_ fan: LiveFan) -> String {
    let n = fan.displayName.trimmingCharacters(in: .whitespaces)
    switch n.lowercased() {
    case "left", "left fan": return String(localized: "Left fan")
    case "right", "right fan": return String(localized: "Right fan")
    case "": return String(localized: "Fan \(fan.id + 1)")
    default: return n
    }
}

/// Short fan name for the popover rows, which already sit under the "Fans" header: «Левый» instead of
/// «Левый вентилятор», which truncates next to the speed bar in the 360 pt panel.
@MainActor func popoverFanShortName(_ fan: LiveFan) -> String {
    // LiveFan.displayName is already localized by FanStore.displayName ("Left fan" → «Левый вентилятор»).
    let name = popoverFanName(fan)
    switch name {
    case String(localized: "Left fan"): return String(localized: "fanSide.left", defaultValue: "Left", comment: "Popover fan row under the Fans header")
    case String(localized: "Right fan"): return String(localized: "fanSide.right", defaultValue: "Right", comment: "Popover fan row under the Fans header")
    default: return name
    }
}

// MARK: - DEBUG overrides (SPEC §5 Unit 7 acceptance: force fanless / helper-missing / stale / ◆ states)

/// Forced UI states for manual verification. Always empty in Release builds. In DEBUG builds they are toggled from the
/// status item's right-click "Debug" menu or set at launch, e.g. `open Thermik.app --args -ThermikDemo YES
/// -ThermikDebugHelper notInstalled` (keys: ThermikDebugFanless, ThermikDebugHelper, ThermikDebugForeign,
/// ThermikDebugStale, ThermikDebugBadge override|safety, ThermikDebugPressure 0…4, ThermikDebugEngaging,
/// ThermikDebugMaxCountdown, ThermikDebugCycleStyles, ThermikDebugStyle <MenuBarStyle raw value>). Launch arguments
/// live in the volatile argument domain only.
@MainActor @Observable final class PopoverDebugOverrides {
    var fanless = false
    var helper: HelperAvailability?
    var foreignController: String?
    var stale = false
    var badge: MenuBarBadge?
    var pressure: ThermalPressure?
    var engaging = false
    var safetyOverrideC: Double?
    var maxDeadline: Date?
    var styleOverride: MenuBarStyle?
    var cycleStyles = false

    init() {
        #if DEBUG
        let d = UserDefaults.standard
        fanless = d.bool(forKey: "ThermikDebugFanless")
        helper = d.string(forKey: "ThermikDebugHelper").flatMap(HelperAvailability.init(rawValue:))
        foreignController = d.string(forKey: "ThermikDebugForeign")
        stale = d.bool(forKey: "ThermikDebugStale")
        badge = switch d.string(forKey: "ThermikDebugBadge") { case "override": .override; case "safety": .safety; default: nil }
        if badge == .safety { safetyOverrideC = 103 }
        pressure = (d.object(forKey: "ThermikDebugPressure") as? Int).flatMap { ThermalPressure(rawValue: UInt64(max($0, 0))) }
            ?? d.string(forKey: "ThermikDebugPressure").flatMap { UInt64($0) }.flatMap(ThermalPressure.init(rawValue:))
        engaging = d.bool(forKey: "ThermikDebugEngaging")
        if d.bool(forKey: "ThermikDebugMaxCountdown") { maxDeadline = Date().addingTimeInterval(30 * 60) }
        cycleStyles = d.bool(forKey: "ThermikDebugCycleStyles")
        styleOverride = d.string(forKey: "ThermikDebugStyle").flatMap(MenuBarStyle.init(rawValue:))
        #endif
    }

    var isActive: Bool {
        fanless || helper != nil || foreignController != nil || stale || badge != nil || pressure != nil || engaging
            || safetyOverrideC != nil || maxDeadline != nil || styleOverride != nil || cycleStyles
    }

    func reset() {
        fanless = false; helper = nil; foreignController = nil; stale = false; badge = nil; pressure = nil
        engaging = false; safetyOverrideC = nil; maxDeadline = nil; styleOverride = nil; cycleStyles = false
    }
}

/// Effective fan-control state for the UI (FanStore status + DEBUG overrides), shared by the popover and menu bar.
struct FanPanelState: Equatable {
    var status: FanControlStatus
    var hasFans: Bool
    var canControl: Bool
    var mode: FanMode
    var foreignName: String?
    var maxDeadline: Date?

    @MainActor init(fans: FanStore, debug: PopoverDebugOverrides?) {
        var status = fans.status
        var hasFans = fans.hasFans
        var canControl = fans.canControl
        var foreign = fans.foreignControllerName
        if case .foreignController(let n) = status { foreign = n ?? foreign }
        if let debug {
            if let t = debug.safetyOverrideC { status = .safetyOverride(temperatureC: t) }
            if debug.engaging { status = .engaging }
            if let name = debug.foreignController { status = .foreignController(name: name); foreign = name; canControl = false }
            if let h = debug.helper { status = .monitoringOnly(h); canControl = false }
            if debug.fanless { status = .fanless; hasFans = false; canControl = false }
        }
        if case .foreignController = status { canControl = false }
        self.status = status
        self.hasFans = hasFans
        self.canControl = canControl
        self.mode = canControl ? fans.mode : .system          // "Auto shown as current" while control is unavailable
        self.foreignName = foreign
        self.maxDeadline = debug?.maxDeadline ?? fans.maxRevertDeadline
    }

    var helperAvailability: HelperAvailability? {
        if case .monitoringOnly(let a) = status { return a }
        return nil
    }
    var isForeign: Bool { if case .foreignController = status { return true }; return false }
    var isEngaging: Bool { status == .engaging }
    var safetyTemperature: Double? { if case .safetyOverride(let t) = status { return t }; return nil }
}
