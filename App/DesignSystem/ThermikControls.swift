//  ThermikControls.swift — the switch and the slider drawn with shapes, and plain table rows (MIT). OWNER: Unit 7.
//  On macOS 26 and later every appearance of a system switch or slider, SwiftUI's or AppKit's, makes the process hold
//  about 260 MB of GPU memory for a second (their Liquid Glass knobs are rendered with Metal; measured on macOS 27, also
//  for mini and disabled switches), and so do a table's zebra stripes wherever rows do not fill it. There these draw the
//  system controls' shapes, sizes and colours (measured) with no GPU cost; macOS 14 and 15 keep the system controls.
//  VoiceOver sees the system control (accessibilityRepresentation); keyboard focus and keys work as with it.
import AppKit
import SwiftUI

// MARK: - Switch

/// Toggles drawn as the system switch. A grouped form takes `.thermikFormSwitch`, the mini switch macOS draws there;
/// elsewhere `.thermikSwitch` follows the control size.
struct ThermikSwitchStyle: ToggleStyle {
    var inForm: Bool

    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            LabeledContent {
                ThermikSwitch(isOn: configuration.$isOn, size: inForm ? .mini : nil, label: configuration.label)
            } label: {
                configuration.label.accessibilityHidden(true)       // the switch carries it
            }
        } else if inForm {
            Toggle(configuration)                                   // the form's own switch
        } else {
            Toggle(configuration).toggleStyle(.switch)
        }
    }
}

extension ToggleStyle where Self == ThermikSwitchStyle {
    /// The switch of a grouped form: mini, as macOS draws it there.
    static var thermikFormSwitch: ThermikSwitchStyle { ThermikSwitchStyle(inForm: true) }
    /// A switch sized by the environment's control size.
    static var thermikSwitch: ThermikSwitchStyle { ThermikSwitchStyle(inForm: false) }
}

private struct ThermikSwitch: View {
    @Binding var isOn: Bool
    var size: ControlSize?          // nil: the environment's control size
    var label: ToggleStyleConfiguration.Label
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        // The system switch: mini 36 × 16, small 44 × 20, regular 54 × 24; the knob is a pill 60 % of the track wide.
        let track = switch size ?? controlSize {
        case .mini: CGSize(width: 36, height: 16)
        case .small: CGSize(width: 44, height: 20)
        default: CGSize(width: 54, height: 24)
        }
        Capsule()
            .fill(isOn ? ControlColors.fill(active: activeState != .inactive, slider: false) : ControlColors.track)
            .overlay { if contrast == .increased { Capsule().strokeBorder(ControlColors.outline, lineWidth: 1) } }
            .opacity(isEnabled ? 1 : isOn ? 0.7 : 0.5)          // disabled: the system fades the track only
            .overlay(alignment: isOn ? .trailing : .leading) {
                ControlKnob(color: ControlColors.switchKnob).frame(width: track.width * 0.6).padding(2)
            }
            .frame(width: track.width, height: track.height)
            .contentShape(Capsule())
            .onTapGesture { isOn.toggle() }
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isOn)
            .focusable(interactions: .activate)
            .onKeyPress(.space, phases: .down) { _ in isOn.toggle(); return .handled }   // once per press, not on repeat
            .accessibilityRepresentation {
                // A system switch on this one, trailing edges together (it keeps its regular size there): VoiceOver
                // reads and presses it as any switch. With its label hidden it would be a toggle button.
                Toggle(isOn: $isOn) { label }.toggleStyle(.switch).fixedSize()
                    .frame(width: track.width, height: track.height, alignment: .trailing)
            }
    }
}

// MARK: - Slider

