//  ThermikEffects.swift — Thermik's decorative effects (MIT). OWNER: Unit 7.
//  Effects policy (SPEC §4.10, DES §3.3): never in the menu bar; animate only while the host is visible and
//  `EffectsPolicy.animate` holds; at most one effect animates at a time.
//  Every effect is a bitmap drawn on the CPU (EffectFrames), never a Metal shader: any SwiftUI Metal effect on screen
//  made RenderBox hold 70–260 MB of GPU surfaces. Animated frames go straight into a layer (EffectLayer), never through
//  a SwiftUI update.
import SwiftUI

/// Global switch for decorative animation: honours Reduce Motion, Low Power Mode and the in-app setting.
struct EffectsPolicy {
    var reduceMotion: Bool
    var lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    var userEnabled: Bool = true
    /// The hosting window is on screen (popover open / main window visible and not occluded).
    var visible: Bool = true
    var animate: Bool { userEnabled && !reduceMotion && !lowPower && visible }
}

extension EnvironmentValues {
    /// Set to false by a host while its window is hidden or occluded: every effect freezes on its still frame.
    @Entry var thermikEffectsVisible: Bool = true
    /// Settings › Appearance › Animated effects (`settings.animatedEffects`).
    @Entry var thermikAnimatedEffects: Bool = true
}

extension View {
    /// Injects the design-system environment of a hosted root: colour ramp, user effects switch and visibility.
    func thermikDesignEnvironment(colorBlind: Bool, animatedEffects: Bool, visible: Bool = true) -> some View {
        environment(\.thermikRamp, ThermikRamp.forSettings(colorBlind: colorBlind))
            .environment(\.thermikAnimatedEffects, animatedEffects)
            .environment(\.thermikEffectsVisible, visible)
    }
}

/// Reads the environment once per body evaluation and builds the policy.
private struct EffectsEnvironment: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.thermikAnimatedEffects) var userEnabled
    @Environment(\.thermikEffectsVisible) var visible
    var policy: EffectsPolicy { EffectsPolicy(reduceMotion: reduceMotion, userEnabled: userEnabled, visible: visible) }
}

/// Shows an effect's frames in a layer of its own. While animating, a display link puts each new frame straight into
/// that layer at `fps`, so a frame costs its drawing and one layer commit. With a TimelineView, every tick also re-ran
/// SwiftUI's graph update and the window's layout pass: measured with the Overview's glow animating, +26 % CPU that way
/// against +4–7 % this way. With `tint`, a frame is a mask over that colour. The still frame (time 0) stays with the view
/// and is redrawn only when `stillKey`, the size or the scale changes.
private struct EffectLayer: NSViewRepresentable {
    var animate: Bool
    var fps: Double
    var tint: Color?
    /// Every input of the frame besides the view's size and scale.
    var stillKey: [Float]
    /// The frame for a view of `size` points at `scale` pixels per point, `time` seconds into the animation (0: still).
    var frame: @MainActor (_ size: CGSize, _ scale: CGFloat, _ time: Float) -> CGImage?

    init(animate: Bool, fps: Double, tint: Color? = nil, stillKey: [Float],
         frame: @escaping @MainActor (_ size: CGSize, _ scale: CGFloat, _ time: Float) -> CGImage?) {
        self.animate = animate; self.fps = fps; self.tint = tint; self.stillKey = stillKey; self.frame = frame
    }

    func makeNSView(context: Context) -> LayerView { LayerView() }

    func updateNSView(_ view: LayerView, context: Context) {
        view.frameSource = frame
        view.stillKey = stillKey
        view.scale = context.environment.displayScale
        view.tint = tint.map { $0.resolve(in: context.environment).cgColor }
        view.fill = Float(Color.primary.resolve(in: context.environment).opacity)
        view.setAnimation(animate ? max(fps, 1) : nil)
        view.update()
    }

    static func dismantleNSView(_ view: LayerView, coordinator: ()) { view.setAnimation(nil) }

