// ChipIdentity+Read.swift — Thermik (MIT). OWNER: Unit 1. Chip / board identity (SPEC §2.5.2 step 1, SENS §8.3).
//
// Verified on Mac16,5: IOPlatformExpertDevice `platform-name` = "t6041" (Data, NUL-padded), `target-type` = "J616c",
// `compatible` = "J616cAP\0Mac16,5\0AppleARM\0"; `hw.model` = "Mac16,5"; `machdep.cpu.brand_string` = "Apple M4 Max";
// SMC `RPlt` (ch8*) = "j616c". Intel Macs have no `platform-name` → "intel" (SENS §8.6).
import Foundation
import IOKit
import ThermikSMC

extension ChipIdentity {
    /// Reads the identity once (≈ 0.2 ms; IORegistry + sysctl, plus one SMC read when a connection is given).
    public static func read(smc: SMCReading? = nil) -> ChipIdentity {
        let expert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if expert != 0 { IOObjectRelease(expert) } }
        let isAS = HostInfo.isAppleSilicon
        let platform = registryString(expert, "platform-name")
        // An Apple-Silicon Mac without platform-name would be a new layout, not Intel: heuristics, never intel.json.
        let platformName = platform.map { $0.lowercased() } ?? (isAS ? "unknown" : "intel")
        let target = registryString(expert, "target-type")
        let brand = sysctlString("machdep.cpu.brand_string") ?? (isAS ? "Apple Silicon" : "Intel")
        var smcPlatform: String?
        if let smc, case .string(let s)? = try? smc.value("RPlt"), !s.isEmpty { smcPlatform = s }
        return ChipIdentity(platformName: platformName, targetType: target, modelIdentifier: HostInfo.modelIdentifier,
                            chipName: brand, isAppleSilicon: isAS, smcPlatform: smcPlatform)
    }

    /// First NUL-terminated string of a Data (or String) registry property.
    static func registryString(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard entry != 0,
              let ref = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        let s: String?
        if let d = ref as? Data { s = String(decoding: d.prefix { $0 != 0 }, as: UTF8.self) }
        else { s = ref as? String }
        guard let v = s?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return s.isEmpty ? nil : s
    }
}