/// A slider drawn as the system one: capsule track, accent fill, white pill knob, and with a step a dot under the track
/// for every step. A drag runs an editing session (`onEditingChanged`) as the system slider does, ended also when the
/// view goes away mid-drag; a click on the track jumps there, a press on the knob moves nothing until the pointer does.
/// Arrow keys and VoiceOver step without a session, as with the system slider. No visible label: give it one with
/// `.accessibilityLabel`.
struct ThermikSlider: View {
    @Binding var value: Double
    var bounds: ClosedRange<Double>
    var step: Double?
    var onEditingChanged: (Bool) -> Void
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var grip: CGFloat?           // where the drag holds the knob, from its leading edge; nil: no drag

    init(value: Binding<Double>, in bounds: ClosedRange<Double>, step: Double? = nil,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value; self.bounds = bounds; self.step = step; self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            drawn
        } else if let step {
            Slider(value: $value, in: bounds, step: step, onEditingChanged: onEditingChanged)
        } else {
            Slider(value: $value, in: bounds, onEditingChanged: onEditingChanged)
        }
    }

    @ViewBuilder private var drawn: some View {
        // The system slider: knob 20 × 16, 18 × 14, 16 × 12 and track 6, 4, 4 pt (regular, small, mini). With a step it
        // draws a 2 pt dot under the track for every step, and at small and mini its knob stands up: 10 × 18, 8 × 16.
        let ticks = tickCount
        let (knob, trackHeight, tickGap): (CGSize, CGFloat, CGFloat) = switch controlSize {
        case .mini: (ticks == nil ? CGSize(width: 16, height: 12) : CGSize(width: 8, height: 16), 4, 2)
        case .small: (ticks == nil ? CGSize(width: 18, height: 14) : CGSize(width: 10, height: 18), 4, 3)
        default: (CGSize(width: 20, height: 16), 6, 3)
        }
        GeometryReader { g in
            let travel = max(g.size.width - knob.width, 1)
            let x = travel * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(ControlColors.track)
                    .overlay { if contrast == .increased { Capsule().strokeBorder(ControlColors.outline, lineWidth: 1) } }
                    .frame(height: trackHeight)
                // Disabled, the filled part loses its accent and fades; the empty part and the knob stay.
                Capsule().fill(isEnabled ? ControlColors.fill(active: activeState != .inactive, slider: true) : ControlColors.track)
                    .opacity(isEnabled ? 1 : 0.5)
                    .frame(width: x + knob.width / 2, height: trackHeight)
                if let ticks, let step {
                    Path { p in         // one shape for all the dots
                        let span = bounds.upperBound - bounds.lowerBound
                        let y = (g.size.height + trackHeight) / 2 + tickGap
                        for i in 0..<ticks {
                            let cx = knob.width / 2 + travel * CGFloat(Double(i) * step / span)
                            p.addEllipse(in: CGRect(x: cx - 1, y: y, width: 2, height: 2))
                        }
                    }
                    .fill(ControlColors.tick)
                    .opacity(isEnabled ? 1 : 0.38)
                }
                ControlKnob(color: ControlColors.sliderKnob).frame(width: knob.width, height: knob.height).offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if grip == nil {
                        let onKnob = drag.startLocation.x >= x && drag.startLocation.x <= x + knob.width
                        grip = onKnob ? drag.startLocation.x - x : knob.width / 2
                        onEditingChanged(true)
                        if onKnob { return }
                    }
                    set(fraction: (drag.location.x - (grip ?? 0)) / travel)
                }
                .onEnded { _ in endSession() })
        }
        .frame(height: knob.height)
        .onDisappear { endSession() }
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.leftArrow, .downArrow, .rightArrow, .upArrow]) { press in
            stepOnce(press.key == .leftArrow || press.key == .downArrow ? -1 : 1)
            return .handled
        }
        .accessibilityRepresentation {
            if let step { Slider(value: $value, in: bounds, step: step) } else { Slider(value: $value, in: bounds) }
        }
    }

    /// One dot for every step from the lower bound (the system's count); nil without a step.
    private var tickCount: Int? {
        let span = bounds.upperBound - bounds.lowerBound
        guard let step, step > 0, span > 0 else { return nil }
        return Int((span / step + 1e-9).rounded(.down)) + 1
    }

    private var fraction: Double {
        let span = bounds.upperBound - bounds.lowerBound
        return span > 0 ? min(max((value - bounds.lowerBound) / span, 0), 1) : 0
    }

    /// The editing session ends once, whether the drag ends or the view goes away during it.
    private func endSession() {
        guard grip != nil else { return }
        grip = nil
        onEditingChanged(false)
    }

    /// An arrow key: to the next step in that direction, so a value between steps reaches the nearest one past it;
    /// without a step, 1 % of the range.
    private func stepOnce(_ direction: Double) {
        guard let step, step > 0 else {
            set(value: value + direction * (bounds.upperBound - bounds.lowerBound) / 100)
            return
        }
        let k = (value - bounds.lowerBound) / step
        set(value: bounds.lowerBound + (direction > 0 ? (k + 1e-9).rounded(.down) + 1 : (k - 1e-9).rounded(.up) - 1) * step)
    }

    private func set(fraction: Double) {
        set(value: bounds.lowerBound + min(max(fraction, 0), 1) * (bounds.upperBound - bounds.lowerBound))
    }

    /// Snapped to `step` (counted from the lower bound) and clamped; a value that does not change is not written.
    private func set(value raw: Double) {
        var v = min(max(raw, bounds.lowerBound), bounds.upperBound)
        if let step, step > 0 {
            v = min(bounds.lowerBound + ((v - bounds.lowerBound) / step).rounded() * step, bounds.upperBound)
        }
        if v != value { value = v }
    }
}