    final class LayerView: NSView {
        fileprivate var frameSource: @MainActor (CGSize, CGFloat, Float) -> CGImage? = { _, _, _ in nil }
        fileprivate var stillKey: [Float] = []
        fileprivate var scale: CGFloat = 2
        fileprivate var tint: CGColor?
        /// The shaders ended with `* color.a`, the default foreground's alpha: 216/255 normally, 255/255 with Increase
        /// Contrast, 178 (light) or 229 (dark) over a material such as the panel's glass. Frames have unit alpha.
        fileprivate var fill: Float = 1
        private let effect = CALayer(), mask = CALayer()
        private var fps: Double?                 // nil: still
        private var link: CADisplayLink?
        private var idle = false                 // the link runs slowly while the view is scrolled out of sight
        private var idleSince: CFTimeInterval = 0
        private var start: CFTimeInterval = 0
        private var time: Float = 0              // 0: the still frame
        private var shown: CGImage?              // the frame in the layer, before re-tagging
        private var shownSpace: CGColorSpace?
        private var shownTinted = false
        private var shownKey: [Float]?           // the still in the layer: `stillInputs` when drawn, nil for animation

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(effect)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }      // decoration: clicks reach the views below
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); syncLink() }

        override func setFrameSize(_ newSize: NSSize) {
            let changed = newSize != frame.size
            super.setFrameSize(newSize)
            guard changed else { return }
            // Animating, the next frame comes at the new size; during a live resize the still stretches until it ends.
            if shown != nil, link != nil || inLiveResize { restyle() } else { redraw() }
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            update()
        }

        /// SwiftUI updates come about once a second. Still, the frame is redrawn only when an input changed; animating,
        /// the next frame picks new inputs up anyway.
        fileprivate func update() {
            if link == nil ? stillInputs != shownKey : shown == nil { redraw() } else { restyle() }
        }

        private var stillInputs: [Float] { stillKey + [Float(bounds.width), Float(bounds.height), Float(scale)] }

        fileprivate func setAnimation(_ fps: Double?) {
            guard fps != self.fps else { return }
            self.fps = fps
            link?.invalidate(); link = nil
            syncLink()
        }

        /// The display link runs only while animating in a window; it retains the view until invalidated.
        private func syncLink() {
            if let fps, window != nil {
                guard link == nil else { return }
                let link = displayLink(target: self, selector: #selector(step))
                link.preferredFrameRateRange = Self.rate(fps)
                link.add(to: .main, forMode: .common)
                self.link = link
                idle = false
                start = CACurrentMediaTime()
            } else {
                link?.invalidate(); link = nil
                time = 0
            }
        }

        private static func rate(_ fps: Double) -> CAFrameRateRange {
            CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
        }

        @objc private func step(_ link: CADisplayLink) {
            // Scrolled out of sight, the link keeps firing (views do not clip to their bounds, so test the overlap): it
            // slows to 4 fps and the animation clock stops, so the view resumes from the frame it still shows.
            let visible = visibleRect.intersects(bounds)
            if visible == idle, let fps {
                idle = !visible
                link.preferredFrameRateRange = Self.rate(idle ? min(fps, 4) : fps)
                if idle { idleSince = link.targetTimestamp } else { start += link.targetTimestamp - idleSince }
            }
            guard visible else { return }
            // Seconds since the animation started, kept small so Float precision holds.
            time = Float((link.targetTimestamp - start).truncatingRemainder(dividingBy: 3600))
            redraw()
        }

        private func redraw() {
            let image = bounds.width < 1 || bounds.height < 1 ? nil : frameSource(bounds.size, scale, time)
            let tinted = tint != nil
            // A mask gives only its alpha: tagged with the window's own colour space, Core Animation takes the frame as it
            // is instead of colour-matching it on every commit (measured 0.9 → 0.09 ms at 1208 × 288 pixels).
            let space = tinted ? window?.colorSpace?.cgColorSpace : nil
            shownKey = time == 0 ? stillInputs : nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if image !== shown || space != shownSpace || tinted != shownTinted {
                shown = image; shownSpace = space; shownTinted = tinted
                let contents = space.flatMap { image?.copy(colorSpace: $0) } ?? image
                mask.contents = tinted ? contents : nil
                effect.contents = tinted ? nil : contents
            }
            style()
            CATransaction.commit()
        }

        private func restyle() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            style()
            CATransaction.commit()
        }

        /// What changes without a new frame: geometry, tint and opacity.
        private func style() {
            effect.frame = bounds
            mask.frame = effect.bounds
            effect.backgroundColor = tint
            effect.mask = tint != nil ? mask : nil
            effect.opacity = fill
        }
    }
}

