// SanityFilter.swift — Thermik (MIT). OWNER: Unit 1. Validity of ONE decoded temperature (SPEC §2.5.4, SENS §5.3/§7).
//
// Sentinels observed on M4 Max / macOS 27 (SENS §5.3), all rejected by the rule below:
//  * power-gated P-cluster triplet (-4.0, -4.0 + offset, 0.0), e.g. (-4.0, 1.9, 0.0): everything < 10 °C on die groups;
//  * "not sampled yet" after cluster wake / system wake: exactly 40.0 on P-core, P-fabric and cluster-aggregate keys;
//  * 0.0 on unused keys and gated aggregates (`Tpx*`, `TH1a/b`, `Ta00…`), constant 8.6 on unused `Ta0x`;
//  * NaN from HID services without an event (`als-temp`);
//  * Intel sp78 raw 0x8000 / 0x7FFF (−128 / 127.996, disconnected probe): range check + the rail rule below
//    (VirtualSMC SMCSensorKeys, BSD-3: sp78 = signed 7.8 fixed point).
import Foundation

package struct SanityFilter: Sendable {
    /// The exact-40.0 placeholder rule is an Apple Silicon (M4) firmware artefact. Intel sp78 temperatures are often
    /// whole degrees, so on Intel the rule would drop genuine 40.0 °C readings (deliberate refinement of §2.5.4).
    package let rejectsPlaceholder40: Bool
    /// Intel only: 0x7FFF / 256 is the sp78 positive rail ("no probe"); it lies inside the die range 10…130.
    package let rejectsSP78Rail: Bool

    package static let sp78PositiveRail = 32767.0 / 256.0      // 127.99609375

    package init(appleSilicon: Bool) {
        rejectsPlaceholder40 = appleSilicon
        rejectsSP78Rail = !appleSilicon
    }

    package func isValid(_ v: Double, _ d: SensorDescriptor) -> Bool {
        guard v.isFinite, v != 0 else { return false }                       // NaN / Inf / unused / gated pos3
        guard d.group.plausibleRange.contains(v) else { return false }       // die 10…130; ambient-like −20…100
        if d.invalidValues?.contains(v) == true { return false }             // DB sentinels (40.0, 127.996)
        if rejectsPlaceholder40 && d.group.rejectsExact40 && v == 40.0 { return false }  // M4 "not sampled yet"
        if rejectsSP78Rail && v == Self.sp78PositiveRail { return false }    // Intel disconnected sp78 probe
        return true
    }
}