// MARK: - Tables

extension View {
    /// Table rows without zebra stripes on macOS 26 and later: drawn in the empty part of a table (a few rows, or rows
    /// filtered down), the stripes made the process hold about 250 MB of GPU memory for a second on every appearance.
    @ViewBuilder func thermikPlainRows() -> some View {
        if #available(macOS 26.0, *) { alternatingRowBackgrounds(.disabled) } else { self }
    }
}

// MARK: - Shared

/// The white pill both controls use as their knob, with the system's soft shadow.
private struct ControlKnob: View {
    var color: Color
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Capsule()
            .fill(color)
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .overlay {
                if contrast == .increased { Capsule().strokeBorder(ControlColors.outline, lineWidth: 1) }
                else { Capsule().strokeBorder(.black.opacity(0.05), lineWidth: 0.5) }
            }
    }
}

/// Colours measured from the system controls on macOS 27 (light: over white; dark: over a 12 % grey window). With
/// Increase Contrast, tracks and knobs also get an `outline`, as system controls get borders there.
private enum ControlColors {
    /// The off track and the slider's empty part: black 8 % (light), white 17 % (dark).
    static let track = adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.17))
    static let switchKnob = adaptive(light: .white, dark: NSColor(white: 0.91, alpha: 1))
    static let sliderKnob = adaptive(light: .white, dark: NSColor(white: 0.89, alpha: 1))
    /// A step's dot: black 26 % (light), white 25 % (dark).
    static let tick = adaptive(light: NSColor(white: 0, alpha: 0.26), dark: NSColor(white: 1, alpha: 0.25))
    static let outline = Color.primary.opacity(0.5)

    /// The on track and the slider's filled part: the accent colour, grey while the window is inactive.
    static func fill(active: Bool, slider: Bool) -> Color {
        guard !active else { return .accentColor }
        return slider ? inactiveSliderFill : inactiveSwitchFill
    }

    private static let inactiveSwitchFill = adaptive(light: NSColor(white: 0, alpha: 0.11), dark: NSColor(white: 1, alpha: 0.22))
    private static let inactiveSliderFill = adaptive(light: NSColor(white: 0, alpha: 0.18), dark: NSColor(white: 1, alpha: 0.31))

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
}