// MARK: - 1. Heat glow behind the hottest card

/// Place *behind* a card: `.background { HeatGlow(intensity:tint:) }`.
/// `intensity` 0…1 — map from ThermalScale.normalized(temp) with a dead zone (no glow below "warm").
struct HeatGlow: View {
    var intensity: Double
    var tint: Color
    var cornerRadius: CGFloat = ThermikMetrics.cardRadius
    var spread: CGFloat = 22
    var fps: Double = 15          // the glow moves slowly: 15 fps is enough, and every frame is drawn on the CPU
    /// false → static frame (e.g. while the aurora animates: the two never animate together, SPEC §4.5).
    var animated: Bool = true
    private var effects = EffectsEnvironment()

    init(intensity: Double, tint: Color, cornerRadius: CGFloat = ThermikMetrics.cardRadius, spread: CGFloat = 22,
         fps: Double = 15, animated: Bool = true) {
        self.intensity = intensity; self.tint = tint; self.cornerRadius = cornerRadius; self.spread = spread
        self.fps = fps; self.animated = animated
    }

    static func intensity(forNormalized t: Double) -> Double {
        // 0 below t = 0.55 (warm), eases in to 1 at critical.
        let x = min(max(0, (t - 0.55) / 0.45), 1)
        return x * x * (3 - 2 * x)
    }

    var body: some View {
        // 1/50 steps: the hottest value moves a little on every tick, and each new intensity draws a new still frame.
        let level = (min(max(intensity, 0), 1) * 50).rounded() / 50
        let active = level > 0.02
        Group {
            if active {
                // Frozen, the glow shows one stable frame (time 0 is a valid, pleasant phase of the noise).
                EffectLayer(animate: animated && effects.policy.animate, fps: fps, tint: tint,
                            stillKey: [Float(level), Float(cornerRadius), Float(spread)]) { size, scale, time in
                    mask(level: level, size: size, scale: scale, time: time)
                }
            }
        }
        .padding(-spread)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Animates `active` flips only, for a caller that keeps the glow mounted (both call sites mount it only when hot,
        // so there it appears in one step, as before). Keyed to the intensity, a 0.6 s animation restarted on every tick
        // and kept the whole panel redrawing at the display rate, even with animated effects off.
        .animation(effects.reduceMotion ? nil : .easeInOut(duration: 0.6), value: active)
    }

    /// The glow mask at `time`. The tint is not part of it: it follows the hottest value on every tick.
    private func mask(level: Double, size: CGSize, scale: CGFloat, time: Float) -> CGImage? {
        EffectFrames.heatGlowMask(intensity: Float(level), cornerRadius: Float(cornerRadius), spread: Float(spread),
                                  width: Float(size.width.rounded()), height: Float(size.height.rounded()),
                                  scale: Float(scale), time: time)
    }
}

// MARK: - 2. Chip thermal map

struct DieSensor: Identifiable, Sendable, Hashable {
    let id: String          // SMC key or HID name
    let label: String       // "P-Core 3", "GPU 2", …
    let position: CGPoint   // unit square of the die (0…1), from a per-chip layout table
    var celsius: Double
    var scale: ThermalScale = .soc
}

/// Smooth heat field interpolated (inverse-distance weighting) from sparse sensors.
/// Static by default (redraws only when values change, i.e. at sensor cadence ~1 Hz).
struct ThermalFieldView: View {
    var sensors: [DieSensor]
    var cornerRadius: CGFloat = 12
    var power: Double = 2.6
    var contours: Bool = true
    var showsMarkers: Bool = true
    var unit: UnitTemperature = .celsius
    @Binding var hovered: DieSensor.ID?
    @Environment(\.self) private var environment
    @State private var memo = FieldMemo()

    init(sensors: [DieSensor], cornerRadius: CGFloat = 12, power: Double = 2.6, contours: Bool = true,
         showsMarkers: Bool = true, unit: UnitTemperature = .celsius, hovered: Binding<DieSensor.ID?>) {
        self.sensors = sensors; self.cornerRadius = cornerRadius; self.power = power; self.contours = contours
        self.showsMarkers = showsMarkers; self.unit = unit; self._hovered = hovered
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                Group {
                    if let image = field(size: geo.size) {
                        // The shader's `* color.a`, as for the other effects (EffectLayer.LayerView.fill).
                        Image(decorative: image, scale: environment.displayScale).resizable()
                            .opacity(Double(Color.primary.resolve(in: environment).opacity))
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 1))
                if showsMarkers {
                    ForEach(sensors) { s in
                        Circle()
                            .fill(.white.opacity(hovered == s.id ? 1 : 0.75))
                            .frame(width: hovered == s.id ? 9 : 5, height: hovered == s.id ? 9 : 5)
                            .shadow(color: .black.opacity(0.35), radius: 1.5)
                            .position(x: s.position.x * geo.size.width, y: s.position.y * geo.size.height)
                            .onHover { inside in hovered = inside ? s.id : (hovered == s.id ? nil : hovered) }
                            .help("\(s.label): \(ThermikFormat.temp(s.celsius, unit: unit))")
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Chip thermal map"))
        .accessibilityValue(sensors.sorted { $0.celsius > $1.celsius }.prefix(3)
            .map { "\($0.label) \(ThermikFormat.temp($0.celsius, unit: unit))" }.joined(separator: ", "))
    }

    /// The field bitmap, redrawn when a sensor moves by 1/200 of its scale (finer steps are not visible) and kept by the
    /// view in between, e.g. while the pointer moves over the markers.
    private func field(size: CGSize) -> CGImage? {
        let w = Float(size.width.rounded()), h = Float(size.height.rounded()), scale = Float(environment.displayScale)
        let points = sensors.map { s in
            SIMD3(Float(s.position.x), Float(s.position.y), (Float(s.scale.normalized(s.celsius)) * 200).rounded() / 200)
        }
        let stops = environment.thermikRamp.fieldStops.map { SIMD3(Float($0.r), Float($0.g), Float($0.b)) }
        let key: [Float] = [Float(power), contours ? 1 : 0, w, h, scale]
            + points.flatMap { [$0.x, $0.y, $0.z] } + stops.flatMap { [$0.x, $0.y, $0.z] }
        if key != memo.key {
            memo.key = key
            memo.image = EffectFrames.thermalField(sensors: points, ramp: stops, power: Float(power), contours: contours,
                                                   width: w, height: h, scale: scale)
        }
        return memo.image
    }
}

/// The chip map's last bitmap and its inputs: a class, so `body` can update it without invalidating the view.
private final class FieldMemo {
    var key: [Float] = []
    var image: CGImage?
}

// MARK: - 3. Aurora header

struct AuroraBackground: View {
    var normalized: Double      // hottest sensor, 0…1
    var energy: Double          // thermal pressure 0…1 (nominal 0, moderate .33, heavy .66, throttling 1)
    var fps: Double = 12        // motion is very slow: 10–12 fps is indistinguishable from more
    /// false → static frame. The popover animates only at pressure > nominal (SPEC §4.5).
    var animated: Bool = true
    private var effects = EffectsEnvironment()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.thermikRamp) private var ramp

    init(normalized: Double, energy: Double, fps: Double = 12, animated: Bool = true) {
        self.normalized = normalized; self.energy = energy; self.fps = fps; self.animated = animated
    }

    var body: some View {
        // 1/50 steps: finer than the eye can tell apart, and each new value draws a new still frame.
        let n = ((normalized.isFinite ? min(max(normalized, 0), 1) : 0) * 50).rounded() / 50
        let base = ThermikPalette.sample(ramp.vivid, n)
        // Analogous hues only (±0.1 on the ramp) — mixing e.g. green + orange turns muddy (seen in renders).
        let cool = ThermikPalette.sample(ramp.vivid, max(0, n - 0.10))
        let hot  = ThermikPalette.sample(ramp.vivid, min(1, n + 0.10))
        let alpha = scheme == .dark ? 0.42 : 0.34
        let e = Float(min(max(energy, 0), 1))
        let a = Float(alpha)
        let colors = [cool, base, hot].map { EffectFrames.RGBA(Float($0.r) * a, Float($0.g) * a, Float($0.b) * a, a) }   // premultiplied
        EffectLayer(animate: animated && effects.policy.animate, fps: fps,
                    stillKey: [e] + colors.flatMap { [$0.x, $0.y, $0.z, $0.w] }) { _, _, time in
            EffectFrames.aurora(colors[0], colors[1], colors[2], energy: e, time: time)       // stretched to the view
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
